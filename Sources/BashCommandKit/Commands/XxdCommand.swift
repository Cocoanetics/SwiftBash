import ArgumentParser
import BashInterpreter
import Foundation

/// `xxd [-l LEN] [-g GROUPSIZE] [FILE]` — make a hex dump of FILE (or
/// stdin).
///
/// Default output: 16 bytes per row, hex grouped in 2-byte pairs, ASCII
/// rendering on the right. Non-printable bytes show as `.`.
///
/// ```
/// 00000000: 6865 6c6c 6f20 776f 726c 640a            hello world.
/// ```
///
/// `-l LEN` stops after LEN bytes (decimal, `0x…` hex, or `0…` octal);
/// `-g GROUPSIZE` sets bytes per hex group (`-g0` = one continuous
/// run). Both accept the attached (`-g1`) and separated (`-g 1`) forms.
/// Out of scope: `-r` reverse, `-p` plain, `-c COLS`, `-s SEEK`.
public struct XxdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "xxd",
        abstract: "Hex dump (default 16-byte rows)."
    )

    // Hand-rolled option scan (see ``CLIOptionScanner``) so the attached
    // short forms GNU/BSD users expect — `-g1`, `-l0x40` — parse, which
    // the ArgumentParser bridge rejects for value-bearing short options.
    @Argument(parsing: .captureForPassthrough,
              help: "[-l LEN] [-g N] [FILE]")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard let options = parseArguments() else { return ExitStatus(2) }

        let data: Data
        if let file = options.file, file != "-" {
            do {
                data = try await Shell.bashCurrent.readDataAtPath(file)
            } catch {
                Shell.bashCurrent.stderr("xxd: \(file): \(error)\n")
                return .failure
            }
        } else {
            data = await Shell.bashCurrent.stdin.readAllData()
        }

        // `-l N` truncates the input to the first N bytes before
        // hex-dumping. Real xxd accepts decimal (`-l 64`), `0x`-
        // prefixed hex (`-l 0x40`), or `0`-prefixed octal (`-l 0100`);
        // we honour the common decimal and hex forms.
        let truncated: Data
        if let lengthString = options.length {
            guard let limit = Self.parseLength(lengthString), limit >= 0 else {
                Shell.bashCurrent.stderr(
                    "xxd: invalid length: \(lengthString)\n")
                return ExitStatus(2)
            }
            truncated = data.prefix(min(limit, data.count))
        } else {
            truncated = data
        }

        let bytesPerRow = 16
        var offset = 0
        let bytes = [UInt8](truncated)
        while offset < bytes.count {
            // Per-row check — for a 1 GiB hex dump (~67M rows) this
            // means cancellation lands within microseconds.
            try Task.checkCancellation()
            let end = min(offset + bytesPerRow, bytes.count)
            Shell.bashCurrent.stdout(Self.format(offset: offset,
                                     row: Array(bytes[offset..<end]),
                                     bytesPerRow: bytesPerRow,
                                     groupSize: options.groupSize) + "\n")
            offset = end
        }
        return .success
    }

    private struct Options {
        var length: String?
        var groupSize: Int = 2
        var file: String?
    }

    /// Scan `rawArgv`. Emits a diagnostic and returns `nil` on a bad
    /// option (the caller then exits 2).
    private func parseArguments() -> Options? {
        var options = Options()
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                if index < rawArgv.count { options.file = rawArgv[index] }
                break
            }
            if arg == "-" || !arg.hasPrefix("-") {
                options.file = arg; index += 1; continue
            }
            if let match = CLIOptionScanner.value(
                arg, short: "l", long: "len", argv: rawArgv, at: index) {
                options.length = match.value; index += match.advance; continue
            }
            if let match = CLIOptionScanner.value(
                arg, short: "g", long: "groupsize", argv: rawArgv, at: index) {
                guard let parsed = Int(match.value), parsed >= 0 else {
                    Shell.bashCurrent.stderr(
                        "xxd: invalid group size: \(match.value)\n")
                    return nil
                }
                options.groupSize = parsed; index += match.advance; continue
            }
            Shell.bashCurrent.stderr("xxd: invalid option: \(arg)\n")
            return nil
        }
        return options
    }

    /// Parse `-l N` argument: decimal (`64`), `0x`-prefixed hex
    /// (`0x40`), or `0`-prefixed octal (`0100`). Returns nil for
    /// anything else (negative numbers, garbage, overflow). Mirrors
    /// the syntax real xxd accepts.
    static func parseLength(_ str: String) -> Int? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        if trimmed.hasPrefix("0"), trimmed.count > 1,
           trimmed.dropFirst().allSatisfy({ $0.isNumber }) {
            return Int(trimmed, radix: 8)
        }
        return Int(trimmed, radix: 10)
    }

    /// Render one xxd row. The hex column always has a fixed width so
    /// short trailing rows still align with the ASCII column.
    static func format(offset: Int, row: [UInt8],
                       bytesPerRow: Int, groupSize: Int) -> String {
        var hex = ""
        for idx in 0..<bytesPerRow {
            if idx < row.count {
                hex += String(format: "%02x", row[idx])
            } else {
                hex += "  "
            }
            // Separator after every `groupSize` bytes (0 = no grouping).
            // Skipped after the final byte so short rows still align.
            if groupSize > 0, (idx + 1) % groupSize == 0, idx + 1 < bytesPerRow {
                hex += " "
            }
        }
        var ascii = ""
        for byte in row {
            // Match xxd: only printable ASCII (0x20..0x7e); everything
            // else (including tab/newline) becomes `.`.
            ascii.append(
                (byte >= 0x20 && byte <= 0x7e)
                    ? Character(UnicodeScalar(byte))
                    : ".")
        }
        return String(format: "%08x: %@  %@",
                      offset,
                      hex as NSString,
                      ascii as NSString)
    }
}
