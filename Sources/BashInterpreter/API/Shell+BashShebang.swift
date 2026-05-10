import Foundation

extension Shell {

    /// Register `bash`, `sh`, and `dash` as shebang interpreters so a
    /// path-invoked script with `#!/usr/bin/env bash` (or `#!/bin/sh`,
    /// or `#!/usr/bin/env dash`) runs through this shell's bash
    /// interpreter.
    ///
    /// Without this, `./hello.sh` fails with `command not found` —
    /// SwiftBash is in-process and doesn't fall back to host `exec`,
    /// so a `#!`-shebang naming an unregistered interpreter has
    /// nowhere to go. `bash <path>` (the builtin) still works because
    /// it goes through the registry directly, but every embedder
    /// building an interactive shell ends up writing the same
    /// boilerplate to make `./script.sh` work. Lift it into the API.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()   // BashCommandKit
    /// shell.registerBashShebang()        // <- this
    /// try await shell.run("./hello.sh")  // dispatches via the
    ///                                    //    shebang now
    /// ```
    ///
    /// Each name gets its own ``ClosureScriptInterpreter`` so the
    /// `[String: ScriptInterpreter]` invariant `interpreter.name ==
    /// registryKey` holds. The body just feeds the script source back
    /// into the bash interpreter — same semantics as `bash <path>`.
    public func registerBashShebang(
        names: [String] = ["bash", "sh", "dash"]
    ) {
        for name in names {
            registerScriptInterpreter(ClosureScriptInterpreter(name: name) { context in
                try await Shell.bashCurrent.run(context.source)
            })
        }
    }
}
