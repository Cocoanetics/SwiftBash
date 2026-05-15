import ArgumentParser
import BashInterpreter
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
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

    // swiftlint:disable:next function_body_length - argv parsing plus libc broken-down-time emission
    public mutating func execute() async throws -> ExitStatus {
        var format = "%a %b %e %H:%M:%S %Z %Y"
        var utc = false

        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                if idx < rawArgv.count, rawArgv[idx].hasPrefix("+") {
                    format = String(rawArgv[idx].dropFirst())
                }
                break
            }
            if arg == "-h" || arg == "--help" {
                Shell.bashCurrent.stdout("""
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
            if arg == "-u" || arg == "--utc" || arg == "--universal" {
                utc = true; idx += 1; continue
            }
            if arg == "-f" || arg == "--format" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("date: option requires an argument: \(arg)\n")
                    return ExitStatus(2)
                }
                format = rawArgv[idx + 1]
                idx += 2; continue
            }
            if arg.hasPrefix("+") {
                format = String(arg.dropFirst())
                idx += 1; continue
            }
            // Unknown option / extra positional. Real `date` accepts
            // `-r SECONDS` and `-d STRING` but those are out of scope.
            Shell.bashCurrent.stderr("date: unknown argument: \(arg)\n")
            return ExitStatus(2)
        }

        var epoch = time_t(Date().timeIntervalSince1970)
        var broken = tm()
        #if os(Windows)
        if utc {
            _ = gmtime_s(&broken, &epoch)
        } else {
            _ = localtime_s(&broken, &epoch)
        }
        #else
        if utc {
            _ = gmtime_r(&epoch, &broken)
        } else {
            _ = localtime_r(&epoch, &broken)
        }
        #endif

        // Resolve the conversion specifiers libc handles inconsistently
        // (`%s` and `%Z`) before calling strftime, so the output is
        // identical on macOS / Linux / Windows.
        let resolved = Self.preprocessFormat(format, epoch: epoch, utc: utc)
        var buffer = [CChar](repeating: 0, count: 4096)
        let written = strftime(&buffer, buffer.count, resolved, &broken)
        // Truncate to the actual byte count strftime produced and
        // decode as UTF-8 (the deprecated `String(cString: array)`
        // variant scans for NUL itself).
        let bytes = (0..<written).map { UInt8(bitPattern: buffer[$0]) }
        // swiftlint:disable:next optional_data_string_conversion - strftime output may include locale bytes
        Shell.bashCurrent.stdout(String(decoding: bytes, as: UTF8.self) + "\n")
        return .success
    }

    /// Pre-substitute `%s` (Unix epoch — ucrt doesn't recognise it,
    /// crashes via the invalid-parameter handler) and `%Z` (timezone
    /// abbreviation — ucrt returns the verbose Windows form like
    /// "Coordinated Universal Time" instead of glibc's "UTC"/"GMT"/"PST")
    /// with literal text before handing the string to `strftime`. Other
    /// specifiers and `%%` pass through untouched.
    static func preprocessFormat(_ format: String,
                                 epoch: time_t,
                                 utc: Bool) -> String {
        let timeZone: String
        if utc {
            timeZone = "UTC"
        } else {
            timeZone = TimeZone.current.abbreviation() ?? ""
        }
        var out = ""
        out.reserveCapacity(format.count)
        var idx = format.startIndex
        while idx < format.endIndex {
            let char = format[idx]
            if char != "%" {
                out.append(char)
                idx = format.index(after: idx)
                continue
            }
            let next = format.index(after: idx)
            guard next < format.endIndex else {
                // Trailing lone `%` — leave for strftime to handle.
                out.append(char)
                idx = next
                continue
            }
            let nextChar = format[next]
            switch nextChar {
            case "%":
                out.append("%%")
            case "s":
                out.append("\(epoch)")
            case "Z":
                // Escape any `%` in the abbreviation so strftime treats
                // it literally.
                out.append(timeZone.replacingOccurrences(of: "%", with: "%%"))
            default:
                out.append(char)
                out.append(nextChar)
            }
            idx = format.index(after: next)
        }
        return out
    }
}
