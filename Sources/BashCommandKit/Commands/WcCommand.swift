import ArgumentParser
import BashInterpreter
import Foundation

/// `wc [-l|-w|-c|-m] [FILE...]` — count lines, words, bytes, or
/// characters of stdin or each named file.
///
/// With no flags, prints lines+words+bytes (matching `/usr/bin/wc`).
/// Multiple files emit a per-file row plus a `total` row. Counts are
/// right-aligned in 7-wide columns to match BSD/GNU formatting.
public struct WcCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "wc",
        abstract: "Count lines, words, bytes, or characters."
    )

    @Flag(name: .customShort("l"), help: "Count newlines.")
    public var lines: Bool = false

    @Flag(name: .customShort("w"), help: "Count whitespace-separated words.")
    public var words: Bool = false

    @Flag(name: .customShort("c"), help: "Count bytes (UTF-8).")
    public var bytes: Bool = false

    @Flag(name: .customShort("m"), help: "Count characters (UTF-8 codepoints).")
    public var chars: Bool = false

    @Argument(help: "Files to count. When empty, reads stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let showAll = !lines && !words && !bytes && !chars

        if files.isEmpty {
            let data = await Shell.current.stdin.readAllData()
            let counts = compute(data: data)
            Shell.current.stdout(format(counts: counts, label: nil,
                                showAll: showAll) + "\n")
            return .success
        }

        var total = Counts()
        var hadError = false
        for path in files {
            do {
                let data = path == "-"
                    ? await Shell.current.stdin.readAllData()
                    : try await Shell.current.readDataAtPath(path)
                let c = compute(data: data)
                total.add(c)
                Shell.current.stdout(format(counts: c, label: path,
                                    showAll: showAll) + "\n")
            } catch FileSystemError.notFound {
                Shell.current.stderr("wc: \(path): No such file or directory\n")
                hadError = true
            } catch {
                Shell.current.stderr("wc: \(path): \(error)\n")
                hadError = true
            }
        }
        if files.count > 1 {
            Shell.current.stdout(format(counts: total, label: "total",
                                showAll: showAll) + "\n")
        }
        return hadError ? .failure : .success
    }

    private struct Counts {
        var lines = 0
        var words = 0
        var bytes = 0
        var chars = 0
        mutating func add(_ other: Counts) {
            lines += other.lines; words += other.words
            bytes += other.bytes; chars += other.chars
        }
    }

    private func compute(data: Data) -> Counts {
        let text = String(decoding: data, as: UTF8.self)
        return Counts(
            lines: text.filter { $0 == "\n" }.count,
            words: text.split(whereSeparator: { $0.isWhitespace }).count,
            bytes: data.count,
            chars: text.count)
    }

    private func format(counts c: Counts, label: String?, showAll: Bool) -> String {
        var pieces: [String] = []
        let pad = { (n: Int) in String(format: "%8d", n) }
        if lines || showAll { pieces.append(pad(c.lines)) }
        if words || showAll { pieces.append(pad(c.words)) }
        if bytes || showAll { pieces.append(pad(c.bytes)) }
        if chars             { pieces.append(pad(c.chars)) }
        var out = pieces.joined(separator: " ")
        if let l = label { out += " " + l }
        return out
    }
}
