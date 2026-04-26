import Foundation

/// `cd [DIR]` — changes the shell's working directory.
///
/// With no argument, goes to `$HOME`. With `-`, goes to `$OLDPWD`.
/// Updates `$PWD` and `$OLDPWD` to reflect the change. Only affects
/// the shell's virtual cwd — does not `chdir` the host process.
public struct CdCommand: Command {
    public let name = "cd"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = argv.dropFirst()
        let target: String
        if let requested = args.first, !requested.isEmpty {
            if requested == "-" {
                guard let old = Shell.current.environment["OLDPWD"] else {
                    Shell.current.stderr("cd: OLDPWD not set\n")
                    return .failure
                }
                target = old
            } else {
                target = requested
            }
        } else {
            guard let home = Shell.current.environment["HOME"] else {
                Shell.current.stderr("cd: HOME not set\n")
                return .failure
            }
            target = home
        }

        let absolute = Shell.current.resolvePath(target)
        guard let meta = try? await Shell.current.fileSystem.metadata(absolute),
              meta.kind == .directory
        else {
            Shell.current.stderr("cd: no such file or directory: \(target)\n")
            return .failure
        }

        let old = Shell.current.environment.workingDirectory
        Shell.current.environment.workingDirectory = absolute
        Shell.current.environment["OLDPWD"] = old
        Shell.current.environment["PWD"] = absolute
        return .success
    }
}
