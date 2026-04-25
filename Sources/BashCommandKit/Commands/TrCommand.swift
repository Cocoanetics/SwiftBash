import ArgumentParser
import BashInterpreter
import Foundation

/// `tr [-d] SET1 [SET2]` — translate or delete characters from stdin
/// to stdout.
///
/// ### Behaviour
/// - `tr SET1 SET2` — replace each character in SET1 with the
///   corresponding character in SET2 (positionally).
/// - `tr -d SET1` — drop every character in SET1.
///
/// ### SET syntax
/// - Plain literals: `tr abc xyz`
/// - Inclusive ranges: `tr a-z A-Z`
/// - Backslash escapes: `\\`, `\n`, `\t`, `\r`, `\\`, `\'`, `\"`
///
/// When SET2 is shorter than SET1, the final character of SET2 is
/// repeated to fill — matches BSD `tr`. Extra trailing characters of
/// SET2 (when it's longer) are ignored.
///
/// Out of scope: `-c` complement, `-s` squeeze, `-C`, `[:class:]`
/// POSIX classes, octal escapes (`\NNN`).
public struct TrCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tr",
        abstract: "Translate or delete characters."
    )

    @Flag(name: [.customShort("d"), .customLong("delete")],
          help: "Delete characters in SET1 instead of translating.")
    public var delete: Bool = false

    @Argument(help: "Source set (and target set when not deleting).")
    public var sets: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard let set1Raw = sets.first else {
            shell.stderr("tr: missing SET1\n")
            return ExitStatus(2)
        }
        let set1 = Self.expandSet(set1Raw)
        if delete {
            let drop = Set(set1)
            for await chunk in shell.stdin.bytes {
                let s = String(decoding: chunk, as: UTF8.self)
                let kept = String(s.unicodeScalars.compactMap { sc -> Character? in
                    let c = Character(sc)
                    return drop.contains(c) ? nil : c
                })
                shell.stdout(kept)
            }
            return .success
        }

        guard sets.count >= 2 else {
            shell.stderr("tr: SET2 required when not in -d mode\n")
            return ExitStatus(2)
        }
        let set2 = Self.expandSet(sets[1])
        guard !set2.isEmpty else {
            shell.stderr("tr: SET2 must not be empty\n")
            return ExitStatus(2)
        }

        // Build the translation map. When SET2 is shorter, the final
        // character is repeated to cover the rest of SET1 (BSD `tr`).
        var map: [Character: Character] = [:]
        for (i, c) in set1.enumerated() {
            let r = i < set2.count ? set2[i] : set2[set2.count - 1]
            map[c] = r
        }

        for await chunk in shell.stdin.bytes {
            let s = String(decoding: chunk, as: UTF8.self)
            let translated = String(s.map { map[$0] ?? $0 })
            shell.stdout(translated)
        }
        return .success
    }

    // MARK: SET expansion

    /// Expand a raw SET into a flat `[Character]`. Handles `a-z`
    /// ranges and backslash escapes (`\\`, `\n`, `\t`, `\r`, `\'`, `\"`).
    static func expandSet(_ raw: String) -> [Character] {
        let chars = Array(raw)
        var i = 0
        var out: [Character] = []

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
}
