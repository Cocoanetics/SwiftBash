import ArgumentParser
import BashInterpreter
import Foundation

/// `tree [DIRECTORY...]` — pretty-print a directory tree.
///
/// - `-L N` / `--level=N` — maximum display depth
/// - `-a` — include hidden entries
/// - `-d` — directories only
/// - `-f` — print full path instead of basename
public struct TreeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "List contents of directories in a tree-like format."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, DIR…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var maxDepth: Int? = nil
        var showHidden = false
        var dirsOnly = false
        var fullPath = false
        var roots: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { roots.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-L" || a == "--level" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("tree: -L requires a positive integer\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 2; continue
            }
            if a.hasPrefix("--level=") {
                guard let n = Int(a.dropFirst("--level=".count)), n > 0 else {
                    Shell.current.stderr("tree: invalid --level\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 1; continue
            }
            if a == "-a" { showHidden = true; i += 1; continue }
            if a == "-d" { dirsOnly = true; i += 1; continue }
            if a == "-f" { fullPath = true; i += 1; continue }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                Shell.current.stderr("tree: unknown option: \(a)\n"); return ExitStatus(2)
            }
            roots.append(a); i += 1
        }
        if roots.isEmpty { roots = ["."] }

        var dirCount = 0
        var fileCount = 0
        for root in roots {
            Shell.current.stdout(root + "\n")
            await walk(root: root, dir: Shell.current.resolvePath(root),
                       prefix: "", depth: 1, maxDepth: maxDepth,
                       showHidden: showHidden, dirsOnly: dirsOnly,
                       fullPath: fullPath, displayPath: root,
                       dirCount: &dirCount, fileCount: &fileCount)
        }
        let summary = dirsOnly
            ? "\n\(dirCount) director\(dirCount == 1 ? "y" : "ies")\n"
            : "\n\(dirCount) director\(dirCount == 1 ? "y" : "ies"), \(fileCount) file\(fileCount == 1 ? "" : "s")\n"
        Shell.current.stdout(summary)
        return .success
    }

    private func walk(root: String, dir: String, prefix: String, depth: Int,
                      maxDepth: Int?, showHidden: Bool, dirsOnly: Bool,
                      fullPath: Bool, displayPath: String,
                      dirCount: inout Int, fileCount: inout Int) async {
        if let m = maxDepth, depth > m { return }
        var entries = (try? await Shell.current.fileSystem.list(dir)) ?? []
        if !showHidden { entries = entries.filter { !$0.hasPrefix(".") } }
        entries.sort()
        var visible: [(name: String, meta: FileMetadata?)] = []
        for n in entries {
            let p = (dir as NSString).appendingPathComponent(n)
            let meta = (try? await Shell.current.fileSystem.metadata(p)) ?? nil
            if dirsOnly && meta?.kind != .directory { continue }
            visible.append((n, meta))
        }
        for (idx, (name, meta)) in visible.enumerated() {
            let isLast = idx == visible.count - 1
            let connector = isLast ? "└── " : "├── "
            let label = fullPath
                ? (displayPath as NSString).appendingPathComponent(name)
                : name
            Shell.current.stdout(prefix + connector + label + "\n")
            if meta?.kind == .directory {
                dirCount += 1
                let childPrefix = prefix + (isLast ? "    " : "│   ")
                let childDir = (dir as NSString).appendingPathComponent(name)
                let childDisplay = (displayPath as NSString).appendingPathComponent(name)
                await walk(root: root, dir: childDir, prefix: childPrefix,
                           depth: depth + 1, maxDepth: maxDepth,
                           showHidden: showHidden, dirsOnly: dirsOnly,
                           fullPath: fullPath, displayPath: childDisplay,
                           dirCount: &dirCount, fileCount: &fileCount)
            } else {
                fileCount += 1
            }
        }
    }
}

/// `strings [-n MIN] [FILE...]` — extract printable runs from binary
/// input. Default minimum length is 4 bytes. ASCII-only.
public struct StringsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "strings",
        abstract: "Extract printable strings from a binary file."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var minLen = 4
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-n" || a == "--bytes" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("strings: -n requires positive N\n"); return ExitStatus(2)
                }
                minLen = n; i += 2; continue
            }
            if a.hasPrefix("--bytes=") {
                guard let n = Int(a.dropFirst("--bytes=".count)), n > 0 else {
                    Shell.current.stderr("strings: invalid --bytes\n"); return ExitStatus(2)
                }
                minLen = n; i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                if let n = Int(a.dropFirst()), n > 0 { minLen = n; i += 1; continue }
                Shell.current.stderr("strings: unknown option: \(a)\n"); return ExitStatus(2)
            }
            files.append(a); i += 1
        }
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            do {
                let data: Data
                if f == "-" { data = await Shell.current.stdin.readAllData() }
                else { data = try await Shell.current.readDataAtPath(f) }
                emit(data, minLen: minLen)
            } catch {
                Shell.current.stderr("strings: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func emit(_ data: Data, minLen: Int) {
        var run = [UInt8]()
        for byte in data {
            // Printable ASCII: space (0x20) through tilde (0x7E), plus
            // tab as a common separator.
            if (byte >= 0x20 && byte <= 0x7E) || byte == 0x09 {
                run.append(byte)
            } else {
                if run.count >= minLen {
                    Shell.current.stdout(String(decoding: run, as: UTF8.self) + "\n")
                }
                run.removeAll(keepingCapacity: true)
            }
        }
        if run.count >= minLen {
            Shell.current.stdout(String(decoding: run, as: UTF8.self) + "\n")
        }
    }
}

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
