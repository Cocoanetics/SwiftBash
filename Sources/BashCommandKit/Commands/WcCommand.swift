import ArgumentParser
import BashInterpreter

/// `wc [-l|-w|-c]` — count lines, words, and/or bytes of stdin.
///
/// With no flags, prints all three in the order `lines words bytes`
/// (matching `/usr/bin/wc`). Any flag restricts output to the
/// selected counts (in a consistent `l w c` order).
public struct WcCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "wc",
        abstract: "Count lines, words, and bytes of stdin."
    )

    @Flag(name: .customShort("l"), help: "Count newlines.")
    public var lines: Bool = false

    @Flag(name: .customShort("w"), help: "Count whitespace-separated words.")
    public var words: Bool = false

    @Flag(name: .customShort("c"), help: "Count bytes (UTF-8).")
    public var bytes: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let data  = await shell.stdin.readAllData()
        let input = String(decoding: data, as: UTF8.self)
        let showAll = !lines && !words && !bytes

        let lineCount  = input.filter { $0 == "\n" }.count
        let wordCount  = input.split(whereSeparator: { $0.isWhitespace }).count
        let byteCount  = data.count

        var pieces: [String] = []
        if lines || showAll { pieces.append("\(lineCount)") }
        if words || showAll { pieces.append("\(wordCount)") }
        if bytes || showAll { pieces.append("\(byteCount)") }
        shell.stdout(pieces.joined(separator: " ") + "\n")
        return .success
    }
}
