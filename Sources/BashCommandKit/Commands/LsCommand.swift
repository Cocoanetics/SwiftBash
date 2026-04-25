import ArgumentParser
import BashInterpreter
import Foundation

/// `ls [PATH...]` — list directory contents. Multiple paths are
/// listed with a header line each, matching bash `/bin/ls`.
///
/// Supported flags:
/// - `-a` / `--all` — include hidden entries (those starting with `.`).
/// - `-1` — one entry per line (the default here; we don't column-
///   pack output, so this flag is a no-op kept for compatibility).
public struct LsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List directory contents."
    )

    @Argument(help: "Paths to list. Defaults to the current directory.")
    public var paths: [String] = []

    @Flag(name: [.short, .long], help: "Include hidden entries.")
    public var all: Bool = false

    @Flag(name: .customShort("1"), help: "One entry per line (default).")
    public var oneLine: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let targets = paths.isEmpty ? ["."] : paths
        var hadError = false

        for (i, path) in targets.enumerated() {
            let resolved = shell.resolvePath(path)
            let meta: FileMetadata?
            do {
                meta = try await shell.fileSystem.metadata(resolved)
            } catch {
                shell.stderr("ls: \(path): \(error)\n")
                hadError = true
                continue
            }
            guard let meta else {
                shell.stderr("ls: \(path): No such file or directory\n")
                hadError = true
                continue
            }

            if meta.kind != .directory {
                // Non-directory: print the path as given, matching bash.
                shell.stdout(path + "\n")
                continue
            }

            let entries: [String]
            do {
                entries = try await shell.fileSystem.list(resolved)
            } catch {
                shell.stderr("ls: \(path): \(error)\n")
                hadError = true
                continue
            }
            var visible = all ? entries : entries.filter { !$0.hasPrefix(".") }
            visible.sort()

            if targets.count > 1 {
                if i > 0 { shell.stdout("\n") }
                shell.stdout("\(path):\n")
            }
            for name in visible {
                shell.stdout(name + "\n")
            }
        }
        return hadError ? .failure : .success
    }
}
