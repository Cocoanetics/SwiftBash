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

    @Option(name: [.customShort("d"), .customLong("delimiters")],
            help: "Delimiter character(s); cycles when more than one.")
    public var delimiters: String = "\t"

    @Flag(name: [.customShort("s"), .customLong("serial")],
          help: "Paste each file's lines serially into a single line.")
    public var serial: Bool = false

    @Argument(help: "Input files. Use `-` for stdin (only once).")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard !files.isEmpty else {
            shell.stderr("paste: missing operand\n")
            return .failure
        }
        guard !delimiters.isEmpty else {
            shell.stderr("paste: -d may not be empty\n")
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
                    shell.stderr("paste: stdin can only be used once\n")
                    return .failure
                }
                stdinUsed = true
                var lines: [String] = []
                for await line in shell.stdin.lines { lines.append(line) }
                inputs.append(lines)
            } else {
                do {
                    let data = try await shell.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    inputs.append(SortCommand.splitLines(text))
                } catch {
                    shell.stderr("paste: \(f): \(error)\n")
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
                shell.stdout(out + "\n")
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
                shell.stdout(out + "\n")
            }
        }
        return .success
    }
}
