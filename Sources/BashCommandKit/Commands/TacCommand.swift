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

    public mutating func execute() async throws -> ExitStatus {
        if files.isEmpty {
            var lines: [String] = []
            for await line in Shell.bashCurrent.stdin.lines { lines.append(line) }
            for line in lines.reversed() { Shell.bashCurrent.stdout(line + "\n") }
            return .success
        }
        var hadError = false
        for file in files {
            try Task.checkCancellation()
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(file)
                // tac input may legitimately contain non-UTF-8 byte sequences
                // swiftlint:disable:next optional_data_string_conversion
                let text = String(decoding: data, as: UTF8.self)
                for line in SortCommand.splitLines(text).reversed() {
                    try Task.checkCancellation()
                    Shell.bashCurrent.stdout(line + "\n")
                }
            } catch {
                Shell.bashCurrent.stderr("tac: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
