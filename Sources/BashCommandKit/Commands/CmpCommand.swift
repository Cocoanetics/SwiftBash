import ArgumentParser
import BashInterpreter
import Foundation

/// `cmp [-s] FILE1 FILE2` — byte-by-byte comparison. Exit 0 if equal,
/// 1 if different, 2 on error. With `-s`, no output.
///
/// Either FILE argument may be `-`, which reads from standard input.
/// Only one `-` is allowed per invocation; stdin can't be replayed.
public struct CmpCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cmp",
        abstract: "Compare two files byte by byte."
    )

    @Flag(name: [.customShort("s"), .customLong("silent")],
          help: "Suppress output; exit status only.")
    public var silent: Bool = false

    @Argument(help: "FILE1 FILE2 (use - for stdin)")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard files.count == 2 else {
            Shell.bashCurrent.stderr("cmp: usage: cmp [-s] FILE1 FILE2\n")
            return ExitStatus(2)
        }
        if files[0] == "-" && files[1] == "-" {
            Shell.bashCurrent.stderr("cmp: standard input can only be used once\n")
            return ExitStatus(2)
        }
        let dataA: Data, dataB: Data
        do {
            dataA = try await readOperand(files[0])
            dataB = try await readOperand(files[1])
        } catch {
            Shell.bashCurrent.stderr("cmp: \(error)\n")
            return ExitStatus(2)
        }
        let count = min(dataA.count, dataB.count)
        var line = 1
        for idx in 0..<count {
            if dataA[idx] != dataB[idx] {
                if !silent {
                    Shell.bashCurrent.stdout("\(files[0]) \(files[1]) differ: char \(idx + 1), line \(line)\n")
                }
                return ExitStatus(1)
            }
            if dataA[idx] == 0x0A { line += 1 }
        }
        if dataA.count != dataB.count {
            if !silent {
                let longer = dataA.count > dataB.count ? files[0] : files[1]
                Shell.bashCurrent.stdout("cmp: EOF on \(longer)\n")
            }
            return ExitStatus(1)
        }
        return .success
    }

    private func readOperand(_ path: String) async throws -> Data {
        if path == "-" {
            return await Shell.bashCurrent.stdin.readAllData()
        }
        return try await Shell.bashCurrent.readDataAtPath(path)
    }
}
