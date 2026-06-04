import ArgumentParser
import BashInterpreter
import Foundation

/// `realpath PATH...` — resolve each `PATH` to an absolute canonical
/// path with symlinks followed and `.`/`..` components normalised,
/// printing one resolved line per argument.
///
/// By default each path must exist. Pass `-m` / `--missing` to allow
/// non-existent path components (logical resolution only). Exit status
/// is non-zero if any argument fails to resolve.
public struct RealpathCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "realpath",
        abstract: "Resolve a path to its canonical absolute form."
    )

    @Argument(help: "Path(s) to resolve.")
    public var paths: [String] = []

    @Flag(name: [.short, .long],
          help: "Allow path components that don't exist.")
    public var missing: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard !paths.isEmpty else {
            Shell.bashCurrent.stderr("realpath: missing operand\n")
            return ExitStatus(1)
        }
        var hadError = false
        for path in paths {
            let absolute = Shell.bashCurrent.resolvePath(path)
            do {
                let resolved = try await Shell.bashCurrent.fileSystem.canonicalize(
                    absolute, allowMissing: missing)
                Shell.bashCurrent.stdout(resolved + "\n")
            } catch FileSystemError.notFound {
                Shell.bashCurrent.stderr(
                    "realpath: \(path): No such file or directory\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
