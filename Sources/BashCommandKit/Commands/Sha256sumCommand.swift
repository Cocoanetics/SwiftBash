import ArgumentParser
import BashInterpreter
import Crypto
import Foundation

// MARK: - md5sum

/// `sha256sum [FILE...]` — coreutils-format SHA-256 digests.
public struct Sha256sumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sha256sum",
        abstract: "Compute SHA-256 digests in coreutils format."
    )

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }) {
            ShasumHelpers.hex(of: SHA256.hash(data: $0))
        }
    }
}
