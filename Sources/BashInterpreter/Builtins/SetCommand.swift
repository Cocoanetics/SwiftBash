import Foundation

/// `set [-- ARG ...]` — replace the shell's positional parameters
/// with the given list. Without `--`, this skeleton just lists them
/// (real bash also takes `-e`, `-x`, etc.; those aren't modelled).
///
/// ```bash
/// set -- a b c
/// echo $1 $2 $3   # → a b c
/// ```
public struct SetCommand: Command {
    public let name = "set"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        guard let dashDash = args.firstIndex(of: "--") else {
            // No `--` separator: list current positional params and
            // exported environment, à la bash without options.
            for (i, value) in shell.positionalParameters.enumerated() {
                shell.stdout("\(i + 1)=\(value)\n")
            }
            return .success
        }
        let newParams = Array(args[(dashDash + 1)...])
        shell.positionalParameters = newParams
        return .success
    }
}
