import ArgumentParser
import BashInterpreter

/// `mkdir [-p] DIR...` — create one or more directories.
public struct MkdirCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mkdir",
        abstract: "Create directories."
    )

    @Argument(help: "Directories to create.")
    public var paths: [String] = []

    @Flag(name: [.short, .long],
          help: "Create parent directories as needed; ignore existing.")
    public var parents: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if paths.isEmpty {
            Shell.bashCurrent.stderr("mkdir: missing operand\n")
            return .failure
        }
        var hadError = false
        for path in paths {
            let resolved = Shell.bashCurrent.resolvePath(path)
            do {
                try await Shell.bashCurrent.fileSystem.createDirectory(
                    resolved, intermediates: parents)
            } catch FileSystemError.alreadyExists where parents {
                // `-p` treats existing as success.
                continue
            } catch {
                Shell.bashCurrent.stderr("mkdir: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
