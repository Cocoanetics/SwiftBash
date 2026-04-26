import Foundation

/// `trap` — register, inspect, or remove signal handlers.
///
/// Forms:
/// - `trap` (no args) — list installed handlers, one per line, in a
///   re-readable form.
/// - `trap -l` — list known signal names.
/// - `trap -p [SIG …]` — print specific (or all) handlers, re-readable.
/// - `trap COMMAND SIG …` — install `COMMAND` as the handler for each
///   `SIG`. Empty `COMMAND` (`trap '' SIG`) means "ignore". The literal
///   `-` resets the signal to its default.
///
/// Only the in-process pseudo-signals are actually wired into the
/// runtime: `EXIT`, `ERR`, `DEBUG`, `RETURN`. OS signals (`INT`,
/// `TERM`, etc.) can still be registered and printed but won't fire —
/// the embedded interpreter isn't a process group leader.
public struct TrapCommand: Command {
    public let name = "trap"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())

        if args.isEmpty {
            for sig in Shell.current.traps.keys.sorted() {
                Shell.current.stdout(formatTrap(sig: sig, body: Shell.current.traps[sig]!))
            }
            return .success
        }

        if args[0] == "-l" {
            Shell.current.stdout(knownSignals.joined(separator: " ") + "\n")
            return .success
        }

        if args[0] == "-p" {
            let names = Array(args.dropFirst())
            let toShow: [String] = names.isEmpty
                ? Array(Shell.current.traps.keys.sorted())
                : names.map(canonicalize)
            for sig in toShow {
                if let body = Shell.current.traps[sig] {
                    Shell.current.stdout(formatTrap(sig: sig, body: body))
                }
            }
            return .success
        }

        // `trap COMMAND SIG …`. The COMMAND can be:
        //   `-`  → reset to default (delete the trap)
        //   `''` → ignore (store empty string)
        //   any other text → command to run
        guard args.count >= 2 else {
            Shell.current.stderr("trap: usage: trap [-lp] [[arg] signal_spec ...]\n")
            return ExitStatus(2)
        }
        let command = args[0]
        let sigSpecs = Array(args.dropFirst())

        for raw in sigSpecs {
            let sig = canonicalize(raw)
            guard isValidSignal(sig) else {
                Shell.current.stderr("trap: \(raw): invalid signal specification\n")
                return ExitStatus(1)
            }
            if command == "-" {
                Shell.current.traps.removeValue(forKey: sig)
            } else {
                Shell.current.traps[sig] = command
            }
        }
        return .success
    }

    private func formatTrap(sig: String, body: String) -> String {
        // `trap -- 'body' SIG` is the canonical re-readable form.
        let escaped = body.replacingOccurrences(of: "'", with: #"'\''"#)
        return "trap -- '\(escaped)' \(sig)\n"
    }

    /// Map a user-typed signal name to canonical form. Accepts
    /// numeric `0` (= `EXIT`), `SIGINT` / `INT` style, and is
    /// case-insensitive.
    private func canonicalize(_ raw: String) -> String {
        if raw == "0" { return "EXIT" }
        let upper = raw.uppercased()
        if upper.hasPrefix("SIG") { return String(upper.dropFirst(3)) }
        return upper
    }

    private func isValidSignal(_ canonical: String) -> Bool {
        knownSignals.contains(canonical) || pseudoSignals.contains(canonical)
    }

    private let pseudoSignals: Set<String> = ["EXIT", "ERR", "DEBUG", "RETURN"]

    /// Subset of the POSIX signal set commonly used in scripts. Not
    /// exhaustive — the names are accepted by `trap` (so `kill -l`
    /// style scripts don't error) even though we can't deliver them.
    private let knownSignals: [String] = [
        "EXIT", "ERR", "DEBUG", "RETURN",
        "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE",
        "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM",
        "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG",
        "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS",
    ]
}
