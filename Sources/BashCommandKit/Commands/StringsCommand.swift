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

    public mutating func execute() async throws -> ExitStatus {
        var minLen = 4
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-n" || a == "--bytes" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.bashCurrent.stderr("strings: -n requires positive N\n"); return ExitStatus(2)
                }
                minLen = n; i += 2; continue
            }
            if a.hasPrefix("--bytes=") {
                guard let n = Int(a.dropFirst("--bytes=".count)), n > 0 else {
                    Shell.bashCurrent.stderr("strings: invalid --bytes\n"); return ExitStatus(2)
                }
                minLen = n; i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                if let n = Int(a.dropFirst()), n > 0 { minLen = n; i += 1; continue }
                Shell.bashCurrent.stderr("strings: unknown option: \(a)\n"); return ExitStatus(2)
            }
            files.append(a); i += 1
        }
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            try Task.checkCancellation()
            do {
                let data: Data
                if f == "-" { data = await Shell.bashCurrent.stdin.readAllData() }
                else { data = try await Shell.bashCurrent.readDataAtPath(f) }
                emit(data, minLen: minLen)
            } catch {
                Shell.bashCurrent.stderr("strings: \(f): \(error)\n")
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
                    Shell.bashCurrent.stdout(String(decoding: run, as: UTF8.self) + "\n")
                }
                run.removeAll(keepingCapacity: true)
            }
        }
        if run.count >= minLen {
            Shell.bashCurrent.stdout(String(decoding: run, as: UTF8.self) + "\n")
        }
    }
}
