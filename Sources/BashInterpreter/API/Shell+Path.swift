import Foundation

extension Shell {

    /// Resolve a user-supplied path into an absolute one suitable for
    /// handing to ``fileSystem``:
    ///
    /// - Leading `~` / `~/…` is expanded against `$HOME`.
    /// - Relative paths are resolved against
    ///   ``Environment/workingDirectory``.
    /// - `.` and `..` components are normalised.
    ///
    /// The result is *not* symlink-resolved — call
    /// ``FileSystem/canonicalize(_:allowMissing:)`` for that.
    public func resolvePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            let base = environment.workingDirectory
            absolute = (base as NSString).appendingPathComponent(expanded)
        }
        return (absolute as NSString).standardizingPath
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~"),
              let home = environment["HOME"], !home.isEmpty
        else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path // `~user` not supported
    }
}
