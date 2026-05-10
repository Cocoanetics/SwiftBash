#if canImport(JavaScriptCore)
import Foundation
import BashInterpreter

extension Shell {

    /// Register `swift-js`, `node`, and `bun` as shebang interpreters
    /// so a path-invoked script with `#!/usr/bin/env swift-js`
    /// (or `#!/usr/bin/env node`) runs in-process via `JSRuntime`.
    ///
    /// Mirrors ``Shell/registerBashShebang()`` and
    /// ``Shell/registerSwiftScript()``: one call wires the entire
    /// JavaScript shebang surface, with stdout / stderr routed
    /// through the calling shell's sinks, argv pinned to
    /// ``ShellArgvProvider``, env to ``ShellEnvProvider``, and
    /// `child_process` left in-process so JS spawns route back into
    /// SwiftBash's command registry rather than fork/exec.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()
    /// shell.registerSwiftScript()        // .swift via SwiftScript
    /// shell.registerSwiftJS()            // .js   via SwiftJSCore
    /// try await shell.run("./hello.js Alice")
    /// ```
    ///
    /// Apple-platforms only — JavaScriptCore isn't available on
    /// Linux / Windows / Android. The whole file is gated on
    /// `canImport(JavaScriptCore)`.
    public func registerSwiftJS(
        names: [String] = ["swift-js", "node", "bun"]
    ) {
        for name in names {
            let interpreterName = name
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
        }
    }
}
#endif
