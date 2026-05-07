import ArgumentParser
import BashInterpreter
import Foundation

/// `base64 [-d] [FILE]` — encode (default) or decode (`-d`) Base64.
///
/// With no FILE, reads stdin. Output is wrapped at 76 columns when
/// encoding (matching BSD/GNU defaults); decoding accepts whitespace
/// freely. Pass `-` as the FILE to read stdin explicitly.
public struct Base64Command: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "base64",
        abstract: "Encode or decode Base64."
    )

    @Flag(name: [.customShort("d"), .customLong("decode")],
          help: "Decode instead of encode.")
    public var decode: Bool = false

    @Argument(help: "Input file. Reads stdin if empty (or `-`).")
    public var input: String?

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let data: Data
        if let f = input, f != "-" {
            do {
                data = try await Shell.bashCurrent.readDataAtPath(f)
            } catch {
                Shell.bashCurrent.stderr("base64: \(f): \(error)\n")
                return .failure
            }
        } else {
            data = await Shell.bashCurrent.stdin.readAllData()
        }

        if decode {
            // Strip whitespace so users can decode multiline blobs.
            let cleaned = data.filter {
                !($0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09)
            }
            guard let decoded = Data(base64Encoded: cleaned) else {
                Shell.bashCurrent.stderr("base64: invalid input\n")
                return .failure
            }
            Shell.bashCurrent.stdout(decoded)
        } else {
            let encoded = data.base64EncodedString(
                options: [.lineLength76Characters,
                          .endLineWithLineFeed])
            Shell.bashCurrent.stdout(encoded + "\n")
        }
        return .success
    }
}
