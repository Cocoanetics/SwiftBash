import ArgumentParser
import BashInterpreter
import Foundation

/// `mktemp [-d] [-t PREFIX] [TEMPLATE]` — create a unique file or
/// directory in the shell's filesystem and print its path.
///
/// The trailing `X` characters in `TEMPLATE` are replaced with a
/// random suffix; the rest of the template is kept verbatim. With
/// no arguments the template is `tmp.XXXXXXXX` placed under the
/// shell filesystem's temp directory (via
/// ``FileSystem/makeTempPath(prefix:)``).
///
/// Useful for scripts that need a scratch file without race
/// conditions:
///
/// ```bash
/// out=$(mktemp)
/// trap 'rm -f "$out"' EXIT
/// some-cmd > "$out"
/// ```
public struct MktempCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mktemp",
        abstract: "Create a unique temporary file or directory."
    )

    @Flag(name: .customShort("d"),
          help: "Create a directory instead of a file.")
    public var directory: Bool = false

    @Flag(name: .customShort("q"),
          help: "Quiet — suppress diagnostics on errors.")
    public var quiet: Bool = false

    @Flag(name: .customShort("u"),
          help: "Unsafe — print a name without actually creating it.")
    public var dryRun: Bool = false

    @Option(name: .customShort("t"),
            help: "Use a template under the temp directory with this prefix.")
    public var prefix: String?

    @Argument(help: "Template name; trailing Xs are replaced with random characters.")
    public var template: String?

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let path: String
        do {
            path = try await resolveTemplate()
        } catch {
            if !quiet {
                Shell.bashCurrent.stderr("mktemp: \(error.localizedDescription)\n")
            }
            return .failure
        }

        if dryRun {
            Shell.bashCurrent.stdout(path + "\n")
            return .success
        }

        do {
            if directory {
                try await Shell.bashCurrent.fileSystem.createDirectory(
                    path, intermediates: false)
            } else {
                try await Shell.bashCurrent.fileSystem.writeData(
                    Data(), to: path, append: false)
            }
        } catch {
            if !quiet {
                Shell.bashCurrent.stderr("mktemp: \(path): \(error)\n")
            }
            return .failure
        }

        Shell.bashCurrent.stdout(path + "\n")
        return .success
    }

    private func resolveTemplate() async throws -> String {
        // Decide the template body and which directory it lives in.
        if let templateText = template {
            let resolved = Shell.bashCurrent.resolvePath(templateText)
            return Self.replacingX(in: resolved)
        }
        let chosenPrefix = prefix ?? "tmp"
        // makeTempPath gives a unique full path under the FS's temp
        // directory; any trailing "X"-style randomness is provided by
        // the FS implementation itself.
        return try await Shell.bashCurrent.fileSystem.makeTempPath(prefix: chosenPrefix)
    }

    /// Replace the trailing run of `X` characters with a random
    /// suffix of the same length. `mktemp` requires at least 3
    /// trailing Xs; we accept any count ≥ 1 and treat 0 as
    /// "no substitution needed".
    ///
    /// The replacement alphabet deliberately omits `X` so the
    /// substitution can be detected by the absence of `X` in the
    /// trailing run — matches what the BSD/GNU `mktemp` binaries
    /// produce in practice and keeps the round-trip test stable.
    static func replacingX(in template: String) -> String {
        var chars = Array(template)
        var count = 0
        while count < chars.count, chars[chars.count - 1 - count] == "X" { count += 1 }
        guard count > 0 else { return template }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwyz" +
                             "ABCDEFGHIJKLMNOPQRSTUVWYZ")
        for idx in (chars.count - count)..<chars.count {
            chars[idx] = alphabet.randomElement()!
        }
        return String(chars)
    }
}
