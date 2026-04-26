import ArgumentParser
import BashInterpreter
import Foundation

/// `paste [-d DELIM] [-s] FILE...` — merge corresponding lines of
/// each FILE.
///
/// Default: emit one line for every "row" `i`, joining `file1[i]`
/// `file2[i]` … with TAB. With `-s` ("serial"), each FILE's lines are
/// joined into a single output line independent of the others.
///
/// `-d DELIM` overrides the join character. Multi-character DELIM
/// values cycle through, like BSD/GNU paste:
/// `paste -d ',|' a b c` joins as `a,b|c,a,b|c,…`.
public struct PasteCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Merge lines of files."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE arguments.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var delimiters = "\t"
        var serial = false
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-d" || a == "--delimiters" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("paste: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                delimiters = decodePasteDelimiters(rawArgv[i + 1])
                i += 2; continue
            }
            // BSD/GNU `-dCHAR(s)` combined form (e.g. `-d,`).
            if a.hasPrefix("-d"), a.count > 2 {
                delimiters = decodePasteDelimiters(String(a.dropFirst(2)))
                i += 1; continue
            }
            if a == "-s" || a == "--serial" {
                serial = true; i += 1; continue
            }
            if a == "-" {
                files.append(a); i += 1; continue
            }
            if a.hasPrefix("-"), a.count > 1 {
                Shell.current.stderr("paste: invalid option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        guard !files.isEmpty else {
            Shell.current.stderr("paste: missing operand\n")
            return .failure
        }
        guard !delimiters.isEmpty else {
            Shell.current.stderr("paste: -d may not be empty\n")
            return ExitStatus(2)
        }
        let delimChars = Array(delimiters)

        // Read every input fully up front. paste needs random access
        // across files for its row-by-row interleaving.
        var inputs: [[String]] = []
        var stdinUsed = false
        for f in files {
            if f == "-" {
                guard !stdinUsed else {
                    Shell.current.stderr("paste: stdin can only be used once\n")
                    return .failure
                }
                stdinUsed = true
                var lines: [String] = []
                for await line in Shell.current.stdin.lines { lines.append(line) }
                inputs.append(lines)
            } else {
                do {
                    let data = try await Shell.current.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    inputs.append(SortCommand.splitLines(text))
                } catch {
                    Shell.current.stderr("paste: \(f): \(error)\n")
                    return .failure
                }
            }
        }

        if serial {
            // One output line per file, joining all of that file's
            // lines with the cycling delimiter.
            for lines in inputs {
                var out = ""
                for (i, line) in lines.enumerated() {
                    if i > 0 {
                        out.append(delimChars[(i - 1) % delimChars.count])
                    }
                    out += line
                }
                Shell.current.stdout(out + "\n")
            }
        } else {
            // One output line per row index, taking the i-th line of
            // each file (or "" if that file is shorter).
            let rows = inputs.map(\.count).max() ?? 0
            for i in 0..<rows {
                var out = ""
                for (j, lines) in inputs.enumerated() {
                    if j > 0 {
                        out.append(delimChars[(j - 1) % delimChars.count])
                    }
                    if i < lines.count { out += lines[i] }
                }
                Shell.current.stdout(out + "\n")
            }
        }
        return .success
    }
}

/// Decode `\t`, `\n`, `\\`, `\0` escapes inside a `-d` value the way
/// BSD/GNU `paste` does — `paste -d $'\t'` and `paste -d \\t` both
/// yield a tab.
private func decodePasteDelimiters(_ raw: String) -> String {
    var out = ""
    var i = raw.startIndex
    while i < raw.endIndex {
        let c = raw[i]
        if c == "\\", raw.index(after: i) < raw.endIndex {
            let n = raw[raw.index(after: i)]
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "\\": out.append("\\")
            default: out.append(n)
            }
            i = raw.index(i, offsetBy: 2)
        } else {
            out.append(c)
            i = raw.index(after: i)
        }
    }
    return out
}
