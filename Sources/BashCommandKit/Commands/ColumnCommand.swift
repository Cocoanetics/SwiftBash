import ArgumentParser
import BashInterpreter
import Foundation

/// `column [-t] [-s SEP] [-c WIDTH] [FILE...]` — format input as a
/// table.
///
/// - `-t` — tabulate by columns (auto-detect or use `-s`)
/// - `-s SEP` — input field separator (default whitespace)
/// - `-c WIDTH` — output width for non-tabular column layout (default 80)
/// - `-x` — fill rows before columns in column layout
public struct ColumnCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "column",
        abstract: "Columnate lists."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var table = false
        var fillRows = false
        var sep: String? = nil
        var width = 80
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-t" { table = true; i += 1; continue }
            if a == "-x" { fillRows = true; i += 1; continue }
            if a == "-s" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("column: -s requires SEP\n"); return ExitStatus(2)
                }
                sep = rawArgv[i + 1]; i += 2; continue
            }
            if a == "-c" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("column: -c requires WIDTH\n"); return ExitStatus(2)
                }
                width = n; i += 2; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                Shell.current.stderr("column: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        // Read input.
        var lines: [String] = []
        if files.isEmpty {
            for await line in Shell.current.stdin.lines { lines.append(line) }
        } else {
            for f in files {
                do {
                    let data = try await Shell.current.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    lines.append(contentsOf: SortCommand.splitLines(text))
                } catch {
                    Shell.current.stderr("column: \(f): \(error)\n")
                    return .failure
                }
            }
        }

        if table {
            // Compute per-column widths, then emit aligned rows.
            var rows: [[String]] = lines.map { line in
                if let s = sep {
                    return line.components(separatedBy: s)
                }
                return line.split(omittingEmptySubsequences: true,
                                  whereSeparator: { $0.isWhitespace }).map(String.init)
            }
            let cols = rows.map { $0.count }.max() ?? 0
            var widths = [Int](repeating: 0, count: cols)
            for r in rows {
                for (i, v) in r.enumerated() {
                    widths[i] = max(widths[i], v.count)
                }
            }
            for r in 0..<rows.count {
                while rows[r].count < cols { rows[r].append("") }
            }
            for r in rows {
                let parts = r.enumerated().map { (i, v) -> String in
                    if i == cols - 1 { return v }
                    return v.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
                }
                Shell.current.stdout(parts.joined() + "\n")
            }
            return .success
        }

        // Non-table: pack values into columns up to `width`.
        let maxLen = (lines.map { $0.count }.max() ?? 0) + 2
        let perRow = max(1, width / max(1, maxLen))
        let rowCount = (lines.count + perRow - 1) / perRow
        for r in 0..<rowCount {
            var pieces: [String] = []
            for c in 0..<perRow {
                let idx = fillRows ? (r * perRow + c) : (c * rowCount + r)
                if idx < lines.count {
                    pieces.append(lines[idx].padding(toLength: maxLen, withPad: " ", startingAt: 0))
                }
            }
            Shell.current.stdout(pieces.joined().trimmingCharacters(in: .whitespaces) + "\n")
        }
        return .success
    }
}
