import ArgumentParser
import BashInterpreter
import Foundation

/// `cut -f LIST [-d DELIM] [FILE...]` — extract delimited fields from
/// each input line.
///
/// ### Field list (`-f`)
/// Comma-separated 1-based field numbers, with optional inclusive
/// ranges:
/// - `1`             → field 1
/// - `1,3`           → fields 1 and 3
/// - `2-4`           → fields 2, 3, 4
/// - `1,3-5,8`       → fields 1, 3, 4, 5, 8
/// - `3-`            → field 3 to the end
/// - `-3`            → fields 1, 2, 3
///
/// ### Delimiter (`-d`)
/// Default is tab. Pass `-d ,` to cut CSV-ish input. Output uses the
/// same delimiter to join surviving fields.
///
/// Lines lacking the delimiter are passed through unchanged (matching
/// BSD `cut`'s default; we don't yet support `-s` to suppress them).
///
/// Out of scope: `-c` (character mode), `-b` (byte mode),
/// `--complement`, `--output-delimiter`, `-s`.
public struct CutCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cut",
        abstract: "Extract delimited fields from each line."
    )

    @Option(name: [.customShort("f"), .customLong("fields")],
            help: "Field list (1-based, comma-separated, ranges allowed).")
    public var fields: String

    @Option(name: [.customShort("d"), .customLong("delimiter")],
            help: "Delimiter character (default: tab).")
    public var delimiter: String = "\t"

    @Argument(help: "Files to read. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard delimiter.count == 1, let delimChar = delimiter.first else {
            shell.stderr("cut: -d requires a single character\n")
            return ExitStatus(2)
        }
        let spec: FieldSpec
        do {
            spec = try FieldSpec.parse(fields)
        } catch let err as FieldSpec.ParseError {
            shell.stderr("cut: -f \(fields): \(err.message)\n")
            return ExitStatus(2)
        }

        if files.isEmpty {
            for await line in shell.stdin.lines {
                shell.stdout(emit(line: line, spec: spec, delim: delimChar)
                    + "\n")
            }
            return .success
        }
        var hadError = false
        for f in files {
            do {
                let data = try await shell.readDataAtPath(f)
                let text = String(decoding: data, as: UTF8.self)
                for line in SortCommand.splitLines(text) {
                    shell.stdout(emit(line: line, spec: spec, delim: delimChar)
                        + "\n")
                }
            } catch {
                shell.stderr("cut: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func emit(line: String, spec: FieldSpec,
                      delim: Character) -> String {
        // No delimiter on the line → pass through verbatim (BSD).
        guard line.contains(delim) else { return line }
        let parts = line.split(separator: delim,
                               omittingEmptySubsequences: false)
                        .map(String.init)
        let picked = spec.picks(from: parts.count)
        return picked.map { parts[$0] }.joined(separator: String(delim))
    }

    // MARK: Field spec

    /// Parsed `-f` argument. Stored as a list of inclusive [lo, hi]
    /// ranges (1-based) with `Int.max` standing in for "to end".
    struct FieldSpec {
        struct ParseError: Error { let message: String }

        var ranges: [(lo: Int, hi: Int)]

        static func parse(_ raw: String) throws -> FieldSpec {
            var out: [(Int, Int)] = []
            for piece in raw.split(separator: ",") {
                let s = String(piece)
                if let dash = s.firstIndex(of: "-") {
                    let loStr = String(s[..<dash])
                    let hiStr = String(s[s.index(after: dash)...])
                    let lo = loStr.isEmpty ? 1 : (Int(loStr) ?? 0)
                    let hi = hiStr.isEmpty ? Int.max : (Int(hiStr) ?? 0)
                    guard lo >= 1, hi >= lo else {
                        throw ParseError(
                            message: "invalid range `\(s)`")
                    }
                    out.append((lo, hi))
                } else {
                    guard let n = Int(s), n >= 1 else {
                        throw ParseError(
                            message: "invalid field `\(s)`")
                    }
                    out.append((n, n))
                }
            }
            guard !out.isEmpty else {
                throw ParseError(message: "empty list")
            }
            return FieldSpec(ranges: out)
        }

        /// Indices into a 0-based fields array, in order, deduped.
        func picks(from count: Int) -> [Int] {
            var seen = Set<Int>()
            var out: [Int] = []
            for r in ranges {
                let lo = r.lo
                let hi = min(r.hi, count)
                guard lo <= hi else { continue }
                for i in lo...hi {
                    let zero = i - 1
                    if seen.insert(zero).inserted {
                        out.append(zero)
                    }
                }
            }
            return out
        }
    }
}
