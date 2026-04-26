import ArgumentParser
import BashInterpreter

/// `seq [-s SEP] [-w] [LAST]`
/// `seq [-s SEP] [-w] FIRST LAST`
/// `seq [-s SEP] [-w] FIRST INCREMENT LAST`
///
/// Print a sequence of numbers from `FIRST` to `LAST` (inclusive) in
/// steps of `INCREMENT`. `FIRST` defaults to `1`, `INCREMENT` to `1`
/// (or `-1` if `FIRST > LAST`).
///
/// Flags:
/// - `-s SEP` / `-sSEP` — separator between numbers (default newline).
/// - `-w` / `--equal-width` — left-pad with zeros so every value is
///   the same width.
public struct SeqCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "seq",
        abstract: "Print a sequence of numbers."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then LAST | FIRST LAST | FIRST INCREMENT LAST.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var separator = "\n"
        var equalWidth = false
        var positional: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { positional.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-s" || a == "--separator" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("seq: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                separator = rawArgv[i + 1]
                i += 2; continue
            }
            // `-sCHAR(s)` combined.
            if a.hasPrefix("-s"), a.count > 2,
               !isNumericArg(a)
            {
                separator = String(a.dropFirst(2))
                i += 1; continue
            }
            if a == "-w" || a == "--equal-width" {
                equalWidth = true; i += 1; continue
            }
            if a == "-f" || a == "--format" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("seq: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                // We support the simplest case: pass-through the format
                // and use it via String(format:). Bash's seq accepts
                // anything printf accepts.
                _ = rawArgv[i + 1] // currently unused — emit unformatted
                i += 2; continue
            }
            // `-NUM` and bare numbers are positional.
            positional.append(a); i += 1
        }

        var parsed: [Double] = []
        parsed.reserveCapacity(positional.count)
        for raw in positional {
            guard let n = Double(raw) else {
                shell.stderr("seq: invalid number: \(raw)\n")
                return .failure
            }
            parsed.append(n)
        }

        let first: Double, step: Double, last: Double
        switch parsed.count {
        case 1: first = 1;          step = 1;           last = parsed[0]
        case 2: first = parsed[0];  step = 1;           last = parsed[1]
        case 3: first = parsed[0];  step = parsed[1];   last = parsed[2]
        default:
            shell.stderr("seq: expected 1, 2, or 3 numeric arguments\n")
            return .failure
        }

        if step == 0 {
            shell.stderr("seq: invalid zero increment value\n")
            return .failure
        }

        var values: [String] = []
        var v = first
        let ascending = step > 0
        while (ascending && v <= last + 1e-9) || (!ascending && v >= last - 1e-9) {
            values.append(format(v))
            v += step
        }
        if equalWidth, let width = values.map({ widthIgnoringSign($0) }).max() {
            values = values.map { padLeftZeros($0, toWidth: width) }
        }
        shell.stdout(values.joined(separator: separator) + "\n")
        return .success
    }

    private func format(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    private func isNumericArg(_ a: String) -> Bool {
        // True for `-3`, `-3.5`, `+1`, `2` — used to disambiguate
        // `-3` (a negative LAST) from `-3...something` (an option).
        let body = a.hasPrefix("-") || a.hasPrefix("+")
            ? String(a.dropFirst()) : a
        return Double(body) != nil
    }

    private func widthIgnoringSign(_ s: String) -> Int {
        s.first == "-" ? s.count - 1 : s.count
    }

    private func padLeftZeros(_ s: String, toWidth w: Int) -> String {
        let body = s.first == "-" ? String(s.dropFirst()) : s
        let pad = max(0, w - body.count)
        let zeros = String(repeating: "0", count: pad)
        return (s.first == "-" ? "-" : "") + zeros + body
    }
}
