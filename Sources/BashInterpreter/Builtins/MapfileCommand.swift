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
/// Lines are read from `Shell.current.stdin`; the typical idiom
/// `mapfile arr < file` re-binds stdin first via redirection.
public struct MapfileCommand: Command {
    public let name: String
    public init(name: String = "mapfile") { self.name = name }

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var stripNewline = false
        var maxCount = 0
        var skip = 0
        var origin = 0
        var arrayName = "MAPFILE"

        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" { i += 1; break }
            if a == "-t" { stripNewline = true; i += 1; continue }
            if a == "-n" || a == "-c" {
                guard i + 1 < argv.count, let n = Int(argv[i + 1]) else {
                    Shell.current.stderr("\(name): option requires a numeric argument: \(a)\n")
                    return ExitStatus(2)
                }
                maxCount = n; i += 2; continue
            }
            if a == "-s" {
                guard i + 1 < argv.count, let n = Int(argv[i + 1]) else {
                    Shell.current.stderr("\(name): option requires a numeric argument: \(a)\n")
                    return ExitStatus(2)
                }
                skip = n; i += 2; continue
            }
            if a == "-O" {
                guard i + 1 < argv.count, let n = Int(argv[i + 1]) else {
                    Shell.current.stderr("\(name): option requires a numeric argument: \(a)\n")
                    return ExitStatus(2)
                }
                origin = n; i += 2; continue
            }
            if a.hasPrefix("-"), a.count > 1 {
                Shell.current.stderr("\(name): invalid option: \(a)\n")
                return ExitStatus(2)
            }
            arrayName = a; i += 1
        }
        if i < argv.count { arrayName = argv[i] }

        // Drain the entire stream into one buffer first so we can split
        // it by newline. mapfile is a "consume all of stdin" operation.
        let data = await Shell.current.stdin.readAllData()
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
        Shell.current.environment.arrays[arrayName] = array
        Shell.current.environment.variables.removeValue(forKey: arrayName)
        return .success
    }
}
