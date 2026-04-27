import ArgumentParser
import BashInterpreter
import Foundation

/// `od [-c] [-x] [-b] [FILE]` — octal (default) / character / hex dump.
///
/// Default rows pack 16 bytes; the address column is octal (matching
/// `od`'s tradition). Pick *one* mode flag — multiple just last-wins.
///
/// - default / `-b`: octal bytes, each `\000`–`\377`
/// - `-x`: 2-byte hex words (little-endian byte order on the host)
/// - `-c`: characters with C-style escapes (`\n`, `\t`, …) for
///   non-printables
///
/// Out of scope (low-frequency): `-A` address radix override,
/// `-N COUNT`, `-j SKIP`, `-t TYPE` arbitrary type strings.
public struct OdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "od",
        abstract: "Dump bytes in octal / hex / character format."
    )

    @Flag(name: .customShort("b"), help: "Octal bytes (the default).")
    public var octal: Bool = false

    @Flag(name: .customShort("x"), help: "Two-byte hex words.")
    public var hex: Bool = false

    @Flag(name: .customShort("c"),
          help: "Characters with C-style escapes for non-printables.")
    public var chars: Bool = false

    @Argument(help: "Input file. Reads stdin if empty.")
    public var input: String?

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let data: Data
        if let f = input, f != "-" {
            do {
                data = try await Shell.current.readDataAtPath(f)
            } catch {
                Shell.current.stderr("od: \(f): \(error)\n")
                return .failure
            }
        } else {
            data = await Shell.current.stdin.readAllData()
        }

        let mode: Mode = chars ? .chars : (hex ? .hex : .octal)
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 16, bytes.count)
            Shell.current.stdout(format(offset: offset,
                                row: Array(bytes[offset..<end]),
                                mode: mode) + "\n")
            offset = end
        }
        // od traditionally prints the final offset on a line of its own.
        Shell.current.stdout(String(format: "%07o", bytes.count) + "\n")
        return .success
    }

    private enum Mode { case octal, hex, chars }

    private func format(offset: Int, row: [UInt8], mode: Mode) -> String {
        let prefix = String(format: "%07o ", offset)
        switch mode {
        case .octal:
            return prefix + row.map { String(format: " %03o", $0) }.joined()
        case .hex:
            // Two-byte words. Pad an odd trailing byte with 0 so the
            // word still renders.
            var words: [String] = []
            var i = 0
            while i < row.count {
                let lo = UInt16(row[i])
                let hi = i + 1 < row.count ? UInt16(row[i + 1]) : 0
                let word = (hi << 8) | lo
                words.append(String(format: " %04x", word))
                i += 2
            }
            return prefix + words.joined()
        case .chars:
            return prefix + row.map { Self.escapeChar($0) }.joined()
        }
    }

    /// Render one byte the way `od -c` does — single-letter escape
    /// where defined, octal escape otherwise, printable ASCII as-is.
    /// Output is right-aligned in a 3-column slot with one leading
    /// space, matching `od -c`'s row formatting.
    static func escapeChar(_ b: UInt8) -> String {
        let token: String
        switch b {
        case 0x00: token = "\\0"
        case 0x07: token = "\\a"
        case 0x08: token = "\\b"
        case 0x09: token = "\\t"
        case 0x0A: token = "\\n"
        case 0x0B: token = "\\v"
        case 0x0C: token = "\\f"
        case 0x0D: token = "\\r"
        default:
            if b >= 0x20 && b <= 0x7E {
                token = String(UnicodeScalar(b))
            } else {
                token = String(format: "\\%03o", b)
            }
        }
        // Right-align in a 3-char slot, then prefix with a single space.
        // Avoid `String(format: "%s", …)` since that wants a C string;
        // passing an NSString bridge there is undefined behaviour.
        let pad = max(0, 3 - token.count)
        return " " + String(repeating: " ", count: pad) + token
    }
}
