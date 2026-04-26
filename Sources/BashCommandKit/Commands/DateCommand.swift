import ArgumentParser
import BashInterpreter
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `date [-u] [+FORMAT]` — print the current date and time.
///
/// Accepts both the conventional `+FORMAT` positional (BSD/GNU `date`)
/// and `-f FMT` / `--format FMT` for symmetry with the rest of the
/// suite. Format strings follow `strftime(3)` (so `%Y`, `%m`, `%d`,
/// `%H:%M:%S`, `%Z`, `%s`, `%%`, `+%Y-%m-%dT%H:%M:%SZ`, …).
public struct DateCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "date",
        abstract: "Print the current date and time."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then optional `+FORMAT`.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var format = "%a %b %e %H:%M:%S %Z %Y"
        var utc = false

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                if i < rawArgv.count, rawArgv[i].hasPrefix("+") {
                    format = String(rawArgv[i].dropFirst())
                }
                break
            }
            if a == "-h" || a == "--help" {
                Shell.current.stdout("""
                    USAGE: date [-u] [-f FMT | --format FMT] [+FORMAT]

                    Print the current date and time. Format strings follow
                    strftime(3) — `%Y-%m-%d`, `%H:%M:%S`, `%Z`, `%s`, `%%`, …

                    OPTIONS:
                      -u, --utc      Use UTC instead of local time.
                      -f, --format   Format string in strftime(3) syntax.
                          --help     Show help information.

                    """)
                return .success
            }
            if a == "-u" || a == "--utc" || a == "--universal" {
                utc = true; i += 1; continue
            }
            if a == "-f" || a == "--format" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("date: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                format = rawArgv[i + 1]
                i += 2; continue
            }
            if a.hasPrefix("+") {
                format = String(a.dropFirst())
                i += 1; continue
            }
            // Unknown option / extra positional. Real `date` accepts
            // `-r SECONDS` and `-d STRING` but those are out of scope.
            Shell.current.stderr("date: unknown argument: \(a)\n")
            return ExitStatus(2)
        }

        var epoch = time_t(Date().timeIntervalSince1970)
        var broken = tm()
        if utc {
            _ = gmtime_r(&epoch, &broken)
        } else {
            _ = localtime_r(&epoch, &broken)
        }

        var buffer = [CChar](repeating: 0, count: 4096)
        _ = strftime(&buffer, buffer.count, format, &broken)
        Shell.current.stdout(String(cString: buffer) + "\n")
        return .success
    }
}
