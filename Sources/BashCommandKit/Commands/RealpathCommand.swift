import ArgumentParser
import BashInterpreter
import Foundation

/// `realpath PATH` — resolve `PATH` to an absolute canonical path with
/// symlinks followed and `.`/`..` components normalised.
///
/// By default the path must exist. Pass `-m` / `--missing` to allow
/// non-existent path components (logical resolution only).
public struct RealpathCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "realpath",
        abstract: "Resolve a path to its canonical absolute form."
    )

    @Argument(help: "Path to resolve.")
    public var path: String

    @Flag(name: [.short, .long],
          help: "Allow path components that don't exist.")
    public var missing: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let absolute = shell.resolvePath(path)
        do {
            let resolved = try await shell.fileSystem.canonicalize(
                absolute, allowMissing: missing)
            shell.stdout(resolved + "\n")
            return .success
        } catch FileSystemError.notFound {
            shell.stderr("realpath: \(path): No such file or directory\n")
            return .failure
        }
    }
}
