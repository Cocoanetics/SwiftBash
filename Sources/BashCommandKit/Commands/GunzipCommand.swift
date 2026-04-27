import ArgumentParser
import BashInterpreter
import Foundation

// MARK: - gzip

/// `gunzip [-c] [FILE...]` — decompress gzip-format files. Same as
/// `gzip -d`. See ``GzipCommand`` for the implementation.
public struct GunzipCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gunzip",
        abstract: "Decompress gzip-format files."
    )

    @Flag(name: [.customShort("c"), .customLong("stdout")],
          help: "Write output to stdout instead of replacing files.")
    public var toStdout: Bool = false

    @Argument(help: "Files to decompress. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        try await runGzip(decompress: true,
                          toStdout: toStdout,
                          files: files,
                          commandName: "gunzip")
    }
}
