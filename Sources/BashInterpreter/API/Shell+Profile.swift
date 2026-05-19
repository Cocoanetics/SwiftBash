import Foundation

extension Shell {

    /// Source `~/.profile` and `~/.bashrc` (in that order) into the
    /// running shell, skipping files that don't exist on disk.
    ///
    /// Real bash sources these once at session startup so the user's
    /// `export PATH=...`, aliases, and PS1 customisation apply for
    /// the whole REPL. SwiftBash doesn't do that automatically —
    /// embedders building an interactive shell call this once before
    /// the first user keystroke.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerStandardCommands()
    /// shell.registerBashShebang()
    /// try await shell.sourceProfileIfPresent(at: sandboxRoot)
    /// ```
    ///
    /// Reads through ``Shell/fileSystem``, so a ``MountedFileSystem``
    /// gates this — a profile sitting outside the sandbox is silently
    /// ignored, the same way a missing one is. Use ``filenames:`` to
    /// add `.bash_profile`, `.zshrc`, etc.
    @discardableResult
    public func sourceProfileIfPresent(
        at home: URL,
        filenames: [String] = [".profile", ".bashrc"]
    ) async throws -> [String] {
        var sourced: [String] = []
        for name in filenames {
            let path = home.appendingPathComponent(name).path
            let meta = try? await fileSystem.metadata(path)
            guard let meta = meta ?? nil, meta.kind == .file else { continue }
            guard let data = try? await fileSystem.readData(path),
                  let body = String(data: data, encoding: .utf8)
            else { continue }
            _ = try await run(body)
            sourced.append(name)
        }
        return sourced
    }
}
