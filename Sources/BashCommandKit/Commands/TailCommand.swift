import ArgumentParser
import BashInterpreter
import Foundation

/// `tail [-n N] [FILE...]` — print the last N lines of each file (or
/// stdin when no files are given). Default N is 10. With multiple
/// files, prints a `==> name <==` header before each, matching
/// `/bin/tail`.
///
/// Unlike `head`, `tail` has to see the whole input before it can
/// know what to emit, so this version buffers — there's no
/// streaming variant to back-pressure an upstream producer. Pair
/// `tail` with bounded inputs.
public struct TailCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Print the last N lines of input."
    )

    @Option(name: [.short, .long],
            help: ArgumentHelp("Number of trailing lines to print.",
                               valueName: "N"))
    public var n: Int = 10

    @Argument(help: "Files to tail. When empty, reads stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if n <= 0 { return .success }

        if files.isEmpty {
            let lines = await collectStdinLines(shell: shell)
            emit(lines: lastN(lines), shell: shell)
            return .success
        }

        var hadError = false
        for (i, path) in files.enumerated() {
            if files.count > 1 {
                if i > 0 { shell.stdout("\n") }
                shell.stdout("==> \(path) <==\n")
            }
            if path == "-" {
                let lines = await collectStdinLines(shell: shell)
                emit(lines: lastN(lines), shell: shell)
                continue
            }
            let resolved = shell.resolvePath(path)
            do {
                let data = try await shell.fileSystem.readData(resolved)
                let text = String(decoding: data, as: UTF8.self)
                let lines = text.split(separator: "\n",
                                       omittingEmptySubsequences: false)
                                .map(String.init)
                // `split` with omittingEmptySubsequences:false leaves a
                // trailing "" when the input ends in `\n` — drop it so
                // we don't tail an extra blank line.
                let trimmed = (text.hasSuffix("\n") && !lines.isEmpty)
                    ? Array(lines.dropLast())
                    : lines
                emit(lines: lastN(trimmed), shell: shell)
            } catch FileSystemError.notFound {
                shell.stderr("tail: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("tail: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("tail: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func collectStdinLines(shell: Shell) async -> [String] {
        var lines: [String] = []
        for await line in shell.stdin.lines { lines.append(line) }
        return lines
    }

    private func lastN(_ lines: [String]) -> [String] {
        guard lines.count > n else { return lines }
        return Array(lines.suffix(n))
    }

    private func emit(lines: [String], shell: Shell) {
        for line in lines {
            shell.stdout(line + "\n")
        }
    }
}
