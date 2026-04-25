import ArgumentParser
import BashInterpreter
import Foundation

/// `nl [-b TYPE] [-w N] [-s STR] [-v N] [FILE...]` — number lines and
/// write to stdout. By default only non-empty lines are numbered;
/// unnumbered lines pass through unchanged.
///
/// Body styles:
/// - `a` — number every line
/// - `t` — number non-empty lines only (default)
/// - `n` — never number lines
public struct NlCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "nl",
        abstract: "Number lines and write them to stdout."
    )

    @Option(name: .customShort("b"),
            help: ArgumentHelp(
                "Body numbering style: a (all), t (non-empty, default), n (none).",
                valueName: "TYPE"))
    public var body: String = "t"

    @Option(name: .customShort("w"),
            help: ArgumentHelp("Width of the line-number field.",
                               valueName: "N"))
    public var width: Int = 6

    @Option(name: .customShort("s"),
            help: ArgumentHelp("Separator between number and line.",
                               valueName: "STR"))
    public var separator: String = "\t"

    @Option(name: .customShort("v"),
            help: ArgumentHelp("First line number.", valueName: "N"))
    public var start: Int = 1

    @Argument(help: "Files to number. When empty, reads stdin.")
    public var files: [String] = []

    public init() {}

    private enum BodyStyle {
        case all, nonEmpty, none
    }

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let style: BodyStyle
        switch body {
        case "a": style = .all
        case "t": style = .nonEmpty
        case "n": style = .none
        default:
            shell.stderr("nl: invalid body numbering style: '\(body)'\n")
            return .failure
        }

        var counter = start

        func emit(_ line: String) {
            let shouldNumber: Bool = {
                switch style {
                case .all: return true
                case .nonEmpty: return !line.isEmpty
                case .none: return false
                }
            }()
            if shouldNumber {
                let numStr = String(counter)
                let pad = max(0, width - numStr.count)
                shell.stdout(String(repeating: " ", count: pad)
                             + numStr + separator + line + "\n")
                counter += 1
            } else {
                shell.stdout(line + "\n")
            }
        }

        if files.isEmpty {
            for await line in shell.stdin.lines { emit(line) }
            return .success
        }

        var hadError = false
        for path in files {
            if path == "-" {
                for await line in shell.stdin.lines { emit(line) }
                continue
            }
            do {
                let data = try await shell.readDataAtPath(path)
                let text = String(decoding: data, as: UTF8.self)
                let parts = text.split(separator: "\n",
                                       omittingEmptySubsequences: false)
                                .map(String.init)
                // `split` leaves a trailing "" when the input ends in "\n";
                // drop it so we don't number a phantom blank line.
                let lines = (text.hasSuffix("\n") && !parts.isEmpty)
                    ? Array(parts.dropLast())
                    : parts
                for line in lines { emit(line) }
            } catch FileSystemError.notFound {
                shell.stderr("nl: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("nl: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("nl: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
