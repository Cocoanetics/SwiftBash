import ArgumentParser
import BashInterpreter
import Crypto
import Foundation

// MARK: - md5sum

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
