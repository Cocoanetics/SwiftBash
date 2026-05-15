import ArgumentParser
import BashInterpreter
import Foundation

/// `tr [-cds] SET1 [SET2]` — translate, delete, or squeeze characters
/// from stdin to stdout.
///
/// ### Modes (combinable)
/// - `tr SET1 SET2` — replace each char in SET1 with the corresponding
///   char in SET2.
/// - `tr -d SET1` — drop every char in SET1.
/// - `tr -s SET1` — squeeze runs of chars in SET1 to a single instance.
///   Combined with translation: squeeze runs in SET2 instead.
/// - `tr -c SET1 [SET2]` — complement SET1 (operate on chars NOT in
///   SET1).  Pairs with `-d` and `-s`.
///
/// ### SET syntax
/// - Plain literals, ranges (`a-z`), backslash escapes (`\\`, `\n`,
///   `\t`, `\r`, `\'`, `\"`), and POSIX character classes
///   (`[:digit:]`, `[:alpha:]`, `[:upper:]`, `[:lower:]`, `[:space:]`,
///   `[:alnum:]`, `[:punct:]`).
///
/// When SET2 is shorter than SET1, the final character of SET2 is
/// repeated to fill — matches BSD `tr`.
public struct TrCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tr",
        abstract: "Translate, delete, or squeeze characters."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then SET1 and (optionally) SET2.")
    public var rawArgv: [String] = []

    public init() {}

    /// Decoded option flags + positional SET arguments.
    private struct Options {
        var deleteMode = false
        var squeezeMode = false
        var complementMode = false
        var positional: [String] = []
    }

    /// Pre-computed per-character behaviour used by ``transform``.
    fileprivate struct Transform {
        let set1Members: Set<Character>
        let set2: [Character]
        let map: [Character: Character]
        let squeezeSet: Set<Character>
        let deleteMode: Bool
        let squeezeMode: Bool
        let complementMode: Bool

        func isInSet1(_ char: Character) -> Bool {
            complementMode ? !set1Members.contains(char) : set1Members.contains(char)
        }
    }

    public mutating func execute() async throws -> ExitStatus {
        var options = Options()
        if let earlyStatus = parseFlags(into: &options) { return earlyStatus }

        guard let set1Raw = options.positional.first else {
            Shell.bashCurrent.stderr("tr: missing SET1\n")
            return ExitStatus(2)
        }
        let set1 = Self.expandSet(set1Raw)
        let set2: [Character] = options.positional.count >= 2
            ? Self.expandSet(options.positional[1])
            : []
        let transform = makeTransform(options: options, set1: set1, set2: set2)
        await runStream(transform: transform)
        return .success
    }

    private mutating func parseFlags(into options: inout Options) -> ExitStatus? {
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count {
                    options.positional.append(rawArgv[index])
                    index += 1
                }
                break
            }
            if arg.hasPrefix("-"), arg.count > 1, arg != "-" {
                for char in arg.dropFirst() {
                    switch char {
                    case "d": options.deleteMode = true
                    case "s": options.squeezeMode = true
                    case "c", "C": options.complementMode = true
                    default:
                        Shell.bashCurrent.stderr("tr: invalid option -- \(char)\n")
                        return ExitStatus(2)
                    }
                }
                index += 1
                continue
            }
            options.positional.append(arg)
            index += 1
        }
        return nil
    }

    private func makeTransform(options: Options,
                               set1: [Character],
                               set2: [Character]) -> Transform {
        let set1Members = Set(set1)
        var map: [Character: Character] = [:]
        if !options.deleteMode, !set2.isEmpty, !options.complementMode {
            // Bash semantics: every non-SET1 char → last(SET2). We handle
            // the complement case in the transform loop instead of
            // pre-computing a map.
            for (idx, char) in set1.enumerated() {
                let replacement = idx < set2.count
                    ? set2[idx]
                    : set2[set2.count - 1]
                map[char] = replacement
            }
        }
        let squeezeSet: Set<Character>
        if options.squeezeMode {
            if !options.deleteMode, !set2.isEmpty {
                squeezeSet = Set(set2)
            } else {
                squeezeSet = set1Members
            }
        } else {
            squeezeSet = []
        }
        return Transform(set1Members: set1Members, set2: set2, map: map,
                         squeezeSet: squeezeSet,
                         deleteMode: options.deleteMode,
                         squeezeMode: options.squeezeMode,
                         complementMode: options.complementMode)
    }

    private func runStream(transform: Transform) async {
        var prev: Character?
        for await chunk in Shell.bashCurrent.stdin.bytes {
            // tr is byte-stream oriented; binary input is legitimate
            // (e.g. `tr -d '\0'`), so a lossy decode is appropriate.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: chunk, as: UTF8.self)
            var out = ""
            for char in text {
                if let emitted = transform.process(char, previous: prev) {
                    out.append(emitted)
                    prev = emitted
                }
            }
            Shell.bashCurrent.stdout(out)
        }
    }

    // MARK: SET expansion

    /// Expand a raw SET into a flat `[Character]`. Handles ranges
    /// (`a-z`), backslash escapes, and POSIX character classes.
    static func expandSet(_ raw: String) -> [Character] {
        var cursor = SetCursor(chars: Array(raw))
        var out: [Character] = []
        while !cursor.isAtEnd {
            if cursor.consumePosixClass(into: &out) { continue }
            guard let start = cursor.nextChar() else { break }
            // Range form `a-z`: peek for the `-` and a successor.
            if cursor.isRangeFollowing {
                cursor.advance()
                guard let end = cursor.nextChar() else {
                    out.append(start)
                    out.append("-")
                    continue
                }
                appendRange(start: start, end: end, into: &out)
            } else {
                out.append(start)
            }
        }
        return out
    }

    private static func appendRange(start: Character,
                                    end: Character,
                                    into out: inout [Character]) {
        if let low = start.asciiValue, let high = end.asciiValue, low <= high {
            for value in low...high {
                out.append(Character(UnicodeScalar(value)))
            }
        } else {
            // Non-ASCII range: just emit endpoints, conservative.
            out.append(start)
            out.append("-")
            out.append(end)
        }
    }

    static let punctChars: [Character] = Array(
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
}

// MARK: - Transform application

extension TrCommand.Transform {
    /// Apply this transform to one character. Returns the character to
    /// emit (after translation), or `nil` if the character should be
    /// dropped (delete mode or squeezed run).
    fileprivate func process(_ char: Character,
                             previous: Character?) -> Character? {
        if deleteMode {
            if isInSet1(char) { return nil }
            if squeezeMode, squeezeSet.contains(char), previous == char {
                return nil
            }
            return char
        }
        if !set2.isEmpty {
            let translated: Character
            if isInSet1(char) {
                if complementMode {
                    translated = set2[set2.count - 1]
                } else {
                    translated = map[char] ?? char
                }
            } else {
                translated = char
            }
            if squeezeMode, squeezeSet.contains(translated),
               previous == translated {
                return nil
            }
            return translated
        }
        // -s only (no SET2, no -d): squeeze runs in SET1.
        if squeezeMode, squeezeSet.contains(char), previous == char {
            return nil
        }
        return char
    }
}

// MARK: - SET cursor

/// Walks the raw bytes of a `tr` SET expression. Encapsulates the
/// `\<esc>`, `[:class:]`, and range-peek logic so the main expansion
/// loop reads as a state machine.
private struct SetCursor {
    let chars: [Character]
    var index: Int = 0

    var isAtEnd: Bool { index >= chars.count }

    var isRangeFollowing: Bool {
        index < chars.count
            && chars[index] == "-"
            && index + 1 < chars.count
            && chars[index + 1] != "-"
    }

    mutating func advance() { index += 1 }

    mutating func nextChar() -> Character? {
        guard index < chars.count else { return nil }
        if chars[index] == "\\" {
            return decodeEscape()
        }
        let char = chars[index]
        index += 1
        return char
    }

    mutating func decodeEscape() -> Character? {
        guard index + 1 < chars.count else { return nil }
        let next = chars[index + 1]
        index += 2
        switch next {
        case "n":  return "\n"
        case "t":  return "\t"
        case "r":  return "\r"
        case "\\": return "\\"
        case "'":  return "'"
        case "\"": return "\""
        case "0":  return "\0"
        default:   return next
        }
    }

    /// If the cursor is at `[:class:]`, consume it and append the
    /// matching characters; otherwise leave the cursor untouched.
    mutating func consumePosixClass(into out: inout [Character]) -> Bool {
        guard index + 1 < chars.count,
              chars[index] == "[", chars[index + 1] == ":"
        else { return false }
        var probe = index + 2
        var name = ""
        while probe < chars.count, chars[probe] != ":" {
            name.append(chars[probe])
            probe += 1
        }
        guard probe + 1 < chars.count,
              chars[probe] == ":", chars[probe + 1] == "]"
        else { return false }
        guard let chars = SetCursor.classCharacters(name) else { return false }
        out.append(contentsOf: chars)
        index = probe + 2
        return true
    }

    // The switch tabulates 11 POSIX character classes; each case is
    // a one-liner, so splitting into helpers would obscure the table.
    // swiftlint:disable:next cyclomatic_complexity
    static func classCharacters(_ name: String) -> [Character]? {
        switch name {
        case "alnum":
            return makeRange("0", "9")
                + makeRange("a", "z")
                + makeRange("A", "Z")
        case "alpha":
            return makeRange("a", "z") + makeRange("A", "Z")
        case "digit": return makeRange("0", "9")
        case "lower": return makeRange("a", "z")
        case "upper": return makeRange("A", "Z")
        case "space":
            return [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
        case "blank": return [" ", "\t"]
        case "punct": return TrCommand.punctChars
        case "xdigit":
            return makeRange("0", "9")
                + makeRange("a", "f")
                + makeRange("A", "F")
        case "cntrl":
            // swiftlint:disable:next force_unwrapping
            return (0...31).map { Character(UnicodeScalar($0)!) }
                + [Character(UnicodeScalar(127))]
        case "print":
            // swiftlint:disable:next force_unwrapping
            return (32...126).map { Character(UnicodeScalar($0)!) }
        case "graph":
            // swiftlint:disable:next force_unwrapping
            return (33...126).map { Character(UnicodeScalar($0)!) }
        default: return nil
        }
    }

    static func makeRange(_ low: Character, _ high: Character) -> [Character] {
        guard let lowByte = low.asciiValue,
              let highByte = high.asciiValue,
              lowByte <= highByte
        else { return [] }
        return (lowByte...highByte).map { Character(UnicodeScalar($0)) }
    }
}
