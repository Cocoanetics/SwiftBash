import ArgumentParser
import BashInterpreter
import Foundation

/// `od [-A RADIX] [-N COUNT] [-t TYPE] [-b] [-x] [-c] [FILE]` — dump
/// bytes in octal / hex / decimal / character form.
///
/// Rows pack 16 bytes. `-A RADIX` sets the address-column base (`o`
/// octal [default], `d`, `x`, or `n` = none). `-N COUNT` formats at
/// most COUNT bytes. `-t TYPE` selects an output type:
///   - `x[1248]` hex, `o[1248]` octal, `u[1248]` unsigned decimal,
///     `d[1248]` signed decimal (the digit is bytes-per-unit,
///     default 4), and
///   - `c` named / escaped characters.
///
/// Options accept both attached (`-tx1`, `-An`, `-N64`) and separated
/// (`-t x1`) forms. Legacy `-b` (octal bytes), `-x` (2-byte hex words)
/// and `-c` (characters) are kept as shorthands and render exactly as
/// before.
///
/// Out of scope: `-j SKIP`, letter sizes (`dI` / `xL` …), the `a`
/// named type, and stacking multiple `-t` specs per row.
public struct OdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "od",
        abstract: "Dump bytes in octal / hex / decimal / character format."
    )

    // Hand-rolled scan (see ``CLIOptionScanner``) so attached short
    // options — `-An`, `-tx1`, `-N64` — parse the way GNU/BSD `od`
    // accepts them; the ArgumentParser bridge only takes the
    // separated form for value-bearing short options.
    @Argument(parsing: .captureForPassthrough,
              help: "[-A RADIX] [-N COUNT] [-t TYPE] [-b|-x|-c] [FILE]")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard let options = parseArguments() else { return ExitStatus(1) }

        let input = await readInput(options.files)

        var bytes = [UInt8](input.data)
        if let limit = options.readLimit { bytes = Array(bytes.prefix(limit)) }

        // `-t` selects the GNU-style typed renderer; otherwise fall
        // back to the legacy `-b`/`-x`/`-c` modes (kept byte-for-byte).
        if let type = options.type {
            try renderTyped(bytes: bytes, type: type, radix: options.radix)
        } else {
            try renderLegacy(bytes: bytes, mode: options.mode,
                             radix: options.radix)
        }
        // Dump whatever was read, then report failure if any operand was
        // unreadable — a bad trailing path must not discard valid output
        // already accepted from earlier operands (GNU od).
        return input.allRead ? .success : .failure
    }

    /// Read all operands concatenated (GNU od); an empty list or `-`
    /// means stdin. On a read failure it emits a diagnostic, skips that
    /// operand, and keeps going, so bytes already read from earlier (and
    /// later readable) operands are still returned. `ok` is false when
    /// any operand failed.
    private func readInput(_ files: [String]) async
        -> (data: Data, allRead: Bool) {
        if files.isEmpty {
            return (await Shell.bashCurrent.stdin.readAllData(), true)
        }
        var combined = Data()
        var allRead = true
        for file in files {
            if file == "-" {
                combined.append(await Shell.bashCurrent.stdin.readAllData())
                continue
            }
            do {
                combined.append(
                    try await Shell.bashCurrent.readDataAtPath(file))
            } catch {
                Shell.bashCurrent.stderr("od: \(file): \(error)\n")
                allRead = false
            }
        }
        return (combined, allRead)
    }

    // MARK: - Argument parsing

    private struct Options {
        var mode: Mode = .octal
        var radix: AddressRadix = .octal
        var readLimit: Int?
        var type: OdOutputType?
        var files: [String] = []
    }

    // Scan `rawArgv`. Emits a diagnostic and returns `nil` on any bad
    // option (the caller then exits 1).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseArguments() -> Options? {
        var options = Options()
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count {
                    options.files.append(rawArgv[index]); index += 1
                }
                break
            }
            switch arg {
            case "-b": options.mode = .octal; index += 1; continue
            case "-x": options.mode = .hex; index += 1; continue
            case "-c": options.mode = .chars; index += 1; continue
            default: break
            }
            if let match = CLIOptionScanner.value(
                arg, short: "A", long: "address-radix", argv: rawArgv, at: index) {
                guard let radix = AddressRadix(parsing: match.value) else {
                    Shell.bashCurrent.stderr(
                        "od: invalid address base '\(match.value)'\n")
                    return nil
                }
                options.radix = radix; index += match.advance; continue
            }
            if let match = CLIOptionScanner.value(
                arg, short: "N", long: "read-bytes", argv: rawArgv, at: index) {
                guard let count = Int(match.value), count >= 0 else {
                    Shell.bashCurrent.stderr(
                        "od: invalid byte count: \(match.value)\n")
                    return nil
                }
                options.readLimit = count; index += match.advance; continue
            }
            if let match = CLIOptionScanner.value(
                arg, short: "t", long: "format", argv: rawArgv, at: index) {
                guard let type = OdOutputType(parsing: match.value) else {
                    Shell.bashCurrent.stderr(
                        "od: invalid type string '\(match.value)'\n")
                    return nil
                }
                options.type = type; index += match.advance; continue
            }
            if arg == "-" || !arg.hasPrefix("-") {
                options.files.append(arg); index += 1; continue
            }
            Shell.bashCurrent.stderr("od: invalid option: \(arg)\n")
            return nil
        }
        return options
    }

    // MARK: - Legacy -b / -x / -c

    enum Mode { case octal, hex, chars }

    private func renderLegacy(bytes: [UInt8], mode: Mode,
                              radix: AddressRadix) throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 16, bytes.count)
            Shell.bashCurrent.stdout(
                format(offset: offset, row: Array(bytes[offset..<end]),
                       mode: mode, radix: radix) + "\n")
            offset = end
        }
        // od traditionally prints the final offset on its own line —
        // suppressed entirely with `-A n`.
        if let tail = radix.address(bytes.count) {
            Shell.bashCurrent.stdout(tail + "\n")
        }
    }

    private func format(offset: Int, row: [UInt8], mode: Mode,
                        radix: AddressRadix) -> String {
        // The legacy address column keeps its historical trailing space.
        let prefix = radix.address(offset).map { $0 + " " } ?? ""
        switch mode {
        case .octal:
            return prefix + row.map { String(format: " %03o", $0) }.joined()
        case .hex:
            // Two-byte words. Pad an odd trailing byte with 0 so the
            // word still renders.
            var words: [String] = []
            var index = 0
            while index < row.count {
                let low = UInt16(row[index])
                let high = index + 1 < row.count ? UInt16(row[index + 1]) : 0
                let word = (high << 8) | low
                words.append(String(format: " %04x", word))
                index += 2
            }
            return prefix + words.joined()
        case .chars:
            return prefix + row.map { Self.escapeChar($0) }.joined()
        }
    }

    // MARK: - -A address radix

    /// `-A` address radix. `.none` (`-A n`) suppresses both the address
    /// column and the trailing offset line.
    enum AddressRadix {
        case octal, decimal, hex, none

        init?(parsing raw: String) {
            switch raw {
            case "o": self = .octal
            case "d": self = .decimal
            case "x": self = .hex
            case "n": self = .none
            default: return nil
            }
        }

        /// The 7-wide address string, or `nil` for `.none`.
        func address(_ offset: Int) -> String? {
            switch self {
            case .octal: return String(format: "%07o", offset)
            case .decimal: return String(format: "%07d", offset)
            case .hex: return String(format: "%07x", offset)
            case .none: return nil
            }
        }
    }

    // MARK: - -t typed output

    private func renderTyped(bytes: [UInt8], type: OdOutputType,
                             radix: AddressRadix) throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 16, bytes.count)
            let row = Array(bytes[offset..<end])
            // GNU style: the address has no trailing space; each unit
            // carries its own leading space instead.
            var line = radix.address(offset) ?? ""
            if type.kind == .char {
                line += row.map { Self.escapeChar($0) }.joined()
            } else {
                line += odNumericUnits(row: row, type: type)
            }
            Shell.bashCurrent.stdout(line + "\n")
            offset = end
        }
        if let tail = radix.address(bytes.count) {
            Shell.bashCurrent.stdout(tail + "\n")
        }
    }

    /// Render one byte the way `od -c` does — single-letter escape
    /// where defined, octal escape otherwise, printable ASCII as-is.
    /// Output is right-aligned in a 3-column slot with one leading
    /// space, matching `od -c`'s row formatting.
    static func escapeChar(_ byte: UInt8) -> String {
        let token: String
        switch byte {
        case 0x00: token = "\\0"
        case 0x07: token = "\\a"
        case 0x08: token = "\\b"
        case 0x09: token = "\\t"
        case 0x0A: token = "\\n"
        case 0x0B: token = "\\v"
        case 0x0C: token = "\\f"
        case 0x0D: token = "\\r"
        default:
            if byte >= 0x20 && byte <= 0x7E {
                token = String(UnicodeScalar(byte))
            } else {
                token = String(format: "\\%03o", byte)
            }
        }
        // Right-align in a 3-char slot, then prefix with a single space.
        // Avoid `String(format: "%s", …)` since that wants a C string;
        // passing an NSString bridge there is undefined behaviour.
        let pad = max(0, 3 - token.count)
        return " " + String(repeating: " ", count: pad) + token
    }
}

// MARK: - Typed-output helpers (file scope to keep the command small)

/// A `-t` output type: a numeric base (`x`/`o`/`d`/`u`) with a byte
/// width, or `c` (named / escaped characters, width 1). Letter sizes
/// (`C`/`S`/`I`/`L`) and the `a` named type are out of scope.
private struct OdOutputType {
    enum Kind { case hex, octal, signedDecimal, unsignedDecimal, char }
    let kind: Kind
    let size: Int   // bytes per unit; 1 for `.char`

    init?(parsing spec: String) {
        guard let first = spec.first else { return nil }
        let rest = spec.dropFirst()
        if first == "c" {
            guard rest.isEmpty else { return nil }
            kind = .char; size = 1; return
        }
        let base: Kind
        switch first {
        case "x": base = .hex
        case "o": base = .octal
        case "d": base = .signedDecimal
        case "u": base = .unsignedDecimal
        default: return nil
        }
        let width: Int
        if rest.isEmpty {
            width = 4                       // GNU default: sizeof(int)
        } else if let parsed = Int(rest), [1, 2, 4, 8].contains(parsed) {
            width = parsed
        } else {
            return nil
        }
        kind = base; size = width
    }
}

/// Assemble `row` into little-endian units of `type.size` bytes
/// (padding a short trailing unit with 0) and format each.
private func odNumericUnits(row: [UInt8], type: OdOutputType) -> String {
    var out = ""
    var index = 0
    while index < row.count {
        var value: UInt64 = 0
        for byteIndex in 0..<type.size where index + byteIndex < row.count {
            value |= UInt64(row[index + byteIndex]) << (8 * byteIndex)
        }
        out += " " + odFormatUnit(value, type: type)
        index += type.size
    }
    return out
}

private func odFormatUnit(_ value: UInt64, type: OdOutputType) -> String {
    let bits = type.size * 8
    switch type.kind {
    case .hex:
        // Zero-padded to the unit width, matching od's hex columns.
        return String(format: "%0\(type.size * 2)llx", value)
    case .octal:
        let width = Int((Double(bits) / 3.0).rounded(.up))
        return String(format: "%0\(width)llo", value)
    case .unsignedDecimal:
        let maxValue = type.size < 8 ? (UInt64(1) << bits) - 1 : UInt64.max
        return String(format: "%\(String(maxValue).count)llu", value)
    case .signedDecimal:
        let minValue: Int64 =
            type.size < 8 ? -(Int64(1) << (bits - 1)) : Int64.min
        return String(format: "%\(String(minValue).count)lld",
                      odSignExtend(value, bits: bits))
    case .char:
        // Unreached — the typed `.char` path uses `escapeChar` directly
        // — but keeps the switch exhaustive.
        return OdCommand.escapeChar(UInt8(truncatingIfNeeded: value))
    }
}

/// Sign-extend the low `bits` of `value` to a signed `Int64`.
private func odSignExtend(_ value: UInt64, bits: Int) -> Int64 {
    if bits >= 64 { return Int64(bitPattern: value) }
    let mask = (UInt64(1) << bits) - 1
    let low = value & mask
    if low & (UInt64(1) << (bits - 1)) != 0 {
        return Int64(bitPattern: low | ~mask)
    }
    return Int64(low)
}
