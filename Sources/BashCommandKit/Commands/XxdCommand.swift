import ArgumentParser
import BashInterpreter
import Foundation

/// `xxd [FILE]` — make a hex dump of FILE (or stdin).
///
/// Default output: 16 bytes per row, hex grouped in 2-byte pairs, ASCII
/// rendering on the right. Non-printable bytes show as `.`.
///
/// ```
/// 00000000: 6865 6c6c 6f20 776f 726c 640a            hello world.
/// ```
///
/// Out of scope for v1: `-r` reverse mode, `-p` plain mode, `-c COLS`,
/// `-g GROUPSIZE`, `-s SEEK`, `-l LEN`. Defaults match macOS / vim
/// `xxd`.
public struct XxdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "xxd",
        abstract: "Hex dump (default 16-byte rows)."
    )

    @Argument(help: "Input file. Reads stdin if empty.")
    public var input: String?

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let data: Data
        if let f = input, f != "-" {
            do {
                data = try await Shell.current.readDataAtPath(f)
            } catch {
                Shell.current.stderr("xxd: \(f): \(error)\n")
                return .failure
            }
        } else {
            data = await Shell.current.stdin.readAllData()
        }

        let bytesPerRow = 16
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            // Per-row check — for a 1 GiB hex dump (~67M rows) this
            // means cancellation lands within microseconds.
            try Task.checkCancellation()
            let end = min(offset + bytesPerRow, bytes.count)
            let row = bytes[offset..<end]
            Shell.current.stdout(Self.format(offset: offset,
                                     row: Array(row),
                                     bytesPerRow: bytesPerRow) + "\n")
            offset = end
        }
        return .success
    }

    /// Render one xxd row. The hex column always has a fixed width so
    /// short trailing rows still align with the ASCII column.
    static func format(offset: Int, row: [UInt8],
                       bytesPerRow: Int) -> String {
        var hex = ""
        for i in 0..<bytesPerRow {
            if i < row.count {
                hex += String(format: "%02x", row[i])
            } else {
                hex += "  "
            }
            // Group in pairs of 2 bytes (4 hex chars).
            if i % 2 == 1, i + 1 < bytesPerRow {
                hex += " "
            }
        }
        var ascii = ""
        for b in row {
            // Match xxd: only printable ASCII (0x20..0x7e); everything
            // else (including tab/newline) becomes `.`.
            ascii.append(
                (b >= 0x20 && b <= 0x7e)
                    ? Character(UnicodeScalar(b))
                    : ".")
        }
        return String(format: "%08x: %@  %@",
                      offset,
                      hex as NSString,
                      ascii as NSString)
    }
}
