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
    ///
    /// On Windows, drive-letter paths (`C:\foo`, `c:/foo`) and UNC
    /// paths (`\\server\share`) count as absolute. The result uses
    /// forward-slash separators throughout — Windows file APIs
    /// accept both, and our split-on-`/` normalisation expects them.
    public func resolvePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        let absolute: String
        if Self.isAbsolutePath(expanded) {
            absolute = expanded
        } else {
            // Pure-Swift join — `NSString.appendingPathComponent`
            // works fine on both platforms, but keeping it inline
            // makes the relative-vs-absolute logic obvious.
            let base = environment.workingDirectory
            absolute = base.hasSuffix("/")
                ? base + expanded
                : base + "/" + expanded
        }
        return Self.normalizePath(absolute)
    }

    /// True for paths that don't need to be joined with the working
    /// directory: `/foo` everywhere, plus `C:\foo` / `C:/foo` / UNC
    /// (`\\server\share`) on Windows.
    static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        // Drive letter: `C:\…` or `C:/…`.
        let chars = Array(path)
        if chars.count >= 3,
           chars[0].isLetter,
           chars[1] == ":",
           chars[2] == "/" || chars[2] == "\\" {
            return true
        }
        // UNC roots: `\\server\share\…` or `//server/share/…`.
        if path.hasPrefix("\\\\") || path.hasPrefix("//") { return true }
        #endif
        return false
    }

    // NB: `normalizePath(_:)` — the lexical `.` / `..` / `//`
    // collapse this resolver relies on — moved down to
    // `ShellKit.Shell` with #83 so the shared `PathMapping` core and
    // this interpreter normalise identically. Call sites are
    // unchanged: the static is inherited. (`cd -L` / `pwd -L`
    // semantics rely on it being lexical; `cd -P` / `pwd -P` go
    // through ``FileSystem/canonicalize(_:allowMissing:)`` instead.)

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~"),
              let home = environment["HOME"], !home.isEmpty
        else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path // `~user` not supported
    }
}
