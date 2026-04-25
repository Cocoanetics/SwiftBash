import Foundation

/// `getopts OPTSTRING NAME [ARG …]` — parse one positional-style
/// short option per call, suitable for use inside a `while` loop.
///
/// State is carried between calls in two shell variables:
/// - `OPTIND` — index of the next argument to inspect (1-based,
///   reset to `1` before the first call). Incremented by getopts as
///   it consumes args.
/// - `OPTARG` — set to the argument value when the matched option
///   takes one (a letter followed by `:` in `OPTSTRING`).
///
/// `OPTSTRING` is a sequence of option letters; a trailing `:` on a
/// letter means it requires an argument. A leading `:` enables
/// "silent" mode: errors set `NAME` to `?` (unknown) or `:` (missing
/// arg) and `OPTARG` to the offending letter, instead of printing.
///
/// If `[ARG …]` is given, those are the args inspected; otherwise
/// the shell's positional parameters are used.
public struct GetoptsCommand: Command {
    public let name = "getopts"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        guard argv.count >= 3 else {
            shell.stderr("getopts: usage: getopts optstring name [arg ...]\n")
            return ExitStatus(2)
        }
        let rawOptstring = argv[1]
        let varName = argv[2]
        let providedArgs = Array(argv.dropFirst(3))
        let args = providedArgs.isEmpty
            ? shell.positionalParameters
            : providedArgs

        let silent = rawOptstring.first == ":"
        let optstring = silent ? String(rawOptstring.dropFirst()) : rawOptstring

        // OPTIND is 1-based; default to 1 if unset/invalid.
        var optind = max(1, Int(shell.environment["OPTIND"] ?? "1") ?? 1)

        // Out of args? End of option processing.
        guard optind - 1 < args.count else {
            shell.environment[varName] = "?"
            return ExitStatus(1)
        }
        let currentArg = args[optind - 1]

        // Non-option arg, lone `-`, or explicit `--` ends parsing.
        // For `--`, OPTIND moves past it (POSIX).
        if currentArg == "-" || !currentArg.hasPrefix("-") {
            shell.environment[varName] = "?"
            return ExitStatus(1)
        }
        if currentArg == "--" {
            shell.environment["OPTIND"] = "\(optind + 1)"
            shell.getoptsCharIndex = 1
            shell.environment[varName] = "?"
            return ExitStatus(1)
        }

        let chars = Array(currentArg)
        var charIdx = shell.getoptsCharIndex
        // If charIdx is somehow past the end, advance to the next arg
        // — defensive against the user mutating OPTIND mid-loop.
        if charIdx >= chars.count {
            optind += 1
            charIdx = 1
            shell.getoptsCharIndex = 1
            shell.environment["OPTIND"] = "\(optind)"
            return try await run(argv, shell: shell)
        }

        let letter = chars[charIdx]
        let optKey = String(letter)
        // Look up the letter in optstring.
        guard let pos = optstring.firstIndex(of: letter) else {
            // Unknown option.
            if silent {
                shell.environment[varName] = "?"
                shell.environment["OPTARG"] = optKey
            } else {
                shell.stderr("getopts: illegal option -- \(optKey)\n")
                shell.environment[varName] = "?"
                shell.environment.variables.removeValue(forKey: "OPTARG")
            }
            advance(shell: shell, charIdx: charIdx, chars: chars, optind: optind)
            return .success
        }

        let next = optstring.index(after: pos)
        let takesArg = next < optstring.endIndex && optstring[next] == ":"
        if takesArg {
            // Argument may be glued to the option (`-bvalue`) or come
            // as the next arg (`-b value`).
            if charIdx + 1 < chars.count {
                shell.environment["OPTARG"] = String(chars[(charIdx + 1)...])
                shell.environment["OPTIND"] = "\(optind + 1)"
                shell.getoptsCharIndex = 1
            } else if optind < args.count {
                shell.environment["OPTARG"] = args[optind]
                shell.environment["OPTIND"] = "\(optind + 2)"
                shell.getoptsCharIndex = 1
            } else {
                // Required arg missing.
                if silent {
                    shell.environment[varName] = ":"
                    shell.environment["OPTARG"] = optKey
                } else {
                    shell.stderr("getopts: option requires an argument -- \(optKey)\n")
                    shell.environment[varName] = "?"
                    shell.environment.variables.removeValue(forKey: "OPTARG")
                }
                shell.environment["OPTIND"] = "\(optind + 1)"
                shell.getoptsCharIndex = 1
                return .success
            }
            shell.environment[varName] = optKey
            return .success
        }

        // Plain flag.
        shell.environment[varName] = optKey
        shell.environment.variables.removeValue(forKey: "OPTARG")
        advance(shell: shell, charIdx: charIdx, chars: chars, optind: optind)
        return .success
    }

    /// Move past the current letter, advancing to the next arg if we
    /// just consumed the last letter of a bundled short-option run.
    private func advance(shell: Shell, charIdx: Int,
                         chars: [Character], optind: Int) {
        if charIdx + 1 < chars.count {
            shell.getoptsCharIndex = charIdx + 1
            shell.environment["OPTIND"] = "\(optind)"
        } else {
            shell.getoptsCharIndex = 1
            shell.environment["OPTIND"] = "\(optind + 1)"
        }
    }
}
