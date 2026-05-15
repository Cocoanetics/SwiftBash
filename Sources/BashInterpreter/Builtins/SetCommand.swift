import Foundation

/// `set` — toggle shell options and replace positional parameters.
///
/// Supported invocations:
/// - `set -e` / `set +e` — toggle `errexit`.
/// - `set -o pipefail` / `set +o pipefail` — toggle the like-named option.
/// - `set -o errexit` / `set -o nounset` etc. — long-name option toggling.
/// - `set -u` / `set +u` — toggle `nounset`.
/// - `set -- ARG …` — replace positional parameters (`$1, $2, …`).
/// - `set` (no args) — list current positional parameters.
///
/// Combined short flags (`set -eu`) are accepted: each character is
/// applied left-to-right.
public struct SetCommand: Command {
    public let name = "set"
    public init() {}

    // POSIX `set` is a multi-mode command: list-positionals, `-o NAME`,
    // bundled short flags `-eu`, special `-euo NAME`, `--`-terminated
    // positional rewrite, or fall-through positional assignment. Per-
    // branch helpers would scatter the `args[index...]` consumption.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        if args.isEmpty {
            for (idx, value) in Shell.bashCurrent.positionalParameters.enumerated() {
                Shell.bashCurrent.stdout("\(idx + 1)=\(value)\n")
            }
            return .success
        }

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                Shell.bashCurrent.positionalParameters = Array(args[(index + 1)...])
                return .success
            }
            // `-o NAME` / `+o NAME`
            if arg == "-o" || arg == "+o" {
                guard index + 1 < args.count else {
                    Shell.bashCurrent.stderr("set: \(arg): option name required\n")
                    return ExitStatus(2)
                }
                let enable = (arg == "-o")
                if let err = applyLongOption(args[index + 1], on: enable) {
                    Shell.bashCurrent.stderr(err)
                    return ExitStatus(2)
                }
                index += 2
                continue
            }
            // `-X` / `+X` short-flag bundles. `o` is special: real
            // bash treats `set -euo pipefail` as `set -eu -o pipefail`
            // — when an `o` appears inside the bundle it consumes the
            // following positional as the long-option name. Apply the
            // preceding short flags left-to-right, then short-circuit
            // out to the next argv element.
            if arg.hasPrefix("-") || arg.hasPrefix("+"), arg.count >= 2 {
                let enable = arg.hasPrefix("-")
                var sawO = false
                for char in arg.dropFirst() {
                    if char == "o" { sawO = true; break }
                    if let err = applyShortFlag(char, on: enable) {
                        Shell.bashCurrent.stderr(err)
                        return ExitStatus(2)
                    }
                }
                if sawO {
                    guard index + 1 < args.count else {
                        Shell.bashCurrent.stderr(
                            "set: -o: option name required\n")
                        return ExitStatus(2)
                    }
                    if let err = applyLongOption(args[index + 1], on: enable) {
                        Shell.bashCurrent.stderr(err)
                        return ExitStatus(2)
                    }
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            // Anything else: bash treats `set arg1 arg2` as setting
            // positional parameters (POSIX). Match that.
            Shell.bashCurrent.positionalParameters = Array(args[index...])
            return .success
        }
        return .success
    }

    /// Apply a single short-flag character. Returns an error string on
    /// unknown flags, `nil` on success.
    private func applyShortFlag(_ char: Character, on enable: Bool) -> String? {
        switch char {
        case "e": Shell.bashCurrent.errexit = enable
        case "u": Shell.bashCurrent.nounset = enable
        case "x": Shell.bashCurrent.xtrace = enable
        case "v": Shell.bashCurrent.verbose = enable
        default:
            return "set: -\(char): invalid option\n"
        }
        return nil
    }

    /// Apply a long option name (`-o NAME` / `+o NAME`).
    private func applyLongOption(_ name: String, on enable: Bool) -> String? {
        switch name {
        case "errexit":  Shell.bashCurrent.errexit = enable
        case "pipefail": Shell.bashCurrent.pipefail = enable
        case "nounset":  Shell.bashCurrent.nounset = enable
        case "xtrace":   Shell.bashCurrent.xtrace = enable
        case "verbose":  Shell.bashCurrent.verbose = enable
        default:
            return "set: -o: invalid option name: \(name)\n"
        }
        return nil
    }
}
