import ArgumentParser
import BashInterpreter

/// `touch PATH...` — create empty files, or update the modification
/// time of existing ones.
public struct TouchCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Create empty files or update modification time."
    )

    @Argument(help: "Paths to touch.")
    public var paths: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if paths.isEmpty {
            Shell.bashCurrent.stderr("touch: missing operand\n")
            return .failure
        }
        var hadError = false
        for path in paths {
            let resolved = Shell.bashCurrent.resolvePath(path)
            do {
                try await Shell.bashCurrent.fileSystem.touch(resolved)
            } catch {
                Shell.bashCurrent.stderr("touch: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
