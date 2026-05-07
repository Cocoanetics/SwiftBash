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

    public mutating func execute() async throws -> ExitStatus {
        var deleteMode = false
        var squeezeMode = false
        var complementMode = false
        var positional: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { positional.append(rawArgv[i]); i += 1 }
                break
            }
            if a.hasPrefix("-"), a.count > 1, a != "-" {
                for ch in a.dropFirst() {
                    switch ch {
                    case "d": deleteMode = true
                    case "s": squeezeMode = true
                    case "c", "C": complementMode = true
                    default:
                        Shell.bashCurrent.stderr("tr: invalid option -- \(ch)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            positional.append(a); i += 1
        }

        guard let set1Raw = positional.first else {
            Shell.bashCurrent.stderr("tr: missing SET1\n")
            return ExitStatus(2)
        }
        let set1 = Self.expandSet(set1Raw)
        let set2: [Character] = positional.count >= 2
            ? Self.expandSet(positional[1])
            : []

        // Build the membership predicate for SET1 (with optional complement).
        let set1Members = Set(set1)
        let isInSet1 = { (c: Character) -> Bool in
            complementMode ? !set1Members.contains(c) : set1Members.contains(c)
        }

        // Translation map (only meaningful when SET2 is given and not
        // pure delete). Complement of SET1 with translation maps every
        // *other* char to the last char of SET2.
        var map: [Character: Character] = [:]
        if !deleteMode, !set2.isEmpty {
            if complementMode {
                // Bash semantics: every non-SET1 char → last(SET2).
                // Easier to apply per-char in the transform loop.
            } else {
                for (idx, c) in set1.enumerated() {
                    let r = idx < set2.count ? set2[idx] : set2[set2.count - 1]
                    map[c] = r
                }
            }
        }

        // For -s, decide which set determines "runs of repeats". Without
        // translation it's SET1; with translation it's SET2 (POSIX).
        let squeezeSet: Set<Character>
        if squeezeMode {
            if !deleteMode, !set2.isEmpty {
                squeezeSet = Set(set2)
            } else {
                squeezeSet = set1Members
            }
        } else {
            squeezeSet = []
        }

        // Stream-process input. We accumulate "previous emitted char" so
        // squeeze can collapse runs across chunk boundaries.
        var prev: Character? = nil

        for await chunk in Shell.bashCurrent.stdin.bytes {
            let s = String(decoding: chunk, as: UTF8.self)
            var out = ""
            for ch in s {
                if deleteMode {
                    if isInSet1(ch) { continue }
                    if squeezeMode, squeezeSet.contains(ch), prev == ch {
                        continue
                    }
                    out.append(ch); prev = ch
                    continue
                }
                if !set2.isEmpty {
                    let translated: Character
                    if isInSet1(ch) {
                        if complementMode {
                            translated = set2[set2.count - 1]
                        } else {
                            translated = map[ch] ?? ch
                        }
                    } else {
                        translated = ch
                    }
                    if squeezeMode, squeezeSet.contains(translated),
                       prev == translated
                    {
                        continue
                    }
                    out.append(translated); prev = translated
                    continue
                }
                // -s only (no SET2, no -d): squeeze runs in SET1.
                if squeezeMode, squeezeSet.contains(ch), prev == ch {
                    continue
                }
                out.append(ch); prev = ch
            }
            Shell.bashCurrent.stdout(out)
        }
        return .success
    }

    // MARK: SET expansion

    /// Expand a raw SET into a flat `[Character]`. Handles ranges
    /// (`a-z`), backslash escapes, and POSIX character classes.
    static func expandSet(_ raw: String) -> [Character] {
        let chars = Array(raw)
        var i = 0
        var out: [Character] = []

        func appendClass(_ name: String) -> Bool {
            let added: [Character]
            switch name {
            case "alnum": added = _trMakeRange("0", "9") + _trMakeRange("a", "z") + _trMakeRange("A", "Z")
            case "alpha": added = _trMakeRange("a", "z") + _trMakeRange("A", "Z")
            case "digit": added = _trMakeRange("0", "9")
            case "lower": added = _trMakeRange("a", "z")
            case "upper": added = _trMakeRange("A", "Z")
            case "space": added = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
            case "blank": added = [" ", "\t"]
            case "punct": added = Array(Self.punctChars)
            case "xdigit": added = _trMakeRange("0", "9") + _trMakeRange("a", "f") + _trMakeRange("A", "F")
            case "cntrl":
                added = (0...31).map { Character(UnicodeScalar($0)!) } + [Character(UnicodeScalar(127))]
            case "print":
                added = (32...126).map { Character(UnicodeScalar($0)!) }
            case "graph":
                added = (33...126).map { Character(UnicodeScalar($0)!) }
            default: return false
            }
            out.append(contentsOf: added)
            return true
        }

        // Expand `[:class:]` if at the cursor; advances `i` and returns true.
        func tryClass() -> Bool {
            // `[:` ... `:]`
            guard i + 1 < chars.count, chars[i] == "[", chars[i + 1] == ":"
            else { return false }
            var j = i + 2
            var name = ""
            while j < chars.count, chars[j] != ":" {
                name.append(chars[j]); j += 1
            }
            guard j + 1 < chars.count, chars[j] == ":", chars[j + 1] == "]"
            else { return false }
            if appendClass(name) {
                i = j + 2
                return true
            }
            return false
        }

        func decodeEscape() -> Character? {
            guard i + 1 < chars.count else { return nil }
            let n = chars[i + 1]
            i += 2
            switch n {
            case "n":  return "\n"
            case "t":  return "\t"
            case "r":  return "\r"
            case "\\": return "\\"
            case "'":  return "'"
            case "\"": return "\""
            case "0":  return "\0"
            default:   return n
            }
        }

        func nextChar() -> Character? {
            guard i < chars.count else { return nil }
            if chars[i] == "\\" {
                return decodeEscape()
            }
            let c = chars[i]
            i += 1
            return c
        }

        while i < chars.count {
            if tryClass() { continue }
            guard let start = nextChar() else { break }
            // Range form `a-z`: peek for the `-` and a successor.
            if i < chars.count, chars[i] == "-",
               i + 1 < chars.count, chars[i + 1] != "-" {
                i += 1  // eat '-'
                guard let end = nextChar() else {
                    out.append(start)
                    out.append("-")
                    continue
                }
                if let lo = start.asciiValue, let hi = end.asciiValue, lo <= hi {
                    for v in lo...hi {
                        out.append(Character(UnicodeScalar(v)))
                    }
                } else {
                    // Non-ASCII range: just emit endpoints, conservative.
                    out.append(start)
                    out.append("-")
                    out.append(end)
                }
            } else {
                out.append(start)
            }
        }
        return out
    }

    private static let punctChars: [Character] = Array(
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
}

private extension ClosedRange where Bound == Character {
    /// Inclusive range `"a"..."z"` materialised to `[Character]`.
    static func char(_ lo: Character, _ hi: Character) -> [Character] {
        guard let a = lo.asciiValue, let b = hi.asciiValue else { return [] }
        return (a...b).map { Character(UnicodeScalar($0)) }
    }
}

private func _trMakeRange(_ lo: Character, _ hi: Character) -> [Character] {
    guard let a = lo.asciiValue, let b = hi.asciiValue, a <= b else { return [] }
    return (a...b).map { Character(UnicodeScalar($0)) }
}
