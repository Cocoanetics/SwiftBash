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

    // Two-step: parse argv (one switch), then parse the 1/2/3 numeric
    // operands (another switch), then drive the sequence loop. Each
    // step is independent and short; splitting them out further would
    // just shuttle six values across helper boundaries.
    // swiftlint:disable:next cyclomatic_complexity
    public mutating func execute() async throws -> ExitStatus {
        var parsedArgs: ParsedArgs
        switch parseArgs() {
        case .success(let args): parsedArgs = args
        case .failure(let code): return code
        }
        let separator = parsedArgs.separator
        let equalWidth = parsedArgs.equalWidth
        let positional = parsedArgs.positional

        var parsed: [Double] = []
        parsed.reserveCapacity(positional.count)
        for raw in positional {
            guard let num = Double(raw) else {
                Shell.bashCurrent.stderr("seq: invalid number: \(raw)\n")
                return .failure
            }
            parsed.append(num)
        }

        let first: Double, step: Double, last: Double
        switch parsed.count {
        case 1: first = 1;          step = 1;           last = parsed[0]
        case 2: first = parsed[0];  step = 1;           last = parsed[1]
        case 3: first = parsed[0];  step = parsed[1];   last = parsed[2]
        default:
            Shell.bashCurrent.stderr("seq: expected 1, 2, or 3 numeric arguments\n")
            return .failure
        }

        if step == 0 {
            Shell.bashCurrent.stderr("seq: invalid zero increment value\n")
            return .failure
        }

        var values: [String] = []
        var current = first
        let ascending = step > 0
        while (ascending && current <= last + 1e-9) || (!ascending && current >= last - 1e-9) {
            // Pure-CPU loop on a user-controlled count; honour
            // cancellation every iteration so `seq 1 1000000000` &
            // `kill $!` actually stops.
            try Task.checkCancellation()
            values.append(format(current))
            current += step
        }
        if equalWidth, let width = values.map({ widthIgnoringSign($0) }).max() {
            values = values.map { padLeftZeros($0, toWidth: width) }
        }
        Shell.bashCurrent.stdout(values.joined(separator: separator) + "\n")
        return .success
    }

    private struct ParsedArgs {
        var separator: String
        var equalWidth: Bool
        var positional: [String]
    }

    private enum ArgResult {
        case success(ParsedArgs)
        case failure(ExitStatus)
    }

    private func parseArgs() -> ArgResult {
        var separator = "\n"
        var equalWidth = false
        var positional: [String] = []

        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { positional.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-s" || arg == "--separator" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("seq: option requires an argument: \(arg)\n")
                    return .failure(ExitStatus(2))
                }
                separator = rawArgv[index + 1]
                index += 2; continue
            }
            // `-sCHAR(s)` combined.
            if arg.hasPrefix("-s"), arg.count > 2,
               !isNumericArg(arg) {
                separator = String(arg.dropFirst(2))
                index += 1; continue
            }
            if arg == "-w" || arg == "--equal-width" {
                equalWidth = true; index += 1; continue
            }
            if arg == "-f" || arg == "--format" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("seq: option requires an argument: \(arg)\n")
                    return .failure(ExitStatus(2))
                }
                // We support the simplest case: pass-through the format
                // and use it via String(format:). Bash's seq accepts
                // anything printf accepts.
                _ = rawArgv[index + 1] // currently unused — emit unformatted
                index += 2; continue
            }
            // `-NUM` and bare numbers are positional.
            positional.append(arg); index += 1
        }
        return .success(ParsedArgs(separator: separator, equalWidth: equalWidth, positional: positional))
    }

    private func format(_ num: Double) -> String {
        if num == num.rounded(), abs(num) < 1e15 {
            return String(Int64(num))
        }
        return String(num)
    }

    private func isNumericArg(_ arg: String) -> Bool {
        // True for `-3`, `-3.5`, `+1`, `2` — used to disambiguate
        // `-3` (a negative LAST) from `-3...something` (an option).
        let body = arg.hasPrefix("-") || arg.hasPrefix("+")
            ? String(arg.dropFirst()) : arg
        return Double(body) != nil
    }

    private func widthIgnoringSign(_ str: String) -> Int {
        str.first == "-" ? str.count - 1 : str.count
    }

    private func padLeftZeros(_ str: String, toWidth width: Int) -> String {
        let body = str.first == "-" ? String(str.dropFirst()) : str
        let pad = max(0, width - body.count)
        let zeros = String(repeating: "0", count: pad)
        return (str.first == "-" ? "-" : "") + zeros + body
    }
}
