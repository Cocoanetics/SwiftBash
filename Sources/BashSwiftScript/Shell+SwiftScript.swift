import BashInterpreter

extension Shell {

    /// Register SwiftScript under each of `names` so a path-invoked
    /// script with a matching `#!`-shebang routes through it.
    /// Defaults to `["swift-script", "swift"]` — both
    /// `#!/usr/bin/env swift-script` and `#!/usr/bin/env swift`
    /// shebangs go to the same backend.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()   // BashCommandKit
    /// shell.registerSwiftScript()        // BashSwiftScript
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
        }
    }
}
