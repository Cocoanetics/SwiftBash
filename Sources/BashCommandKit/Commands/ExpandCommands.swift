import ArgumentParser
import BashInterpreter
import Foundation

/// `expand [-t TABLIST] [FILE...]` — convert tabs to spaces.
///
/// Default tab stops are every 8 columns. `-t N` sets a uniform tab
/// width of N. `-t LIST` (comma- or whitespace-separated) sets explicit
/// stop columns; positions past the last listed stop align to single
/// spaces (POSIX-compatible).
public struct ExpandCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "expand",
        abstract: "Convert tabs to spaces."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var tabSpec = "8"
        var initialOnly = false
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-i" || a == "--initial" { initialOnly = true; i += 1; continue }
            if a == "-t" || a == "--tabs" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("expand: -t requires LIST\n"); return ExitStatus(2)
                }
                tabSpec = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--tabs=") {
                tabSpec = String(a.dropFirst("--tabs=".count)); i += 1; continue
            }
            if a.hasPrefix("-t") && a.count > 2 {
                tabSpec = String(a.dropFirst(2)); i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                // Allow -N as shorthand for -t N (GNU).
                if let _ = Int(a.dropFirst()) {
                    tabSpec = String(a.dropFirst()); i += 1; continue
                }
                shell.stderr("expand: unknown option: \(a)\n"); return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let stops = ExpandCommand.parseTabStops(tabSpec)
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            do {
                let text: String
                if f == "-" { text = await shell.stdin.readAllString() }
                else {
                    let data = try await shell.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                shell.stdout(ExpandCommand.expand(text, stops: stops, initialOnly: initialOnly))
            } catch {
                shell.stderr("expand: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Parse `8`, `4`, `1,5,9`, `4 8 12`. Uniform-width returns a
    /// single-element list whose entry is interpreted as a width.
    static func parseTabStops(_ s: String) -> [Int] {
        let parts = s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
        return parts.compactMap { Int($0) }
    }

    /// Expand tabs in `text`. With one stop, treat as a uniform width;
    /// otherwise the stops are explicit columns.
    static func expand(_ text: String, stops: [Int],
                       initialOnly: Bool) -> String {
        guard !stops.isEmpty else { return text }
        let uniformWidth: Int? = stops.count == 1 ? stops[0] : nil
        let explicit: [Int] = stops.count > 1 ? stops : []

        // Split on \n keeping all lines, including a trailing empty
        // one if the input ends with \n.
        var lines = text.components(separatedBy: "\n")
        let inputEndsNL = !lines.isEmpty && lines.last == ""
        if inputEndsNL { lines.removeLast() }

        var out = ""
        for line in lines {
            var col = 0
            var seenNonBlank = false
            for c in line {
                if c == "\t", !initialOnly || !seenNonBlank {
                    let next: Int
                    if let w = uniformWidth, w > 0 {
                        next = col + (w - col % w)
                    } else if let target = explicit.first(where: { $0 > col }) {
                        next = target
                    } else {
                        next = col + 1
                    }
                    out += String(repeating: " ", count: next - col)
                    col = next
                } else {
                    if c != " " && c != "\t" { seenNonBlank = true }
                    out.append(c); col += 1
                }
            }
            out.append("\n")
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}

/// `unexpand [-a] [-t TABLIST] [FILE...]` — convert sequences of
/// spaces to tabs. Without `-a`, only leading whitespace is converted
/// (POSIX default); `-a` converts spaces anywhere on the line.
public struct UnexpandCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unexpand",
        abstract: "Convert spaces to tabs."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var tabSpec = "8"
        var allBlanks = false
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-a" || a == "--all" { allBlanks = true; i += 1; continue }
            if a == "-t" || a == "--tabs" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("unexpand: -t requires LIST\n"); return ExitStatus(2)
                }
                tabSpec = rawArgv[i + 1]; allBlanks = true; i += 2; continue
            }
            if a.hasPrefix("--tabs=") {
                tabSpec = String(a.dropFirst("--tabs=".count)); allBlanks = true
                i += 1; continue
            }
            if a.hasPrefix("-t") && a.count > 2 {
                tabSpec = String(a.dropFirst(2)); allBlanks = true; i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                shell.stderr("unexpand: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let stops = ExpandCommand.parseTabStops(tabSpec)
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            do {
                let text: String
                if f == "-" { text = await shell.stdin.readAllString() }
                else {
                    let data = try await shell.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                shell.stdout(UnexpandCommand.unexpand(text, stops: stops, allBlanks: allBlanks))
            } catch {
                shell.stderr("unexpand: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    static func unexpand(_ text: String, stops: [Int], allBlanks: Bool) -> String {
        guard !stops.isEmpty else { return text }
        let width = stops[0]
        var lines = text.components(separatedBy: "\n")
        let inputEndsNL = !lines.isEmpty && lines.last == ""
        if inputEndsNL { lines.removeLast() }
        var out = ""
        for line in lines {
            var col = 0
            var processed = ""
            var spaceRunStart = 0
            var inLeading = true
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                if c == " " {
                    if (allBlanks || inLeading) {
                        // Try to compress.
                        let nextStop = col + (width - col % width)
                        // Count consecutive spaces from i.
                        var runEnd = i
                        var spaces = 0
                        while runEnd < line.endIndex && line[runEnd] == " " {
                            spaces += 1
                            runEnd = line.index(after: runEnd)
                        }
                        let needed = nextStop - col
                        if spaces >= needed && needed > 0 {
                            processed.append("\t")
                            col = nextStop
                            i = line.index(i, offsetBy: needed)
                            spaceRunStart = col
                        } else {
                            processed += String(repeating: " ", count: spaces)
                            col += spaces
                            i = runEnd
                        }
                        continue
                    }
                    processed.append(c); col += 1
                } else {
                    inLeading = inLeading && c == "\t"
                    if c == "\t" {
                        // Treat as a real tab.
                        let next = col + (width - col % width)
                        processed.append(c); col = next
                    } else {
                        if c != " " { inLeading = false }
                        processed.append(c); col += 1
                    }
                }
                i = line.index(after: i)
                _ = spaceRunStart
            }
            out += processed + "\n"
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}

/// `fold [-w WIDTH] [-s] [-b] [FILE...]` — wrap lines.
///
/// - `-w N` / `--width=N` — wrap at N columns (default 80)
/// - `-s` / `--spaces` — break at spaces only
/// - `-b` / `--bytes` — count bytes instead of columns
public struct FoldCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fold",
        abstract: "Wrap lines."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var width = 80
        var atSpaces = false
        var byBytes = false
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-s" || a == "--spaces" { atSpaces = true; i += 1; continue }
            if a == "-b" || a == "--bytes" { byBytes = true; i += 1; continue }
            if a == "-w" || a == "--width" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    shell.stderr("fold: -w requires WIDTH\n"); return ExitStatus(2)
                }
                width = n; i += 2; continue
            }
            if a.hasPrefix("--width=") {
                guard let n = Int(a.dropFirst("--width=".count)), n > 0 else {
                    shell.stderr("fold: invalid --width\n"); return ExitStatus(2)
                }
                width = n; i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                if let n = Int(a.dropFirst()) { width = n; i += 1; continue }
                shell.stderr("fold: unknown option: \(a)\n"); return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            do {
                let text: String
                if f == "-" { text = await shell.stdin.readAllString() }
                else {
                    let data = try await shell.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                shell.stdout(FoldCommand.fold(text, width: width, atSpaces: atSpaces, byBytes: byBytes))
            } catch {
                shell.stderr("fold: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    static func fold(_ text: String, width: Int, atSpaces: Bool, byBytes: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        let inputEndsNL = !lines.isEmpty && lines.last == ""
        if inputEndsNL { lines.removeLast() }
        var out = ""
        for line in lines {
            var s = line
            while !s.isEmpty {
                let units = byBytes ? s.utf8.count : s.count
                if units <= width {
                    out += s + "\n"; break
                }
                var splitAt = width
                if atSpaces {
                    // Find last space at or before `width`.
                    let chars = Array(s)
                    var found: Int? = nil
                    for j in (0..<min(width, chars.count)).reversed() {
                        if chars[j] == " " { found = j + 1; break }
                    }
                    if let f = found, f > 0 { splitAt = f }
                }
                let chars = Array(s)
                let head = String(chars[..<splitAt])
                let tail = String(chars[splitAt...])
                out += head + "\n"
                s = tail
            }
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
