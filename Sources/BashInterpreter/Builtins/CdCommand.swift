import Foundation

/// `cd [-L|-P] [DIR]` — change the shell's working directory.
///
/// With no argument, goes to `$HOME`. With `-`, goes to `$OLDPWD` and
/// prints the new cwd (matching bash). Updates `$PWD` and `$OLDPWD`
/// to reflect the change. Only affects the shell's virtual cwd —
/// does not `chdir` the host process.
///
/// Flags:
/// - `-L` (default, "logical") — preserves the path as typed,
///   including any symlink components. `cd /var; pwd` → `/var`
///   even when `/var` is a symlink.
/// - `-P` ("physical") — canonicalizes the target path through
///   ``FileSystem/canonicalize(_:allowMissing:)`` before recording
///   it. `cd -P /var; pwd` → the resolved physical path.
public struct CdCommand: Command {
    public let name = "cd"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        // Parse leading -L / -P flags. The last one wins, matching bash.
        var physical = false
        var rest = Array(argv.dropFirst())
        flagLoop: while let first = rest.first {
            switch first {
            case "-L": physical = false; rest.removeFirst()
            case "-P": physical = true;  rest.removeFirst()
            case "--": rest.removeFirst(); break flagLoop
            default:
                if first.hasPrefix("-"), first.count > 1, first != "-" {
                    Shell.bashCurrent.stderr(
                        "cd: \(first): invalid option\n"
                        + "cd: usage: cd [-L|-P] [dir]\n")
                    return ExitStatus(2)
                }
                break flagLoop
            }
        }

        let target: String
        var printAfter = false
        if let requested = rest.first, !requested.isEmpty {
            if requested == "-" {
                guard let old = Shell.bashCurrent.environment["OLDPWD"] else {
                    Shell.bashCurrent.stderr("cd: OLDPWD not set\n")
                    return .failure
                }
                target = old
                // bash prints the destination after `cd -`.
                printAfter = true
            } else {
                target = requested
            }
        } else {
            guard let home = Shell.bashCurrent.environment["HOME"] else {
                Shell.bashCurrent.stderr("cd: HOME not set\n")
                return .failure
            }
            target = home
        }

        var absolute = Shell.bashCurrent.resolvePath(target)
        guard let meta = try? await Shell.bashCurrent.fileSystem.metadata(absolute),
              meta.kind == .directory
        else {
            Shell.bashCurrent.stderr("cd: no such file or directory: \(target)\n")
            return .failure
        }
        if physical {
            // Resolve symlinks in the path. Fall back to the logical
            // path on canonicalize failure — we already verified the
            // directory exists, so this is a defensive guard.
            if let canon = try? await Shell.bashCurrent.fileSystem
                .canonicalize(absolute, allowMissing: false)
            {
                absolute = canon
            }
        }

        let old = Shell.bashCurrent.environment.workingDirectory
        Shell.bashCurrent.environment.workingDirectory = absolute
        Shell.bashCurrent.environment["OLDPWD"] = old
        Shell.bashCurrent.environment["PWD"] = absolute
        if printAfter { Shell.bashCurrent.stdout(absolute + "\n") }
        return .success
    }
}
