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
                    Shell.bashCurrent.stderr("expand: -t requires LIST\n"); return ExitStatus(2)
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
                Shell.bashCurrent.stderr("expand: unknown option: \(a)\n"); return ExitStatus(2)
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
                if f == "-" { text = await Shell.bashCurrent.stdin.readAllString() }
                else {
                    let data = try await Shell.bashCurrent.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                Shell.bashCurrent.stdout(ExpandCommand.expand(text, stops: stops, initialOnly: initialOnly))
            } catch {
                Shell.bashCurrent.stderr("expand: \(f): \(error)\n")
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
