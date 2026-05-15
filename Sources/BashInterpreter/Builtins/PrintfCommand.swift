import Foundation

/// `printf [-v VAR] FORMAT [ARG ...]` — formatted output.
///
/// Walks `FORMAT` once, expanding backslash escapes and `%`-directives
/// inline. If the args outnumber the directives, the format is *reused*
/// from the start until the args are drained — bash semantics that
/// makes `printf "%s\n" a b c` print three lines from one format.
///
/// Supported directives:
/// - `%s` — string
/// - `%c` — first character of arg
/// - `%d` / `%i` / `%u` — decimal integer
/// - `%o` — octal, `%x` / `%X` — hex
/// - `%f` / `%e` / `%E` / `%g` / `%G` — floating point
/// - `%b` — string with backslash escapes processed
/// - `%q` — argument quoted for shell re-input
/// - `%%` — literal `%`
///
/// Flags (`-+ #0`), width, and precision are honoured. `*` may stand
/// in for width or precision and consumes the next arg as an integer.
///
/// `-v VAR` redirects output to a shell variable instead of stdout.
public struct PrintfCommand: Command {
    public let name = "printf"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var index = 1
        var assignTo: String?

        while index < argv.count {
            let arg = argv[index]
            if arg == "-v" {
                guard index + 1 < argv.count else {
                    Shell.bashCurrent.stderr("printf: -v: option requires an argument\n")
                    return ExitStatus(2)
                }
                assignTo = argv[index + 1]
                index += 2
            } else if arg == "--" {
                index += 1
                break
            } else {
                break
            }
        }

        guard index < argv.count else {
            Shell.bashCurrent.stderr("printf: usage: printf [-v var] format [arguments]\n")
            return ExitStatus(2)
        }

        let format = argv[index]
        let args = Array(argv[(index + 1)...])

        var output = ""
        var argIdx = 0
        // Reuse the format string until args are drained, but only if
        // the format actually consumed an arg this pass — otherwise
        // we'd loop forever on a pure-literal format.
        repeat {
            let pass = formatOnce(format: format, args: args,
                                  startAt: argIdx, output: &output)
            if !pass.consumedAny { break }
            argIdx = pass.nextArgIdx
        } while argIdx < args.count

        if let assignTo {
            Shell.bashCurrent.environment[assignTo] = output
        } else {
            Shell.bashCurrent.stdout(output)
        }
        return .success
    }

    // MARK: One pass over the format string

    struct PassResult {
        var nextArgIdx: Int
        var consumedAny: Bool
    }

    func formatOnce(format: String, args: [String],
                    startAt: Int, output: inout String) -> PassResult {
        let chars = Array(format)
        var index = 0
        var argIdx = startAt
        var consumedAny = false

        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                let (text, adv) = expandBackslash(chars, from: index)
                output += text
                index += adv
            } else if char == "%" {
                guard let (dir, nextI) = parseDirective(chars, from: index) else {
                    // Malformed directive (e.g. trailing `%`) — emit literal.
                    output.append("%")
                    index += 1
                    continue
                }
                if dir.conv == "%" {
                    output.append("%")
                    index = nextI
                    continue
                }
                // `*` width / precision pulls an int from the args.
                var directive = dir
                if directive.width == "*" {
                    directive.width = "\(intArg(args, argIdx))"
                    argIdx += 1
                }
                if directive.precision == "*" {
                    directive.precision = "\(intArg(args, argIdx))"
                    argIdx += 1
                }
                let arg = argIdx < args.count ? args[argIdx] : ""
                applyDirective(directive, arg: arg, output: &output)
                argIdx += 1
                consumedAny = true
                index = nextI
            } else {
                output.append(char)
                index += 1
            }
        }

        return PassResult(nextArgIdx: argIdx, consumedAny: consumedAny)
    }

    // MARK: Directive parsing

    struct Directive {
        var flags: String
        var width: String
        var precision: String?
        var conv: Character
    }

    // MARK: Helpers

    func intArg(_ args: [String], _ idx: Int) -> Int {
        guard idx < args.count else { return 0 }
        return Int(args[idx]) ?? 0
    }
}
