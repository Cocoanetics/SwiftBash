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

    public mutating func execute() async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }) {
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

    public mutating func execute() async throws -> ExitStatus {
        try await runSum(files: files, displayFor: { $0 ?? "-" }) {
            ShasumHelpers.hex(of: SHA256.hash(data: $0))
        }
    }
}

// MARK: - shared

private func runSum(
    files: [String],
    displayFor: (String?) -> String,
    
    hash: (Data) -> String
) async throws -> ExitStatus {
    if files.isEmpty {
        let data = await Shell.current.stdin.readAllData()
        Shell.current.stdout("\(hash(data))  \(displayFor(nil))\n")
        return .success
    }
    var hadError = false
    for f in files {
        do {
            let data = try await Shell.current.readDataAtPath(f)
            Shell.current.stdout("\(hash(data))  \(f)\n")
        } catch {
            Shell.current.stderr("\(f): \(error)\n")
            hadError = true
        }
    }
    return hadError ? .failure : .success
}

/// `shasum [-a 1|256|512] [FILE…]` — Perl-style frontend that picks
/// the digest algorithm via `-a`. Default is SHA-1 to match the macOS
/// `/usr/bin/shasum` defaults.
public struct ShasumCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "shasum",
        abstract: "Compute SHA-1/256/512 digests."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE arguments.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var algorithm = 1
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-a" || a == "--algorithm" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    Shell.current.stderr("shasum: option requires a numeric argument: \(a)\n")
                    return ExitStatus(2)
                }
                algorithm = n
                i += 2; continue
            }
            // `-aN` combined.
            if a.hasPrefix("-a"), let n = Int(a.dropFirst(2)) {
                algorithm = n
                i += 1; continue
            }
            files.append(a); i += 1
        }

        switch algorithm {
        case 1:
            return try await runSum(files: files, displayFor: { $0 ?? "-" }) {
                ShasumHelpers.hex(of: Insecure.SHA1.hash(data: $0))
            }
        case 256:
            return try await runSum(files: files, displayFor: { $0 ?? "-" }) {
                ShasumHelpers.hex(of: SHA256.hash(data: $0))
            }
        case 512:
            return try await runSum(files: files, displayFor: { $0 ?? "-" }) {
                ShasumHelpers.hex(of: SHA512.hash(data: $0))
            }
        default:
            Shell.current.stderr("shasum: unsupported algorithm: \(algorithm)\n")
            return ExitStatus(2)
        }
    }
}

enum ShasumHelpers {
    /// Lowercase hex of a CryptoKit digest. Generic over digest type so
    /// MD5/SHA1/SHA256 all share one formatter.
    static func hex<D: Digest>(of digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
