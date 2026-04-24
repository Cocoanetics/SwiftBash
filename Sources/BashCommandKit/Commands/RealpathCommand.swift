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
        let expanded = expandTilde(path, home: shell.environment["HOME"])
        let base = expanded.hasPrefix("/")
            ? expanded
            : (shell.environment.workingDirectory as NSString)
                .appendingPathComponent(expanded)

        let url = URL(fileURLWithPath: base)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
        let resolved = url.path

        if !missing, !FileManager.default.fileExists(atPath: resolved) {
            shell.stderr("realpath: \(path): No such file or directory\n")
            return .failure
        }

        shell.stdout(resolved + "\n")
        return .success
    }

    private func expandTilde(_ path: String, home: String?) -> String {
        guard path.hasPrefix("~"), let home, !home.isEmpty else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path // `~user` not supported in this minimal build
    }
}
