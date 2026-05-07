import ArgumentParser
import BashInterpreter
import Foundation

/// `cmp [-s] FILE1 FILE2` — byte-by-byte comparison. Exit 0 if equal,
/// 1 if different, 2 on error. With `-s`, no output.
public struct CmpCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cmp",
        abstract: "Compare two files byte by byte."
    )

    @Flag(name: [.customShort("s"), .customLong("silent")],
          help: "Suppress output; exit status only.")
    public var silent: Bool = false

    @Argument(help: "FILE1 FILE2")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard files.count == 2 else {
            Shell.bashCurrent.stderr("cmp: usage: cmp [-s] FILE1 FILE2\n")
            return ExitStatus(2)
        }
        let a: Data, b: Data
        do {
            a = try await Shell.bashCurrent.readDataAtPath(files[0])
            b = try await Shell.bashCurrent.readDataAtPath(files[1])
        } catch {
            Shell.bashCurrent.stderr("cmp: \(error)\n")
            return ExitStatus(2)
        }
        let n = min(a.count, b.count)
        var line = 1
        for i in 0..<n {
            if a[i] != b[i] {
                if !silent {
                    Shell.bashCurrent.stdout("\(files[0]) \(files[1]) differ: char \(i + 1), line \(line)\n")
                }
                return ExitStatus(1)
            }
            if a[i] == 0x0A { line += 1 }
        }
        if a.count != b.count {
            if !silent {
                let longer = a.count > b.count ? files[0] : files[1]
                Shell.bashCurrent.stdout("cmp: EOF on \(longer)\n")
            }
            return ExitStatus(1)
        }
        return .success
    }
}
