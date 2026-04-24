import ArgumentParser
import BashInterpreter
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `date` — print the current date and time, with strftime-style
/// formatting via `-f` / `--format`.
///
/// ```swift
/// let shell = Shell()
/// shell.register(DateCommand.self)
///
/// try shell.run("date")                         // → Sun Apr 24 14:30:45 PDT 2026
/// try shell.run(#"date -f "%Y-%m-%d""#)         // → 2026-04-24
/// try shell.run(#"date -u -f "%Y-%m-%dT%H:%M:%SZ""#)
/// ```
///
/// The format string follows `strftime(3)` — the same syntax `/bin/date`
/// uses — so `%Y`, `%m`, `%d`, `%H`, `%M`, `%S`, `%Z`, `%s`, `%%`, and
/// the rest of the familiar specifiers all work.
public struct DateCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "date",
        abstract: "Print the current date and time."
    )

    @Option(name: [.short, .long],
            help: ArgumentHelp("Format string in strftime(3) syntax.",
                               valueName: "fmt"))
    public var format: String = "%a %b %e %H:%M:%S %Z %Y"

    @Flag(name: [.short, .long], help: "Use UTC instead of local time.")
    public var utc: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var epoch = time_t(Date().timeIntervalSince1970)
        var broken = tm()
        if utc {
            _ = gmtime_r(&epoch, &broken)
        } else {
            _ = localtime_r(&epoch, &broken)
        }

        // 4 KB is plenty for any reasonable strftime output — even the
        // longest localised format strings produce only a few hundred bytes.
        var buffer = [CChar](repeating: 0, count: 4096)
        _ = strftime(&buffer, buffer.count, format, &broken)
        shell.stdout(String(cString: buffer) + "\n")
        return .success
    }
}
