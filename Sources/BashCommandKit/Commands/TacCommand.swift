import ArgumentParser
import BashInterpreter
import Foundation

/// `tac [FILE...]` — print lines in reverse order.
///
/// With no FILE, reverses lines read from stdin. With multiple files,
/// each file is reversed independently and emitted in the order given.
public struct TacCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tac",
        abstract: "Print lines in reverse order."
    )

    @Argument(help: "Files to reverse. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if files.isEmpty {
            var lines: [String] = []
            for await line in shell.stdin.lines { lines.append(line) }
            for line in lines.reversed() { shell.stdout(line + "\n") }
            return .success
        }
        var hadError = false
        for f in files {
            do {
                let data = try await shell.readDataAtPath(f)
                let text = String(decoding: data, as: UTF8.self)
                for line in SortCommand.splitLines(text).reversed() {
                    shell.stdout(line + "\n")
                }
            } catch {
                shell.stderr("tac: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
