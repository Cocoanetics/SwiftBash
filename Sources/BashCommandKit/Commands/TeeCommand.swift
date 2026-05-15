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
        for file in files {
            do {
                sinks.append(
                    try await Shell.bashCurrent.openOutputPath(file, append: append))
            } catch {
                Shell.bashCurrent.stderr("tee: \(file): \(error)\n")
                for sink in sinks { sink.finish() }
                return .failure
            }
        }
        defer { for sink in sinks { sink.finish() } }

        for await chunk in Shell.bashCurrent.stdin.bytes {
            Shell.bashCurrent.stdout(chunk)
            for sink in sinks { sink.write(chunk) }
        }
        return .success
    }
}
