import ArgumentParser
import BashInterpreter

/// `rm [-rf] PATH...` — remove files, and with `-r`, directories too.
public struct RmCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove files and directories."
    )

    @Argument(help: "Paths to remove.")
    public var paths: [String] = []

    @Flag(name: [.customShort("r"), .customLong("recursive"),
                 .customShort("R")],
          help: "Recurse into directories.")
    public var recursive: Bool = false

    @Flag(name: [.short, .long],
          help: "Ignore missing files and never prompt.")
    public var force: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if paths.isEmpty {
            if force { return .success }
            Shell.current.stderr("rm: missing operand\n")
            return .failure
        }
        var hadError = false
        for path in paths {
            let resolved = Shell.current.resolvePath(path)
            do {
                try await Shell.current.fileSystem.remove(resolved, recursive: recursive)
            } catch FileSystemError.notFound where force {
                continue
            } catch FileSystemError.isADirectory {
                Shell.current.stderr("rm: \(path): is a directory\n")
                hadError = true
            } catch {
                Shell.current.stderr("rm: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
