import Foundation

/// `echo [-n] [--] ARGS...`
///
/// Prints its arguments separated by a single space. By default appends
/// a trailing newline; `-n` suppresses it. `--` ends option parsing so
/// subsequent tokens starting with `-` are treated as data.
public struct EchoCommand: Command {
    public let name = "echo"

    public init() {}

    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        var args = Array(argv.dropFirst())
        var newline = true

        // Only treat options that appear contiguously at the start, before
        // any `--` sentinel or data argument.
        optionLoop: while let first = args.first {
            switch first {
            case "-n": newline = false; args.removeFirst()
            case "--": args.removeFirst(); break optionLoop
            default: break optionLoop
            }
        }

        let joined = args.joined(separator: " ")
        shell.stdout(joined + (newline ? "\n" : ""))
        return .success
    }
}
