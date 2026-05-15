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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var table = false
        var fillRows = false
        var sep: String?
        var width = 80
        var files: [String] = []
        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { files.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-t" { table = true; idx += 1; continue }
            if arg == "-x" { fillRows = true; idx += 1; continue }
            if arg == "-s" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("column: -s requires SEP\n"); return ExitStatus(2)
                }
                sep = rawArgv[idx + 1]; idx += 2; continue
            }
            if arg == "-c" {
                guard idx + 1 < rawArgv.count, let num = Int(rawArgv[idx + 1]), num > 0 else {
                    Shell.bashCurrent.stderr("column: -c requires WIDTH\n"); return ExitStatus(2)
                }
                width = num; idx += 2; continue
            }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                Shell.bashCurrent.stderr("column: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); idx += 1
        }

        // Read input.
        var lines: [String] = []
        if files.isEmpty {
            for await line in Shell.bashCurrent.stdin.lines { lines.append(line) }
        } else {
            for file in files {
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(file)
                    // column input may legitimately contain non-UTF-8 bytes
                    // swiftlint:disable:next optional_data_string_conversion
                    let text = String(decoding: data, as: UTF8.self)
                    lines.append(contentsOf: SortCommand.splitLines(text))
                } catch {
                    Shell.bashCurrent.stderr("column: \(file): \(error)\n")
                    return .failure
                }
            }
        }

        if table {
            // Compute per-column widths, then emit aligned rows.
            var rows: [[String]] = lines.map { line in
                if let sep {
                    return line.components(separatedBy: sep)
                }
                return line.split(omittingEmptySubsequences: true,
                                  whereSeparator: { $0.isWhitespace }).map(String.init)
            }
            let cols = rows.map { $0.count }.max() ?? 0
            var widths = [Int](repeating: 0, count: cols)
            for row in rows {
                for (colIdx, value) in row.enumerated() {
                    widths[colIdx] = max(widths[colIdx], value.count)
                }
            }
            for rowIdx in 0..<rows.count {
                while rows[rowIdx].count < cols { rows[rowIdx].append("") }
            }
            for row in rows {
                let parts = row.enumerated().map { (colIdx, value) -> String in
                    if colIdx == cols - 1 { return value }
                    return value.padding(toLength: widths[colIdx] + 2, withPad: " ", startingAt: 0)
                }
                Shell.bashCurrent.stdout(parts.joined() + "\n")
            }
            return .success
        }

        // Non-table: pack values into columns up to `width`.
        let maxLen = (lines.map { $0.count }.max() ?? 0) + 2
        let perRow = max(1, width / max(1, maxLen))
        let rowCount = (lines.count + perRow - 1) / perRow
        for rowIdx in 0..<rowCount {
            var pieces: [String] = []
            for colIdx in 0..<perRow {
                let lineIdx = fillRows ? (rowIdx * perRow + colIdx) : (colIdx * rowCount + rowIdx)
                if lineIdx < lines.count {
                    pieces.append(lines[lineIdx].padding(toLength: maxLen, withPad: " ", startingAt: 0))
                }
            }
            Shell.bashCurrent.stdout(pieces.joined().trimmingCharacters(in: .whitespaces) + "\n")
        }
        return .success
    }
}
