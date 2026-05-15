import ArgumentParser
import BashInterpreter
import Crypto
import Foundation

// MARK: - md5sum

/// `sha1sum [FILE...]` — coreutils-format SHA-1 digests.
public struct Sha1sumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sha1sum",
        abstract: "Compute SHA-1 digests in coreutils format."
    )

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        try await runSum(
            files: files,
            displayFor: { $0 ?? "-" },
            hash: { ShasumHelpers.hex(of: Insecure.SHA1.hash(data: $0)) })
    }
}
