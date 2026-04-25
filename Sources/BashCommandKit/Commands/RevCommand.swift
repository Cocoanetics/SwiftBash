import ArgumentParser
import BashInterpreter
import Foundation

/// `rev [FILE...]` — reverse the characters of each input line.
///
/// Reversal is by extended grapheme cluster (`Character`), so combining
/// marks and emoji ZWJ sequences stay intact.
public struct RevCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rev",
        abstract: "Reverse each line's characters."
    )

    @Argument(help: "Files to reverse. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if files.isEmpty {
            for await line in shell.stdin.lines {
                shell.stdout(String(line.reversed()) + "\n")
            }
            return .success
        }
        var hadError = false
        for f in files {
            do {
                let data = try await shell.readDataAtPath(f)
                let text = String(decoding: data, as: UTF8.self)
                for line in SortCommand.splitLines(text) {
                    shell.stdout(String(line.reversed()) + "\n")
                }
            } catch {
                shell.stderr("rev: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
