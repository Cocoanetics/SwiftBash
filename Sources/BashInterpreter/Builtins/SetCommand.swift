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

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        if args.isEmpty {
            for (i, value) in Shell.bashCurrent.positionalParameters.enumerated() {
                Shell.bashCurrent.stdout("\(i + 1)=\(value)\n")
            }
            return .success
        }

        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                Shell.bashCurrent.positionalParameters = Array(args[(i + 1)...])
                return .success
            }
            // `-o NAME` / `+o NAME`
            if a == "-o" || a == "+o" {
                guard i + 1 < args.count else {
                    Shell.bashCurrent.stderr("set: \(a): option name required\n")
                    return ExitStatus(2)
                }
                let on = (a == "-o")
                if let err = applyLongOption(args[i + 1], on: on) {
                    Shell.bashCurrent.stderr(err)
                    return ExitStatus(2)
                }
                i += 2
                continue
            }
            // `-X` / `+X` short-flag bundles. `o` is special: real
            // bash treats `set -euo pipefail` as `set -eu -o pipefail`
            // — when an `o` appears inside the bundle it consumes the
            // following positional as the long-option name. Apply the
            // preceding short flags left-to-right, then short-circuit
            // out to the next argv element.
            if (a.hasPrefix("-") || a.hasPrefix("+")), a.count >= 2 {
                let on = a.hasPrefix("-")
                var sawO = false
                for ch in a.dropFirst() {
                    if ch == "o" { sawO = true; break }
                    if let err = applyShortFlag(ch, on: on) {
                        Shell.bashCurrent.stderr(err)
                        return ExitStatus(2)
                    }
                }
                if sawO {
                    guard i + 1 < args.count else {
                        Shell.bashCurrent.stderr(
                            "set: -o: option name required\n")
                        return ExitStatus(2)
                    }
                    if let err = applyLongOption(args[i + 1], on: on) {
                        Shell.bashCurrent.stderr(err)
                        return ExitStatus(2)
                    }
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            // Anything else: bash treats `set arg1 arg2` as setting
            // positional parameters (POSIX). Match that.
            Shell.bashCurrent.positionalParameters = Array(args[i...])
            return .success
        }
        return .success
    }

    /// Apply a single short-flag character. Returns an error string on
    /// unknown flags, `nil` on success.
    private func applyShortFlag(_ ch: Character, on: Bool) -> String? {
        switch ch {
        case "e": Shell.bashCurrent.errexit = on
        case "u": Shell.bashCurrent.nounset = on
        default:
            return "set: -\(ch): invalid option\n"
        }
        return nil
    }

    /// Apply a long option name (`-o NAME` / `+o NAME`).
    private func applyLongOption(_ name: String, on: Bool) -> String? {
        switch name {
        case "errexit":  Shell.bashCurrent.errexit = on
        case "pipefail": Shell.bashCurrent.pipefail = on
        case "nounset":  Shell.bashCurrent.nounset = on
        default:
            return "set: -o: invalid option name: \(name)\n"
        }
        return nil
    }
}
