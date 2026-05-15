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

        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-a" || arg == "--algorithm" {
                guard index + 1 < rawArgv.count, let algo = Int(rawArgv[index + 1]) else {
                    Shell.bashCurrent.stderr("shasum: option requires a numeric argument: \(arg)\n")
                    return ExitStatus(2)
                }
                algorithm = algo
                index += 2; continue
            }
            // `-aN` combined.
            if arg.hasPrefix("-a"), let algo = Int(arg.dropFirst(2)) {
                algorithm = algo
                index += 1; continue
            }
            files.append(arg); index += 1
        }

        switch algorithm {
        case 1:
            return try await runSum(
                files: files,
                displayFor: { $0 ?? "-" },
                hash: { ShasumHelpers.hex(of: Insecure.SHA1.hash(data: $0)) })
        case 256:
            return try await runSum(
                files: files,
                displayFor: { $0 ?? "-" },
                hash: { ShasumHelpers.hex(of: SHA256.hash(data: $0)) })
        case 512:
            return try await runSum(
                files: files,
                displayFor: { $0 ?? "-" },
                hash: { ShasumHelpers.hex(of: SHA512.hash(data: $0)) })
        default:
            Shell.bashCurrent.stderr("shasum: unsupported algorithm: \(algorithm)\n")
            return ExitStatus(2)
        }
    }
}
