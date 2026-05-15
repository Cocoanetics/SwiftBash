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

    public mutating func execute() async throws -> ExitStatus {
        var tabSpec = "8"
        var initialOnly = false
        var files: [String] = []

        if let earlyStatus = parseArgs(
            tabSpec: &tabSpec, initialOnly: &initialOnly, files: &files) {
            return earlyStatus
        }

        let stops = ExpandCommand.parseTabStops(tabSpec)
        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for file in inputs {
            try Task.checkCancellation()
            do {
                let text = try await readText(file: file)
                Shell.bashCurrent.stdout(ExpandCommand.expand(
                    text, stops: stops, initialOnly: initialOnly))
            } catch {
                Shell.bashCurrent.stderr("expand: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private mutating func parseArgs(tabSpec: inout String,
                                    initialOnly: inout Bool,
                                    files: inout [String]) -> ExitStatus? {
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count {
                    files.append(rawArgv[index])
                    index += 1
                }
                break
            }
            if arg == "-i" || arg == "--initial" {
                initialOnly = true
                index += 1
                continue
            }
            if arg == "-t" || arg == "--tabs" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("expand: -t requires LIST\n")
                    return ExitStatus(2)
                }
                tabSpec = rawArgv[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--tabs=") {
                tabSpec = String(arg.dropFirst("--tabs=".count))
                index += 1
                continue
            }
            if arg.hasPrefix("-t") && arg.count > 2 {
                tabSpec = String(arg.dropFirst(2))
                index += 1
                continue
            }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                // Allow -N as shorthand for -t N (GNU).
                if Int(arg.dropFirst()) != nil {
                    tabSpec = String(arg.dropFirst())
                    index += 1
                    continue
                }
                Shell.bashCurrent.stderr("expand: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg)
            index += 1
        }
        return nil
    }

    private func readText(file: String) async throws -> String {
        if file == "-" {
            return await Shell.bashCurrent.stdin.readAllString()
        }
        let data = try await Shell.bashCurrent.readDataAtPath(file)
        // Files may contain non-UTF-8 bytes; lossy decode keeps text
        // flowing through the pipeline rather than crashing.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse `8`, `4`, `1,5,9`, `4 8 12`. Uniform-width returns a
    /// single-element list whose entry is interpreted as a width.
    static func parseTabStops(_ spec: String) -> [Int] {
        let parts = spec.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
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
            for char in line {
                if char == "\t", !initialOnly || !seenNonBlank {
                    let next: Int
                    if let width = uniformWidth, width > 0 {
                        next = col + (width - col % width)
                    } else if let target = explicit.first(where: { $0 > col }) {
                        next = target
                    } else {
                        next = col + 1
                    }
                    out += String(repeating: " ", count: next - col)
                    col = next
                } else {
                    if char != " " && char != "\t" { seenNonBlank = true }
                    out.append(char); col += 1
                }
            }
            out.append("\n")
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
