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
    static func isAbsolutePath(_ p: String) -> Bool {
        if p.hasPrefix("/") { return true }
        #if os(Windows)
        // Drive letter: `C:\…` or `C:/…`.
        let chars = Array(p)
        if chars.count >= 3,
           chars[0].isLetter,
           chars[1] == ":",
           chars[2] == "/" || chars[2] == "\\"
        {
            return true
        }
        // UNC roots: `\\server\share\…` or `//server/share/…`.
        if p.hasPrefix("\\\\") || p.hasPrefix("//") { return true }
        #endif
        return false
    }

    /// Lexical path normalisation — collapses `.` / `..` / repeated
    /// `/` purely as text, never touching the filesystem. **Does not
    /// resolve symlinks** (that's what `cd -L` / `pwd -L` semantics
    /// rely on; `cd -P` / `pwd -P` go through
    /// ``FileSystem/canonicalize(_:allowMissing:)`` instead).
    ///
    /// Replaces `NSString.standardizingPath`, which is technically
    /// supposed to be lexical but on swift-corelibs-foundation
    /// (Linux) follows symlinks too — making `cd -L /var` set `$PWD`
    /// to `/private/var` instead of preserving `/var`.
    ///
    /// On Windows, backslashes are normalised to forward slashes
    /// up front (Win32 path APIs accept both). Drive-letter paths
    /// keep their `C:` prefix as the root segment so the result is
    /// still a valid Windows path: `C:\Users\foo\..\bar` → `C:/Users/bar`.
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        #if os(Windows)
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        #else
        let normalized = path
        #endif
        // Split on `/`, tracking whether the path is anchored at the
        // root (Unix `/foo`) or at a drive (Windows `C:/foo`). For a
        // drive-letter path we keep the `C:` segment in the stack so
        // the rebuilt string still stems from that drive.
        let isUnixAbsolute = normalized.hasPrefix("/")
        var stack: [String] = []
        var driveRoot: String? = nil
        var saw: [Substring] = normalized.split(
            separator: "/", omittingEmptySubsequences: true)
        #if os(Windows)
        // Detect a leading `C:` segment (drive root). After we
        // record it, the rest of the segments are walked as if the
        // path were absolute beneath that drive.
        if let first = saw.first,
           first.count == 2,
           let firstChar = first.first, firstChar.isLetter,
           first.last == ":"
        {
            driveRoot = String(first)
            saw = Array(saw.dropFirst())
        }
        #endif
        let anchored = isUnixAbsolute || driveRoot != nil
        for seg in saw {
            switch seg {
            case ".":
                continue
            case "..":
                // For anchored paths, `..` at the root stays at the
                // root. For relative paths we let `..` underflow as
                // a literal segment so callers can preserve the
                // user's intent (rare in practice).
                if !stack.isEmpty, stack.last != ".." {
                    stack.removeLast()
                } else if !anchored {
                    stack.append("..")
                }
            default:
                stack.append(String(seg))
            }
        }
        if let driveRoot {
            return driveRoot + "/" + stack.joined(separator: "/")
        }
        if isUnixAbsolute {
            return "/" + stack.joined(separator: "/")
        }
        return stack.isEmpty ? "." : stack.joined(separator: "/")
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
