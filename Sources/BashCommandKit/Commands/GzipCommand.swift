import ArgumentParser
import BashInterpreter
import Foundation

// MARK: - gzip

/// `gzip [-c] [-d] [FILE...]` — compress files using the gzip format.
///
/// Default behaviour (per BSD/GNU `gzip`):
/// - Without `-c`: each FILE is replaced by `FILE.gz`; stdin → stdout
///   when no FILEs are given.
/// - With `-c`: results stream to stdout instead of replacing files.
/// - With `-d` (or invoked as `gunzip`): decompress instead, replacing
///   `FILE.gz` with `FILE` (or stripping any other suffix).
///
/// Wraps Apple's `Compression` framework (raw DEFLATE via
/// `COMPRESSION_ZLIB`) with a hand-coded gzip header / trailer. CRC32
/// is computed in pure Swift so we don't pull in `zlib`.
public struct GzipCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gzip",
        abstract: "Compress (or `-d` decompress) using gzip."
    )

    @Flag(name: [.customShort("c"), .customLong("stdout")],
          help: "Write output to stdout instead of replacing files.")
    public var toStdout: Bool = false

    @Flag(name: [.customShort("d"), .customLong("decompress")],
          help: "Decompress instead of compressing.")
    public var decompress: Bool = false

    @Argument(help: "Files to (de)compress. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        try await runGzip(decompress: decompress,
                          toStdout: toStdout,
                          files: files,
                          commandName: "gzip")
    }
}
