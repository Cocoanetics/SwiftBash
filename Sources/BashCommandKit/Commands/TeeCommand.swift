import ArgumentParser
import BashInterpreter
import Foundation

/// `tee [-a] FILE...` — copy stdin to stdout *and* to each FILE.
///
/// Useful for capturing partial pipeline output without breaking the
/// chain:
///
/// ```bash
/// long-running | tee progress.log | grep WARN
/// ```
///
/// Files are opened via ``Shell/openOutputPath(_:append:)``, so
/// `tee /dev/null` (silent passthrough) and `tee /dev/stderr` work
/// uniformly across `RealFileSystem`, `InMemoryFileSystem`, and any
/// sandboxed `FileSystem`.
public struct TeeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tee",
        abstract: "Copy stdin to stdout and to each FILE."
    )

    @Flag(name: [.customShort("a"), .customLong("append")],
          help: "Append to FILEs instead of overwriting.")
    public var append: Bool = false

    @Argument(help: "Output files (in addition to stdout).")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        // Open all sinks up front so a single bad path is reported
        // before we start consuming stdin.
        var sinks: [OutputSink] = []
        for f in files {
            do {
                sinks.append(
                    try await Shell.current.openOutputPath(f, append: append))
            } catch {
                Shell.current.stderr("tee: \(f): \(error)\n")
                for s in sinks { s.finish() }
                return .failure
            }
        }
        defer { for s in sinks { s.finish() } }

        for await chunk in Shell.current.stdin.bytes {
            Shell.current.stdout(chunk)
            for s in sinks { s.write(chunk) }
        }
        return .success
    }
}
