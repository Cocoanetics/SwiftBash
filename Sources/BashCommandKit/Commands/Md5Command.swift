import ArgumentParser
import BashInterpreter
import CryptoKit
import Foundation

/// `md5 [-q] [-s STRING] [FILE...]` — print the MD5 digest of each
/// input.
///
/// Output formats (matches macOS `md5`):
/// - With files, default: `MD5 (FILE) = HEX`
/// - With files and `-q`: just the hex digest, one per line
/// - With `-s STRING`: hashes the string literal (no file read)
/// - With no args, hashes stdin and prints the hex digest
///
/// Backed by `CryptoKit.Insecure.MD5`. MD5 is broken for cryptographic
/// uses; this command exists for checksum compatibility with existing
/// scripts.
public struct Md5Command: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "md5",
        abstract: "Compute MD5 digests."
    )

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Print only the hex digest (no `MD5 (FILE) =` prefix).")
    public var quiet: Bool = false

    @Option(name: [.customShort("s"), .customLong("string")],
            help: "Hash STRING (UTF-8) instead of a file.")
    public var string: String?

    @Argument(help: "Files to hash. Reads stdin if empty.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if let s = string {
            let h = Self.hex(of: Data(s.utf8))
            shell.stdout(quiet
                ? h + "\n"
                : "MD5 (\"\(s)\") = \(h)\n")
            return .success
        }
        if files.isEmpty {
            let data = await shell.stdin.readAllData()
            shell.stdout(Self.hex(of: data) + "\n")
            return .success
        }
        var hadError = false
        for f in files {
            do {
                let data = try await shell.readDataAtPath(f)
                let h = Self.hex(of: data)
                shell.stdout(quiet
                    ? h + "\n"
                    : "MD5 (\(f)) = \(h)\n")
            } catch {
                shell.stderr("md5: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Lowercase hex of an MD5 digest. Lives in one place so the
    /// formatting matches across input modes.
    static func hex(of data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
