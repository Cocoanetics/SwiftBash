import Foundation

/// `pwd [-L|-P]` — print the shell's working directory.
///
/// - `-L` (default, "logical") prints the value of
///   ``Environment/workingDirectory`` verbatim — the path the user
///   `cd`'d into, including any symlink components.
/// - `-P` ("physical") resolves symlinks first via
///   ``FileSystem/canonicalize(_:allowMissing:)`` and prints the
///   canonical path. Useful when scripts need a stable identity for
///   the directory regardless of how they got there.
///
/// Matches bash's flag semantics: the last flag wins, and unrecognised
/// flags exit with status 2 and a usage diagnostic.
public struct PwdCommand: Command {
    public let name = "pwd"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var physical = false
        for arg in argv.dropFirst() {
            switch arg {
            case "-L": physical = false
            case "-P": physical = true
            case "--": continue
            default:
                Shell.current.stderr(
                    "pwd: \(arg): invalid option\n"
                    + "pwd: usage: pwd [-LP]\n")
                return ExitStatus(2)
            }
        }
        let logical = Shell.current.environment.workingDirectory
        if physical {
            if let canon = try? await Shell.current.fileSystem
                .canonicalize(logical, allowMissing: true)
            {
                Shell.current.stdout(canon + "\n")
                return .success
            }
        }
        Shell.current.stdout(logical + "\n")
        return .success
    }
}
