import Foundation
import ShellKit

extension Shell {

    // MARK: - install (file-backed)

    /// Install a file-backed ``Command`` at its catalog default path
    /// (`BinCatalog.knownPaths[command.name]`). Traps with a clear
    /// diagnostic if the command's name has no catalog entry — use
    /// ``install(_:at:)`` for off-catalog commands or
    /// ``installShellBuiltin(_:)`` for pure shell built-ins.
    ///
    /// ```swift
    /// shell.install(LsCommand())   // → /bin/ls (catalog)
    /// ```
    public func install(_ command: Command) {
        guard let path = BinCatalog.knownPaths[command.name] else {
            preconditionFailure(
                """
                Shell.install(\(command.name)): no BinCatalog entry. \
                Pass an explicit path: install(_, at: "/usr/local/bin/\(command.name)"), \
                or register as a shell built-in: installShellBuiltin(_).
                """)
        }
        install(command, at: path)
    }

    /// Install a file-backed ``Command`` at an explicit absolute path.
    /// PATH-searchable: a bare invocation of `command.name` resolves
    /// to this command when `path`'s parent directory appears in
    /// `$PATH`.
    ///
    /// ```swift
    /// shell.install(MyTool(), at: "/opt/mytool/bin/mt")
    /// ```
    ///
    /// Replaces any previous install at `path` (the path itself is
    /// the registry key). A second install at a *different* path with
    /// the same basename adds a new entry — both are reachable, with
    /// `$PATH` order picking the winner at lookup time.
    public func install(_ command: Command, at path: String) {
        installFileBacked(command, at: path)
    }

    /// Install a bundle of file-backed commands sharing one directory.
    /// Each command lands at `directory + "/" + command.name`, derived
    /// from its basename. Equivalent to N ``install(_:at:)`` calls but
    /// reads like a manifest.
    ///
    /// ```swift
    /// shell.install(at: "/usr/local/bin") {
    ///     DeployTool()
    ///     LintTool()
    ///     if includeFormatter { FormatTool() }
    /// }
    /// ```
    public func install(
        at directory: String,
        @CommandBundleBuilder _ body: () -> [Command]
    ) {
        for command in body() {
            let leaf = (directory as NSString)
                .appendingPathComponent(command.name)
            installFileBacked(command, at: leaf)
        }
    }

    // MARK: - installShellBuiltin (no path)

    /// Install a pure shell built-in — like `cd`, `export`, `eval`.
    /// Built-ins have no file on disk and are not PATH-searchable;
    /// they're consulted before PATH on bare invocations and ignored
    /// on absolute/relative path invocations (so `/bin/echo` runs the
    /// file form, never the built-in).
    public func installShellBuiltin(_ command: Command) {
        shellBuiltins[command.name] = command
        // Mirror into the legacy basename dict so introspection
        // surfaces (`compgen`, the `Shell.commands` snapshot, the
        // `is FunctionCommand` check in `UnsetCommand`) see the same
        // set the dispatcher uses. Stays in sync with ``shellBuiltins``
        // through ``uninstall(name:)``.
        commands[command.name] = command
    }

    // MARK: - Closure-form convenience

    /// Install a closure-backed file-backed command — short-cut to
    /// wrapping a ``ClosureCommand`` and passing it to ``install(_:)``.
    /// Traps when the name has no catalog entry; use the explicit-path
    /// or built-in variants when registering an off-catalog name.
    public func install(
        name: String,
        _ body: @Sendable @escaping ([String]) async throws -> ExitStatus
    ) {
        install(ClosureCommand(name: name, body: body))
    }

    /// Install a closure-backed file-backed command at an explicit
    /// path.
    public func install(
        name: String,
        at path: String,
        _ body: @Sendable @escaping ([String]) async throws -> ExitStatus
    ) {
        install(ClosureCommand(name: name, body: body), at: path)
    }

    /// Install a closure-backed shell built-in — the shortest path to
    /// adding a test stub or an off-catalog built-in.
    public func installShellBuiltin(
        name: String,
        _ body: @Sendable @escaping ([String]) async throws -> ExitStatus
    ) {
        installShellBuiltin(ClosureCommand(name: name, body: body))
    }

    // MARK: - uninstall

    /// Remove every install that lands at `path`. No-op when `path`
    /// has no install. Also drops the entry from the reverse-name
    /// index and from the basename mirror in ``commands`` when no
    /// other install with the same basename remains.
    public func uninstall(at path: String) {
        guard commandsByPath.removeValue(forKey: path) != nil else { return }
        let basename = (path as NSString).lastPathComponent
        if var paths = pathsByBasename[basename] {
            paths.removeAll { $0 == path }
            if paths.isEmpty {
                pathsByBasename.removeValue(forKey: basename)
                // Drop the basename mirror only when no path remains
                // and the slot wasn't taken over by a function or a
                // shell built-in.
                if !(commands[basename] is FunctionCommand)
                    && shellBuiltins[basename] == nil {
                    commands.removeValue(forKey: basename)
                }
            } else {
                pathsByBasename[basename] = paths
                // Refresh the basename mirror to point at the
                // most-recent surviving install.
                if let latest = paths.last,
                   let cmd = commandsByPath[latest] {
                    commands[basename] = cmd
                }
            }
        }
    }

    /// Remove every install whose basename matches `name`. Drops the
    /// reverse-index entry, every per-path entry, the basename mirror,
    /// AND any shell built-in registered under that name. Returns the
    /// number of installs removed (built-in counted once if dropped).
    @discardableResult
    public func uninstall(name: String) -> Int {
        var removed = 0
        if let paths = pathsByBasename.removeValue(forKey: name) {
            for path in paths
                where commandsByPath.removeValue(forKey: path) != nil {
                removed += 1
            }
        }
        if shellBuiltins.removeValue(forKey: name) != nil {
            removed += 1
        }
        // Only clear the basename mirror when no FunctionCommand still
        // claims that slot (functions live in `commands` directly).
        if !(commands[name] is FunctionCommand) {
            commands.removeValue(forKey: name)
        }
        return removed
    }

    // MARK: - Introspection

    /// `true` when `name` resolves to a user-defined shell function
    /// (the body installed by `name() { … }` / `function name { … }`).
    /// Used by `type`, `command -v`, and the dispatcher to honor the
    /// "function wins over built-in wins over PATH" precedence.
    public func isFunction(named name: String) -> Bool {
        commands[name] is FunctionCommand
    }

    // MARK: - Internal helpers

    private func installFileBacked(_ command: Command, at path: String) {
        let basename = (path as NSString).lastPathComponent
        // Replace any prior install at the same path, deduplicate the
        // basename → paths index, append the new path at the end so
        // most-recently-installed wins the basename mirror.
        commandsByPath[path] = command
        var paths = pathsByBasename[basename] ?? []
        paths.removeAll { $0 == path }
        paths.append(path)
        pathsByBasename[basename] = paths
        commands[basename] = command
    }
}
