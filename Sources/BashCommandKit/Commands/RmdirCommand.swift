import ArgumentParser
import BashInterpreter
import Foundation

/// `rmdir [-p] DIR...` — remove *empty* directories.
///
/// Errors out (non-zero exit) on non-empty directories or non-existent
/// paths. Use `rm -r` for recursive removal.
///
/// With `-p`, also removes each parent directory of the named path,
/// stopping at the first non-empty one (`rmdir -p a/b/c` removes `c`,
/// then `b`, then `a`).
public struct RmdirCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rmdir",
        abstract: "Remove empty directories."
    )

    @Argument(help: "Directories to remove.")
    public var paths: [String] = []

    @Flag(name: [.customShort("p"), .customLong("parents")],
          help: "Also remove parent directories that become empty.")
    public var parents: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if paths.isEmpty {
            Shell.bashCurrent.stderr("rmdir: missing operand\n")
            return .failure
        }
        var hadError = false
        for path in paths {
            if !(await removeOne(path)) { hadError = true }
            if parents, !hadError {
                var p = Self.parentPath(path)
                while !p.isEmpty, p != "." , p != "/" {
                    if !(await removeOne(p)) { break }
                    p = Self.parentPath(p)
                }
            }
        }
        return hadError ? .failure : .success
    }

    /// Pure-Swift `dirname`-style parent path. Use this rather than
    /// `NSString.deletingLastPathComponent`, which has surfaced a
    /// SIGILL trap on swift-corelibs-foundation in recursive call
    /// patterns. We don't actually need NSString here — it's a
    /// 10-line string split.
    static func parentPath(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path == "/" { return "/" }
        // Drop trailing slashes (preserve a bare leading "/").
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        guard let i = s.lastIndex(of: "/") else {
            return ""             // single component → no parent
        }
        if i == s.startIndex { return "/" }   // e.g. "/a" → "/"
        return String(s[..<i])
    }

    /// Remove a single directory; reports stderr on failure and returns
    /// false. `FileSystem.remove(_:recursive:false)` errors when the
    /// directory isn't empty — exactly what `rmdir` is supposed to do.
    private func removeOne(_ path: String) async -> Bool {
        let abs = Shell.bashCurrent.resolvePath(path)
        do {
            try await Shell.bashCurrent.fileSystem.remove(abs, recursive: false)
            return true
        } catch {
            Shell.bashCurrent.stderr("rmdir: \(path): \(error)\n")
            return false
        }
    }
}
