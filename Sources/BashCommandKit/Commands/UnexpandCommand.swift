import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
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
                    Shell.current.stderr("unexpand: -t requires LIST\n"); return ExitStatus(2)
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
                Shell.current.stderr("unexpand: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let stops = ExpandCommand.parseTabStops(tabSpec)
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            try Task.checkCancellation()
            do {
                let text: String
                if f == "-" { text = await Shell.current.stdin.readAllString() }
                else {
                    let data = try await Shell.current.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                Shell.current.stdout(UnexpandCommand.unexpand(text, stops: stops, allBlanks: allBlanks))
            } catch {
                Shell.current.stderr("unexpand: \(f): \(error)\n")
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
