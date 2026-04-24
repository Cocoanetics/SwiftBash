import ArgumentParser
import BashInterpreter
import Foundation

/// `cat [FILE...]` — concatenate file contents to stdout. With no
/// files, copies stdin through unchanged (useful in pipelines).
public struct CatCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Concatenate files (or stdin) to stdout."
    )

    @Argument(help: "Files to read. When empty, reads stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) throws -> ExitStatus {
        if files.isEmpty {
            shell.stdout(shell.stdin)
            return .success
        }
        var hadError = false
        for path in files {
            if path == "-" {
                shell.stdout(shell.stdin)
                continue
            }
            do {
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                shell.stdout(contents)
            } catch {
                shell.stderr("cat: \(path): \(error.localizedDescription)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
