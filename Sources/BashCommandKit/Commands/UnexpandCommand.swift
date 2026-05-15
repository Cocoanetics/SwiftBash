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

    // The flag-parsing while-loop has high branch density (one branch
    // per supported flag form); splitting it would just add plumbing.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var tabSpec = "8"
        var allBlanks = false
        var files: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-a" || arg == "--all" { allBlanks = true; index += 1; continue }
            if arg == "-t" || arg == "--tabs" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("unexpand: -t requires LIST\n"); return ExitStatus(2)
                }
                tabSpec = rawArgv[index + 1]; allBlanks = true; index += 2; continue
            }
            if arg.hasPrefix("--tabs=") {
                tabSpec = String(arg.dropFirst("--tabs=".count)); allBlanks = true
                index += 1; continue
            }
            if arg.hasPrefix("-t") && arg.count > 2 {
                tabSpec = String(arg.dropFirst(2)); allBlanks = true; index += 1; continue
            }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                Shell.bashCurrent.stderr("unexpand: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); index += 1
        }

        let stops = ExpandCommand.parseTabStops(tabSpec)
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for file in inputs {
            try Task.checkCancellation()
            do {
                let text: String
                if file == "-" {
                    text = await Shell.bashCurrent.stdin.readAllString()
                } else {
                    let data = try await Shell.bashCurrent.readDataAtPath(file)
                    // unexpand operates on arbitrary file bytes; lossy
                    // decoding is the standard behavior for text utils.
                    // swiftlint:disable:next optional_data_string_conversion
                    text = String(decoding: data, as: UTF8.self)
                }
                Shell.bashCurrent.stdout(UnexpandCommand.unexpand(text, stops: stops, allBlanks: allBlanks))
            } catch {
                Shell.bashCurrent.stderr("unexpand: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    // Compression logic for spaces-to-tabs is a fused state machine
    // with both leading/all-blanks modes and a tab-vs-space inner
    // branch; complexity is intrinsic.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
            var cursor = line.startIndex
            while cursor < line.endIndex {
                let char = line[cursor]
                if char == " " {
                    if allBlanks || inLeading {
                        // Try to compress.
                        let nextStop = col + (width - col % width)
                        // Count consecutive spaces from cursor.
                        var runEnd = cursor
                        var spaces = 0
                        while runEnd < line.endIndex && line[runEnd] == " " {
                            spaces += 1
                            runEnd = line.index(after: runEnd)
                        }
                        let needed = nextStop - col
                        if spaces >= needed && needed > 0 {
                            processed.append("\t")
                            col = nextStop
                            cursor = line.index(cursor, offsetBy: needed)
                            spaceRunStart = col
                        } else {
                            processed += String(repeating: " ", count: spaces)
                            col += spaces
                            cursor = runEnd
                        }
                        continue
                    }
                    processed.append(char); col += 1
                } else {
                    inLeading = inLeading && char == "\t"
                    if char == "\t" {
                        // Treat as a real tab.
                        let next = col + (width - col % width)
                        processed.append(char); col = next
                    } else {
                        if char != " " { inLeading = false }
                        processed.append(char); col += 1
                    }
                }
                cursor = line.index(after: cursor)
                _ = spaceRunStart
            }
            out += processed + "\n"
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
