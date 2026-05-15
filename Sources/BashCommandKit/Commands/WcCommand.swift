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
            let data = await Shell.bashCurrent.stdin.readAllData()
            let counts = compute(data: data)
            Shell.bashCurrent.stdout(format(counts: counts, label: nil,
                                showAll: showAll) + "\n")
            return .success
        }

        var total = Counts()
        var hadError = false
        for path in files {
            do {
                let data = path == "-"
                    ? await Shell.bashCurrent.stdin.readAllData()
                    : try await Shell.bashCurrent.readDataAtPath(path)
                let counts = compute(data: data)
                total.add(counts)
                Shell.bashCurrent.stdout(format(counts: counts, label: path,
                                    showAll: showAll) + "\n")
            } catch FileSystemError.notFound {
                Shell.bashCurrent.stderr("wc: \(path): No such file or directory\n")
                hadError = true
            } catch {
                Shell.bashCurrent.stderr("wc: \(path): \(error)\n")
                hadError = true
            }
        }
        if files.count > 1 {
            Shell.bashCurrent.stdout(format(counts: total, label: "total",
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
        // swiftlint:disable:next optional_data_string_conversion - wc accepts non-UTF-8 byte streams
        let text = String(decoding: data, as: UTF8.self)
        return Counts(
            lines: text.filter { $0 == "\n" }.count,
            words: text.split(whereSeparator: { $0.isWhitespace }).count,
            bytes: data.count,
            chars: text.count)
    }

    private func format(counts: Counts, label: String?, showAll: Bool) -> String {
        var pieces: [String] = []
        let pad = { (count: Int) in String(format: "%8d", count) }
        if lines || showAll { pieces.append(pad(counts.lines)) }
        if words || showAll { pieces.append(pad(counts.words)) }
        if bytes || showAll { pieces.append(pad(counts.bytes)) }
        if chars { pieces.append(pad(counts.chars)) }
        var out = pieces.joined(separator: " ")
        if let label { out += " " + label }
        return out
    }
}
