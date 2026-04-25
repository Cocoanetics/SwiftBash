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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }, shell: shell) {
            ShasumHelpers.hex(of: Insecure.MD5.hash(data: $0))
        }
    }
}

// MARK: - sha1sum

/// `sha1sum [FILE...]` — coreutils-format SHA-1 digests.
public struct Sha1sumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sha1sum",
        abstract: "Compute SHA-1 digests in coreutils format."
    )

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }, shell: shell) {
            ShasumHelpers.hex(of: Insecure.SHA1.hash(data: $0))
        }
    }
}

// MARK: - sha256sum

/// `sha256sum [FILE...]` — coreutils-format SHA-256 digests.
public struct Sha256sumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sha256sum",
        abstract: "Compute SHA-256 digests in coreutils format."
    )

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }, shell: shell) {
            ShasumHelpers.hex(of: SHA256.hash(data: $0))
        }
    }
}

// MARK: - shared

private func runSum(
    files: [String],
    displayFor: (String?) -> String,
    shell: Shell,
    hash: (Data) -> String
) async throws -> ExitStatus {
    if files.isEmpty {
        let data = await shell.stdin.readAllData()
        shell.stdout("\(hash(data))  \(displayFor(nil))\n")
        return .success
    }
    var hadError = false
    for f in files {
        do {
            let data = try await shell.readDataAtPath(f)
            shell.stdout("\(hash(data))  \(f)\n")
        } catch {
            shell.stderr("\(f): \(error)\n")
            hadError = true
        }
    }
    return hadError ? .failure : .success
}

enum ShasumHelpers {
    /// Lowercase hex of a CryptoKit digest. Generic over digest type so
    /// MD5/SHA1/SHA256 all share one formatter.
    static func hex<D: Digest>(of digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
