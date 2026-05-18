#if canImport(JavaScriptCore)
import Foundation
import BashInterpreter

extension Shell {

    /// Register `swift-js`, `node`, and `bun` as both top-level
    /// commands AND shebang interpreters.
    ///
    /// Two registrations per name:
    ///
    ///   * **Command** — handles a bare `node`/`bun`/`swift-js`
    ///     invocation, including `--version`, `-e <expr>`,
    ///     `-p`/`--print <expr>`, and `<script.js> [args...]`.
    ///     Mirrors the argv-shape of the standalone `swift-js`
    ///     binary (``Sources/swift-js/main.swift``), but stays
    ///     in-process so it works inside iOS App Sandbox and
    ///     virtualised file systems.
    ///
    ///   * **ScriptInterpreter** — handles the
    ///     `#!/usr/bin/env node` shebang path so a path-invoked
    ///     `./hello.js` still routes here.
    ///
    /// Apple-platforms only — JavaScriptCore isn't available on
    /// Linux / Windows / Android. The whole file is gated on
    /// `canImport(JavaScriptCore)`.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()
    /// shell.registerSwiftScript()        // .swift via SwiftScript
    /// shell.registerSwiftJS()            // .js   via SwiftJSCore
    /// try await shell.run("node --version")
    /// try await shell.run("node -e 'console.log(2+2)'")
    /// try await shell.run("./hello.js Alice")
    /// ```
    public func registerSwiftJS(
        names: [String] = ["swift-js", "node", "bun"]
    ) {
        for name in names {
            let interpreterName = name
            // Shebang path: `#!/usr/bin/env node` against a file.
            registerScriptInterpreter(ClosureScriptInterpreter(name: name) { context in
                let shell = Shell.bashCurrent
                let runtime = JSRuntime(
                    argvProvider: ShellArgvProvider(
                        shell,
                        interpreter: interpreterName,
                        scriptPath: context.scriptPath),
                    envProvider: ShellEnvProvider(shell),
                    childShell: .inProcess,
                    stdout: { shell.stdout($0) },
                    stderr: { shell.stderr($0) })
                // Use the source the dispatcher already read through
                // `Shell.fileSystem`, NOT `runtime.runFile(scriptPath)`
                // — the latter reads from the host filesystem and
                // skips the embedder's filesystem mounts. With a
                // virtualised shell (e.g. `MountedFileSystem`),
                // `context.scriptPath` is a virtual path like
                // `/foo.js` that doesn't exist on the host.
                _ = runtime.run(context.source, name: context.scriptPath)
                runtime.fireExitListeners()
                return ExitStatus(Int32(runtime.exitCode))
            })

            // Top-level command path: `node --version`, `node -e ...`,
            // `node script.js`. Same surface as the standalone
            // `swift-js` binary.
            register(name: name) { argv in
                await runSwiftJSCommand(interpreter: interpreterName,
                                        argv: argv)
            }
        }
    }
}

/// Argv-shape dispatcher shared by the `node` / `bun` / `swift-js`
/// commands. Mirrors ``Sources/swift-js/main.swift`` but routes IO
/// through the bound ``Shell`` and reads scripts through
/// ``Shell/fileSystem`` so virtualised mounts work.
private func runSwiftJSCommand(
    interpreter: String,
    argv: [String]
) async -> ExitStatus {
    let shell = Shell.bashCurrent
    let invokedAs = (interpreter as NSString).lastPathComponent.lowercased()
    let userArgs = Array(argv.dropFirst())

    guard let first = userArgs.first else {
        shell.stderr(swiftJSUsage(invokedAs: invokedAs))
        return ExitStatus(2)
    }

    if first == "--version" || first == "-v" {
        shell.stdout("\(swiftJSVersion(invokedAs: invokedAs))\n")
        return .success
    }

    if first == "-e" || first == "-p" || first == "--print" {
        return runSwiftJSEval(
            interpreter: interpreter, invokedAs: invokedAs,
            flag: first, userArgs: userArgs, shell: shell)
    }

    return await runSwiftJSScript(
        interpreter: interpreter, invokedAs: invokedAs,
        userArgs: userArgs, shell: shell)
}

private func swiftJSUsage(invokedAs: String) -> String {
    let isAlias = invokedAs == "node" || invokedAs == "nodejs"
                  || invokedAs == "bun"
    if isAlias {
        return "usage: \(invokedAs) <script.js> [args...]\n"
             + "       \(invokedAs) -e <expr>\n"
             + "       \(invokedAs) --version\n"
    }
    return "usage: \(invokedAs) <script.js> [args...]\n"
         + "       \(invokedAs) -e|-p <expr>\n"
         + "       \(invokedAs) --version\n"
}

private func swiftJSVersion(invokedAs: String) -> String {
    switch invokedAs {
    case "node", "nodejs": return "v22.0.0-swiftjs"
    case "bun":            return "1.3.0-swiftjs"
    default:               return "swift-js 0.2"
    }
}

private func runSwiftJSEval(
    interpreter: String,
    invokedAs: String,
    flag: String,
    userArgs: [String],
    shell: Shell
) -> ExitStatus {
    guard userArgs.count >= 2 else {
        shell.stderr("\(invokedAs): \(flag) requires an expression\n")
        return ExitStatus(2)
    }
    let expr = userArgs[1]
    let extra = Array(userArgs.dropFirst(2))
    // Argv for inline eval: [interpreter, "[eval]", ...extra].
    // Mirrors node's behaviour where argv[1] is the script slot
    // even when there is no script file. Use StaticArgvProvider
    // because there's no script path to anchor a ShellArgvProvider.
    let runtime = JSRuntime(
        argv: [interpreter, "[eval]"] + extra,
        envProvider: ShellEnvProvider(shell),
        childShell: .inProcess,
        stdout: { shell.stdout($0) },
        stderr: { shell.stderr($0) })
    let result = runtime.run(expr, name: "[eval]")
    let shouldPrint = (flag == "-p" || flag == "--print")
    if shouldPrint, runtime.exitCode == 0,
       let result, !result.isUndefined, !result.isNull {
        shell.stdout((result.toString() ?? "") + "\n")
    }
    runtime.fireExitListeners()
    return ExitStatus(runtime.exitCode)
}

private func runSwiftJSScript(
    interpreter: String,
    invokedAs: String,
    userArgs: [String],
    shell: Shell
) async -> ExitStatus {
    // Anything that isn't a flag is treated as a script path. Read
    // through the shell's file system so virtualised mounts work —
    // same reason the shebang path doesn't use `runtime.runFile`.
    let scriptPath = userArgs[0]
    let scriptArgs = Array(userArgs.dropFirst())
    // Resolve relative paths against the shell's cwd (not the host
    // process cwd) so `node foo.js` works after an in-shell `cd` and
    // honours virtualised filesystem roots.
    let absolute = shell.resolvePath(scriptPath)
    let resolved: String
    do {
        resolved = try await shell.fileSystem.canonicalize(
            absolute, allowMissing: false)
    } catch {
        shell.stderr("\(invokedAs): \(scriptPath): No such file or directory\n")
        return ExitStatus(127)
    }
    let data: Data
    do {
        data = try await shell.fileSystem.readData(resolved)
    } catch {
        shell.stderr("\(invokedAs): \(scriptPath): \(error.localizedDescription)\n")
        return ExitStatus(1)
    }
    // swiftlint:disable:next optional_data_string_conversion
    let source = String(decoding: data, as: UTF8.self)

    // Stash scriptArgs as positional parameters so ShellArgvProvider
    // picks them up the same way the shebang path does.
    let savedPositional = shell.positionalParameters
    shell.positionalParameters = scriptArgs
    defer { shell.positionalParameters = savedPositional }

    let runtime = JSRuntime(
        argvProvider: ShellArgvProvider(
            shell,
            interpreter: interpreter,
            scriptPath: resolved),
        envProvider: ShellEnvProvider(shell),
        childShell: .inProcess,
        stdout: { shell.stdout($0) },
        stderr: { shell.stderr($0) })
    _ = runtime.run(source, name: resolved)
    runtime.fireExitListeners()
    return ExitStatus(Int32(runtime.exitCode))
}
#endif
