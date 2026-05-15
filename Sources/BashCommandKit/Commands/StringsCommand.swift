import ArgumentParser
import BashInterpreter
import Foundation

/// `strings [-n MIN] [FILE...]` — extract printable runs from binary
/// input. Default minimum length is 4 bytes. ASCII-only.
public struct StringsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "strings",
        abstract: "Extract printable strings from a binary file."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    // Argv-loop branches add complexity by nature; the parsing is
    // already factored as cleanly as it can be without losing
    // legibility.
    // swiftlint:disable:next cyclomatic_complexity
    public mutating func execute() async throws -> ExitStatus {
        var minLen = 4
        var files: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-n" || arg == "--bytes" {
                guard index + 1 < rawArgv.count, let count = Int(rawArgv[index + 1]), count > 0 else {
                    Shell.bashCurrent.stderr("strings: -n requires positive N\n"); return ExitStatus(2)
                }
                minLen = count; index += 2; continue
            }
            if arg.hasPrefix("--bytes=") {
                guard let count = Int(arg.dropFirst("--bytes=".count)), count > 0 else {
                    Shell.bashCurrent.stderr("strings: invalid --bytes\n"); return ExitStatus(2)
                }
                minLen = count; index += 1; continue
            }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                if let count = Int(arg.dropFirst()), count > 0 {
                    minLen = count; index += 1; continue
                }
                Shell.bashCurrent.stderr("strings: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); index += 1
        }
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for file in inputs {
            try Task.checkCancellation()
            do {
                let data: Data
                if file == "-" {
                    data = await Shell.bashCurrent.stdin.readAllData()
                } else {
                    data = try await Shell.bashCurrent.readDataAtPath(file)
                }
                emit(data, minLen: minLen)
            } catch {
                Shell.bashCurrent.stderr("strings: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func emit(_ data: Data, minLen: Int) {
        var run = [UInt8]()
        for byte in data {
            // Printable ASCII: space (0x20) through tilde (0x7E), plus
            // tab as a common separator.
            if (byte >= 0x20 && byte <= 0x7E) || byte == 0x09 {
                run.append(byte)
            } else {
                if run.count >= minLen {
                    // Run is filtered to printable ASCII above, but a
                    // failable initializer keeps the rule happy.
                    Shell.bashCurrent.stdout((String(bytes: run, encoding: .utf8) ?? "") + "\n")
                }
                run.removeAll(keepingCapacity: true)
            }
        }
        if run.count >= minLen {
            Shell.bashCurrent.stdout((String(bytes: run, encoding: .utf8) ?? "") + "\n")
        }
    }
}
