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
        if let bad = parseArgs(into: &delimiters, serial: &serial, files: &files) { return bad }

        guard !files.isEmpty else {
            Shell.bashCurrent.stderr("paste: missing operand\n")
            return .failure
        }
        guard !delimiters.isEmpty else {
            Shell.bashCurrent.stderr("paste: -d may not be empty\n")
            return ExitStatus(2)
        }
        let delimChars = Array(delimiters)

        // Read every input fully up front. paste needs random access
        // across files for its row-by-row interleaving.
        switch await readInputs(files: files, serial: serial) {
        case .failure(let exit): return exit
        case .success(let inputs):
            emitOutput(inputs: inputs, delimChars: delimChars, serial: serial)
            return .success
        }
    }

    private enum InputResult { case success([[String]]), failure(ExitStatus) }

    private func parseArgs(into delimiters: inout String, serial: inout Bool,
                           files: inout [String]) -> ExitStatus? {
        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { files.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-d" || arg == "--delimiters" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("paste: option requires an argument: \(arg)\n")
                    return ExitStatus(2)
                }
                delimiters = decodePasteDelimiters(rawArgv[idx + 1])
                idx += 2; continue
            }
            // BSD/GNU `-dCHAR(s)` combined form (e.g. `-d,`).
            if arg.hasPrefix("-d"), arg.count > 2 {
                delimiters = decodePasteDelimiters(String(arg.dropFirst(2)))
                idx += 1; continue
            }
            if arg == "-s" || arg == "--serial" {
                serial = true; idx += 1; continue
            }
            if arg == "-" {
                files.append(arg); idx += 1; continue
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                Shell.bashCurrent.stderr("paste: invalid option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); idx += 1
        }
        return nil
    }

    private func readInputs(files: [String], serial: Bool) async -> InputResult {
        // GNU/BSD `paste`:
        // * Default mode with multiple `-` operands reads stdin once
        //   and round-robins its lines across the dash slots — with N
        //   dashes, slot k gets stdin lines k, k+N, k+2N, ...
        // * Serial mode (`-s`) is processed file-by-file in argv
        //   order, so the first `-` drains stdin entirely and any
        //   subsequent `-` sees an empty stream.
        let dashCount = files.filter { $0 == "-" }.count
        var stdinLines: [String] = []
        if dashCount > 0 {
            for await line in Shell.bashCurrent.stdin.lines {
                stdinLines.append(line)
            }
        }
        var dashSeen = 0
        var inputs: [[String]] = []
        for file in files {
            if file == "-" {
                let slot = dashSeen
                dashSeen += 1
                var lines: [String] = []
                if serial {
                    if slot == 0 { lines = stdinLines }
                } else {
                    var idx = slot
                    while idx < stdinLines.count {
                        lines.append(stdinLines[idx])
                        idx += dashCount
                    }
                }
                inputs.append(lines)
            } else {
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(file)
                    // swiftlint:disable:next optional_data_string_conversion - paste input may be partial UTF-8
                    let text = String(decoding: data, as: UTF8.self)
                    inputs.append(SortCommand.splitLines(text))
                } catch {
                    Shell.bashCurrent.stderr("paste: \(file): \(error)\n")
                    return .failure(.failure)
                }
            }
        }
        return .success(inputs)
    }

    private func emitOutput(inputs: [[String]], delimChars: [Character], serial: Bool) {
        if serial {
            // One output line per file, joining all of that file's
            // lines with the cycling delimiter.
            for lines in inputs {
                var out = ""
                for (idx, line) in lines.enumerated() {
                    if idx > 0 {
                        out.append(delimChars[(idx - 1) % delimChars.count])
                    }
                    out += line
                }
                Shell.bashCurrent.stdout(out + "\n")
            }
        } else {
            // One output line per row index, taking the row-th line of
            // each file (or "" if that file is shorter).
            let rows = inputs.map(\.count).max() ?? 0
            for row in 0..<rows {
                var out = ""
                for (col, lines) in inputs.enumerated() {
                    if col > 0 {
                        out.append(delimChars[(col - 1) % delimChars.count])
                    }
                    if row < lines.count { out += lines[row] }
                }
                Shell.bashCurrent.stdout(out + "\n")
            }
        }
    }
}

/// Decode `\t`, `\n`, `\\`, `\0` escapes inside a `-d` value the way
/// BSD/GNU `paste` does — `paste -d $'\t'` and `paste -d \\t` both
/// yield a tab.
private func decodePasteDelimiters(_ raw: String) -> String {
    var out = ""
    var idx = raw.startIndex
    while idx < raw.endIndex {
        let char = raw[idx]
        if char == "\\", raw.index(after: idx) < raw.endIndex {
            let next = raw[raw.index(after: idx)]
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "\\": out.append("\\")
            default: out.append(next)
            }
            idx = raw.index(idx, offsetBy: 2)
        } else {
            out.append(char)
            idx = raw.index(after: idx)
        }
    }
    return out
}
