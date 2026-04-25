import Foundation

/// `cd [DIR]` — changes the shell's working directory.
///
/// With no argument, goes to `$HOME`. With `-`, goes to `$OLDPWD`.
/// Updates `$PWD` and `$OLDPWD` to reflect the change. Only affects
/// the shell's virtual cwd — does not `chdir` the host process.
public struct CdCommand: Command {
    public let name = "cd"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let args = argv.dropFirst()
        let target: String
        if let requested = args.first, !requested.isEmpty {
            if requested == "-" {
                guard let old = shell.environment["OLDPWD"] else {
                    shell.stderr("cd: OLDPWD not set\n")
                    return .failure
                }
                target = old
            } else {
                target = requested
            }
        } else {
            guard let home = shell.environment["HOME"] else {
                shell.stderr("cd: HOME not set\n")
                return .failure
            }
            target = home
        }

        let absolute = shell.resolvePath(target)
        guard let meta = try? await shell.fileSystem.metadata(absolute),
              meta.kind == .directory
        else {
            shell.stderr("cd: no such file or directory: \(target)\n")
            return .failure
        }

        let old = shell.environment.workingDirectory
        shell.environment.workingDirectory = absolute
        shell.environment["OLDPWD"] = old
        shell.environment["PWD"] = absolute
        return .success
    }
}
