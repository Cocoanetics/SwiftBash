import ArgumentParser
import BashInterpreter
import CryptoKit
import Foundation

// MARK: - md5sum

/// `md5sum [FILE...]` — print MD5 digests in coreutils format
/// (`<hex>  <filename>`, two spaces between).
///
/// Note: this is the GNU/Linux output shape. macOS's `md5` lives in
/// ``Md5Command`` and uses `MD5 (file) = hex`.
public struct Md5sumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "md5sum",
        abstract: "Compute MD5 digests in coreutils format."
    )

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }) {
            ShasumHelpers.hex(of: Insecure.MD5.hash(data: $0))
        }
    }
}
