import Foundation

/// `mapfile [-t] [-n COUNT] [-s SKIP] [-O ORIGIN] [ARRAY]` — read
/// stdin lines into an indexed array. Also exposed as `readarray`,
/// the synonym bash provides.
///
/// Default ARRAY is `MAPFILE`.
///
/// Supported options:
/// - `-t` strip the trailing newline from each line.
/// - `-n COUNT` read at most COUNT lines (0 = all).
/// - `-s SKIP` discard the first SKIP lines.
/// - `-O ORIGIN` start writing at index ORIGIN (default 0).
///
/// Lines are read from `Shell.bashCurrent.stdin`; the typical idiom
/// `mapfile arr < file` re-binds stdin first via redirection.
public struct MapfileCommand: Command {
    public let name: String
    public init(name: String = "mapfile") { self.name = name }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func run(_ argv: [String]) async throws -> ExitStatus {
        var stripNewline = false
        var maxCount = 0
        var skip = 0
        var origin = 0
        var arrayName = "MAPFILE"

        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { index += 1; break }
            if arg == "-t" { stripNewline = true; index += 1; continue }
            if arg == "-n" || arg == "-c" {
                guard index + 1 < argv.count, let value = Int(argv[index + 1]) else {
                    Shell.bashCurrent.stderr("\(name): option requires a numeric argument: \(arg)\n")
                    return ExitStatus(2)
                }
                maxCount = value; index += 2; continue
            }
            if arg == "-s" {
                guard index + 1 < argv.count, let value = Int(argv[index + 1]) else {
                    Shell.bashCurrent.stderr("\(name): option requires a numeric argument: \(arg)\n")
                    return ExitStatus(2)
                }
                skip = value; index += 2; continue
            }
            if arg == "-O" {
                guard index + 1 < argv.count, let value = Int(argv[index + 1]) else {
                    Shell.bashCurrent.stderr("\(name): option requires a numeric argument: \(arg)\n")
                    return ExitStatus(2)
                }
                origin = value; index += 2; continue
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                Shell.bashCurrent.stderr("\(name): invalid option: \(arg)\n")
                return ExitStatus(2)
            }
            arrayName = arg; index += 1
        }
        if index < argv.count { arrayName = argv[index] }

        // Drain the entire stream into one buffer first so we can split
        // it by newline. mapfile is a "consume all of stdin" operation.
        let data = await Shell.bashCurrent.stdin.readAllData()
        // swiftlint:disable:next optional_data_string_conversion - mapfile may receive partial UTF-8
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
        // Trailing empty after last `\n` — drop, the way bash does.
        if text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }

        // Apply skip / count.
        if skip > 0 { lines = Array(lines.dropFirst(skip)) }
        if maxCount > 0 { lines = Array(lines.prefix(maxCount)) }

        var array = BashArray()
        for (idx, line) in lines.enumerated() {
            let value = stripNewline ? line : line + "\n"
            array[origin + idx] = value
        }
        Shell.bashCurrent.environment.arrays[arrayName] = array
        Shell.bashCurrent.environment.variables.removeValue(forKey: arrayName)
        return .success
    }
}
