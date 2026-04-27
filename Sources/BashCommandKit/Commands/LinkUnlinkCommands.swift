import ArgumentParser
import BashInterpreter
import Foundation

/// `link FILE1 FILE2` — create a hard link `FILE2` pointing at the
/// same inode as `FILE1`. POSIX-mandated thin wrapper around
/// ``FileSystem/hardlink(target:at:)``; for the friendlier `-s`
/// variant use `ln`.
public struct LinkCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Create a hard link between two files."
    )

    @Argument(help: "Existing file.")
    public var source: String = ""

    @Argument(help: "Path of the new hard link.")
    public var destination: String = ""

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let src = Shell.current.resolvePath(source)
        let dst = Shell.current.resolvePath(destination)
        do {
            try await Shell.current.fileSystem.hardlink(target: src, at: dst)
            return .success
        } catch {
            Shell.current.stderr("link: \(destination): \(error)\n")
            return .failure
        }
    }
}

/// `unlink FILE` — remove a single file. POSIX-mandated thin
/// wrapper around ``FileSystem/remove(_:recursive:)``; refuses to
/// remove directories (use `rmdir` or `rm -r`).
public struct UnlinkCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Remove a single file."
    )

    @Argument(help: "File to remove.")
    public var path: String = ""

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let resolved = Shell.current.resolvePath(path)
        do {
            let meta = try await Shell.current.fileSystem.metadata(resolved)
            if meta?.kind == .directory {
                Shell.current.stderr(
                    "unlink: \(path): is a directory\n")
                return .failure
            }
            try await Shell.current.fileSystem.remove(resolved, recursive: false)
            return .success
        } catch {
            Shell.current.stderr("unlink: \(path): \(error)\n")
            return .failure
        }
    }
}
