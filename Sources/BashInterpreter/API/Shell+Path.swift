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
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch seg {
            case ".":
                continue
            case "..":
                // For absolute paths, `..` at the root stays at the
                // root. For relative paths we let `..` underflow as
                // a literal segment so callers can preserve the
                // user's intent (rare in practice).
                if !stack.isEmpty, stack.last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(seg))
            }
        }
        if isAbsolute {
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
