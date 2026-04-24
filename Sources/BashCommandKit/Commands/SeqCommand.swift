import ArgumentParser
import BashInterpreter

/// `seq [-s SEP] [LAST]`
/// `seq [-s SEP] FIRST LAST`
/// `seq [-s SEP] FIRST INCREMENT LAST`
///
/// Print a sequence of numbers from `FIRST` to `LAST` (inclusive) in
/// steps of `INCREMENT`. `FIRST` defaults to `1`, `INCREMENT` to `1`
/// (or `-1` if `FIRST > LAST`).
///
/// ```
/// seq 3        → 1 2 3
/// seq 2 5      → 2 3 4 5
/// seq 1 2 9    → 1 3 5 7 9
/// seq 5 -1 1   → 5 4 3 2 1
/// seq -s , 4   → 1,2,3,4
/// ```
public struct SeqCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "seq",
        abstract: "Print a sequence of numbers."
    )

    @Option(name: [.short, .long],
            help: ArgumentHelp("Separator between numbers.",
                               valueName: "sep"))
    public var separator: String = "\n"

    // `.captureForPassthrough` lets negative values like `-1` reach us as
    // positional arguments — without it, ArgumentParser rejects them as
    // unknown short options before our array ever sees them. We parse
    // each token into a Double ourselves.
    @Argument(parsing: .captureForPassthrough,
              help: "LAST, or FIRST LAST, or FIRST INCREMENT LAST.")
    public var rawArgs: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) throws -> ExitStatus {
        var parsed: [Double] = []
        parsed.reserveCapacity(rawArgs.count)
        for raw in rawArgs {
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
        shell.stdout(values.joined(separator: separator) + "\n")
        return .success
    }

    private func format(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }
}
