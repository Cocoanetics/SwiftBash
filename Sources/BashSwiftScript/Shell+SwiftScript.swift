import BashInterpreter
import Foundation
import SwiftScriptInterpreter

extension Shell {

    /// Register SwiftScript under each of `names` as both a top-level
    /// command AND a shebang interpreter.
    ///
    /// Two registrations per name:
    ///
    ///   * **Command** — handles a bare `swift`/`swift-script`
    ///     invocation: `--version`, `-e <expr>`, and
    ///     `<script.swift> [args...]`. Mirrors the surface of the
    ///     standalone `swift-script` CLI.
    ///
    ///   * **ScriptInterpreter** — handles
    ///     `#!/usr/bin/env swift-script` / `#!/usr/bin/env swift`
    ///     when a path-invoked script triggers shebang dispatch.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()   // BashCommandKit
    /// shell.registerSwiftScript()        // BashSwiftScript
    /// try await shell.run("swift --version")
    /// try await shell.run("swift -e 'print(1 + 2)'")
    /// try await shell.run("/abs/script.swift one two")
    /// ```
    ///
    /// Each name gets its own ``SwiftScriptShellInterpreter``
    /// instance so the registry's `[String: ScriptInterpreter]`
    /// invariant holds (`interpreter.name == registryKey`). The
    /// underlying SwiftScript ``Interpreter`` is constructed fresh
    /// on every script invocation regardless, so no state leaks
    /// between scripts.
    public func registerSwiftScript(
        names: [String] = ["swift-script", "swift"]
    ) {
        for name in names {
            registerScriptInterpreter(SwiftScriptShellInterpreter(name: name))

            let invokedAs = name
            install(name: name) { argv in
                await runSwiftScriptCommand(invokedAs: invokedAs, argv: argv)
            }
        }
    }
}

/// Argv-shape dispatcher for the `swift` / `swift-script` commands.
/// Mirrors the standalone `swift-script` CLI but routes through the
/// bound ``Shell`` (IO via `shell.stdout/stderr`, script reads via
/// `shell.fileSystem` so virtualised mounts work).
private func runSwiftScriptCommand(
    invokedAs: String,
    argv: [String]
) async -> ExitStatus {
    let shell = Shell.bashCurrent
    let userArgs = Array(argv.dropFirst())

    guard let first = userArgs.first else {
        shell.stderr(swiftScriptUsage(invokedAs: invokedAs))
        return ExitStatus(2)
    }

    if first == "--version" || first == "-v" {
        // Match the upstream `swift --version` shape closely enough
        // that scripts which sniff "Swift" still recognise us.
        shell.stdout("swift-script 0.1 (SwiftBash embedded)\n")
        return .success
    }

    if first == "-h" || first == "--help" {
        shell.stderr(swiftScriptUsage(invokedAs: invokedAs))
        return ExitStatus(2)
    }

    if first == "-e" {
        return await runSwiftScriptEval(
            invokedAs: invokedAs, userArgs: userArgs, shell: shell)
    }

    return await runSwiftScriptFile(
        invokedAs: invokedAs, userArgs: userArgs, shell: shell)
}

private func swiftScriptUsage(invokedAs: String) -> String {
    """
    usage: \(invokedAs) <file.swift> [args...]
           \(invokedAs) -e <expression>
           \(invokedAs) --version

    """
}

private func renderSwiftScriptError(
    _ error: Error,
    interpreter: Interpreter
) -> ExitStatus {
    switch error {
    case let parseError as ParseError:
        interpreter.error(parseError.formatted)
        if !parseError.formatted.hasSuffix("\n") {
            interpreter.error("\n")
        }
        return ExitStatus(1)
    case is CancellationError:
        return ExitStatus(143)
    default:
        interpreter.error(interpreter.renderRuntimeError(error))
        return ExitStatus(1)
    }
}

private func runSwiftScriptEval(
    invokedAs: String,
    userArgs: [String],
    shell: Shell
) async -> ExitStatus {
    guard userArgs.count >= 2 else {
        shell.stderr(swiftScriptUsage(invokedAs: invokedAs))
        return ExitStatus(2)
    }
    let source = userArgs[1]
    let extra = Array(userArgs.dropFirst(2))
    let interpreter = Interpreter()
    interpreter.scriptArguments = ["<expression>"] + extra
    do {
        let result = try await interpreter.eval(
            source, fileName: "<expression>")
        if case .void = result {
            // nothing to print
        } else {
            shell.stdout(result.description + "\n")
        }
        return .success
    } catch let scriptExit as ScriptExit {
        return scriptExit.status
    } catch {
        return renderSwiftScriptError(error, interpreter: interpreter)
    }
}

private func runSwiftScriptFile(
    invokedAs: String,
    userArgs: [String],
    shell: Shell
) async -> ExitStatus {
    // Read through shell.fileSystem so virtualised mounts work.
    let scriptPath = userArgs[0]
    let scriptArgs = Array(userArgs.dropFirst())
    // Resolve relative paths against the shell's cwd (not the host
    // process cwd) so `swift foo.swift` works after an in-shell `cd`
    // and honours virtualised filesystem roots.
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
    var source = String(decoding: data, as: UTF8.self)
    // Rewrite a leading `#!` to `//` so the parser is happy; preserve
    // byte offsets so diagnostics still line up.
    if source.hasPrefix("#!") {
        source = "//" + source.dropFirst(2)
    }
    let interpreter = Interpreter()
    interpreter.scriptArguments = [resolved] + scriptArgs
    do {
        return try await interpreter.evalScript(source, fileName: resolved)
    } catch {
        return renderSwiftScriptError(error, interpreter: interpreter)
    }
}
