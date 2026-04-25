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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if paths.isEmpty {
            shell.stderr("rmdir: missing operand\n")
            return .failure
        }
        var hadError = false
        for path in paths {
            if !(await removeOne(path, shell: shell)) { hadError = true }
            if parents, !hadError {
                var p = (path as NSString).deletingLastPathComponent
                while !p.isEmpty, p != "." , p != "/" {
                    if !(await removeOne(p, shell: shell)) { break }
                    p = (p as NSString).deletingLastPathComponent
                }
            }
        }
        return hadError ? .failure : .success
    }

    /// Remove a single directory; reports stderr on failure and returns
    /// false. `FileSystem.remove(_:recursive:false)` errors when the
    /// directory isn't empty — exactly what `rmdir` is supposed to do.
    private func removeOne(_ path: String, shell: Shell) async -> Bool {
        let abs = shell.resolvePath(path)
        do {
            try await shell.fileSystem.remove(abs, recursive: false)
            return true
        } catch {
            shell.stderr("rmdir: \(path): \(error)\n")
            return false
        }
    }
}
