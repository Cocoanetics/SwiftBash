import ArgumentParser
import BashInterpreter
import Foundation

/// `grep [OPTIONS] PATTERN [FILE...]` — print lines matching PATTERN.
///
/// With no `FILE`, reads stdin. With multiple files (or `-r`), each
/// output line is prefixed with the file name. Streams line-by-line so
/// `tail -f log | grep ERROR` works without buffering.
///
/// ### Pattern flavours
/// - default: plain substring match
/// - `-E` / `--extended-regexp`: ERE via `NSRegularExpression`
///
/// ### Output / matching flags
/// - `-i` / `--ignore-case`
/// - `-v` / `--invert-match`
/// - `-n` / `--line-number` — prefix line numbers
/// - `-c` / `--count` — print the per-file match count
/// - `-l` / `--files-with-matches` — print matching file names only
/// - `-q` / `--quiet` — no output; exit 0 on first match, 1 otherwise
///
/// ### Context
/// - `-A NUM` / `--after-context` — N lines after each match
/// - `-B NUM` / `--before-context` — N lines before each match
/// - `-C NUM` / `--context` — shorthand for `-A NUM -B NUM`
///
/// ### Recursive search
/// - `-r` / `-R` / `--recursive` — descend into directory arguments
/// - `--include=GLOB` — only consider files whose basename matches
///   GLOB. Repeatable; without `--include` every file is searched.
public struct GrepCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "grep",
        abstract: "Print lines matching a pattern."
    )

    @Argument(help: "Pattern to match (substring, or ERE with -E).")
    public var pattern: String

    @Argument(help: "Files to search; reads stdin if empty.")
    public var files: [String] = []

    @Flag(name: [.customShort("v"), .customLong("invert-match")],
          help: "Print non-matching lines instead.")
    public var invert: Bool = false

    @Flag(name: [.customShort("i"), .customLong("ignore-case")],
          help: "Case-insensitive matching.")
    public var ignoreCase: Bool = false

    @Flag(name: [.customShort("E"), .customLong("extended-regexp")],
          help: "Interpret PATTERN as an extended regex.")
    public var extendedRegexp: Bool = false

    @Flag(name: [.customShort("n"), .customLong("line-number")],
          help: "Prefix each output line with its line number.")
    public var lineNumber: Bool = false

    @Flag(name: [.customShort("c"), .customLong("count")],
          help: "Print only a count of matching lines per file.")
    public var countOnly: Bool = false

    @Flag(name: [.customShort("l"), .customLong("files-with-matches")],
          help: "Print only names of files that have at least one match.")
    public var filesWithMatches: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress output; exit 0 on the first match.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("r"), .customShort("R"),
                 .customLong("recursive")],
          help: "Recurse into directory arguments.")
    public var recursive: Bool = false

    @Option(name: [.customShort("A"), .customLong("after-context")],
            help: "Print N lines after each match.")
    public var afterContext: Int = 0

    @Option(name: [.customShort("B"), .customLong("before-context")],
            help: "Print N lines before each match.")
    public var beforeContext: Int = 0

    @Option(name: [.customShort("C"), .customLong("context")],
            help: "Print N lines of context around each match.")
    public var context: Int = 0

    @Option(name: .customLong("include"), parsing: .singleValue,
            help: "Glob filter for filenames when recursing (repeatable).")
    public var include: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let matcher: LineMatcher
        do {
            matcher = try LineMatcher(pattern: pattern,
                                      extendedRegexp: extendedRegexp,
                                      ignoreCase: ignoreCase,
                                      invert: invert)
        } catch {
            Shell.bashCurrent.stderr("grep: \(pattern): \(error)\n")
            return ExitStatus(2)
        }

        // -C N is shorthand for -A N -B N (whichever wins).
        let after = max(afterContext, context)
        let before = max(beforeContext, context)

        // When are filenames printed? GNU rule: when there's more than
        // one input source, or `-r` is on, or `-H` is set (we don't
        // implement -H/-h yet).
        let inputs = await collectSources()
        let showName = recursive || inputs.count > 1
        let opts = OutputOptions(
            showName: showName,
            lineNumber: lineNumber,
            countOnly: countOnly,
            filesWithMatches: filesWithMatches,
            quiet: quiet,
            after: after,
            before: before)

        var anyMatched = false
        for input in inputs {
            let r = await searchOne(input: input,
                                    matcher: matcher,
                                    opts: opts)
            if r { anyMatched = true }
            if quiet, anyMatched { break }
        }
        return anyMatched ? .success : .failure
    }

    // MARK: Source collection

    private struct Source {
        var displayName: String
        var input: InputSource
    }

    /// Resolve `files` into a flat list of `Source`s, recursing into
    /// directories when `-r`. Errors are written to stderr inline as
    /// they're discovered; the returned bool tracks "did we hit any?"
    /// so the caller can pick the right exit code.
    private func collectSources() async -> [Source] {
        if files.isEmpty {
            return [Source(displayName: "(standard input)",
                           input: Shell.bashCurrent.stdin)]
        }

        var out: [Source] = []
        for file in files {
            let resolved = Shell.bashCurrent.resolvePath(file)
            let meta: FileMetadata?
            do {
                meta = try await Shell.bashCurrent.metadataAtPath(file)
            } catch {
                Shell.bashCurrent.stderr("grep: \(file): \(error)\n")
                continue
            }
            guard let meta else {
                Shell.bashCurrent.stderr("grep: \(file): No such file or directory\n")
                continue
            }
            if meta.kind == .directory {
                if !recursive {
                    Shell.bashCurrent.stderr("grep: \(file): Is a directory\n")
                    continue
                }
                let walked = await walkDirectory(displayPath: file,
                                                 absolutePath: resolved)
                out.append(contentsOf: walked)
            } else if let s = await openFile(displayPath: file,
                                             absolutePath: resolved) {
                out.append(s)
            }
        }
        return out
    }

    private func walkDirectory(displayPath: String,
                               absolutePath: String) async -> [Source]
    {
        var result: [Source] = []
        let entries: [String]
        do {
            entries = try await Shell.bashCurrent.fileSystem.list(absolutePath)
        } catch {
            Shell.bashCurrent.stderr("grep: \(displayPath): \(error)\n")
            return []
        }
        for name in entries.sorted() {
            let childAbs = (absolutePath as NSString)
                .appendingPathComponent(name)
            let childDisplay = (displayPath as NSString)
                .appendingPathComponent(name)
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(childAbs)
            guard let meta else { continue }
            if meta.kind == .directory {
                let nested = await walkDirectory(displayPath: childDisplay,
                                                 absolutePath: childAbs)
                result.append(contentsOf: nested)
            } else {
                if !include.isEmpty,
                   !include.contains(where: {
                       Self.globMatch(pattern: $0, string: name) })
                {
                    continue
                }
                if let s = await openFile(displayPath: childDisplay,
                                          absolutePath: childAbs) {
                    result.append(s)
                }
            }
        }
        return result
    }

    private func openFile(displayPath: String,
                          absolutePath: String) async -> Source?
    {
        do {
            let stream = try await Shell.bashCurrent.openInputPath(absolutePath)
            return Source(displayName: displayPath, input: stream)
        } catch {
            Shell.bashCurrent.stderr("grep: \(displayPath): \(error)\n")
            return nil
        }
    }

    // MARK: Per-source search

    private struct OutputOptions {
        let showName: Bool
        let lineNumber: Bool
        let countOnly: Bool
        let filesWithMatches: Bool
        let quiet: Bool
        let after: Int
        let before: Int
    }

    /// Run the matcher against one source, emitting output per `opts`.
    /// Returns true if at least one line matched.
    private func searchOne(input: Source,
                           matcher: LineMatcher,
                           opts: OutputOptions) async -> Bool
    {
        let needsContext = opts.before > 0 || opts.after > 0
        var beforeBuf = RingBuffer<(Int, String)>(capacity: opts.before)
        var afterRemaining = 0
        var lastEmittedLine = 0
        var matchCount = 0

        var lineNum = 0
        for await line in input.input.lines {
            lineNum += 1
            let isMatch = matcher.matches(line)

            if isMatch {
                matchCount += 1
                if opts.quiet { return true }
                if opts.filesWithMatches {
                    Shell.bashCurrent.stdout(input.displayName + "\n")
                    return true
                }
                if !opts.countOnly {
                    // Separator between non-contiguous context groups.
                    if needsContext, lastEmittedLine > 0,
                       lineNum - opts.before > lastEmittedLine + 1 {
                        Shell.bashCurrent.stdout("--\n")
                    }
                    // Flush before-context.
                    for (bn, bl) in beforeBuf.elements {
                        if bn > lastEmittedLine {
                            emit(file: input.displayName, lineNum: bn,
                                 line: bl, isMatch: false,
                                 opts: opts)
                            lastEmittedLine = bn
                        }
                    }
                    // Emit the matched line.
                    emit(file: input.displayName, lineNum: lineNum,
                         line: line, isMatch: true,
                         opts: opts)
                    lastEmittedLine = lineNum
                    afterRemaining = opts.after
                }
            } else if afterRemaining > 0 {
                if !opts.countOnly, !opts.filesWithMatches, !opts.quiet {
                    emit(file: input.displayName, lineNum: lineNum,
                         line: line, isMatch: false,
                         opts: opts)
                    lastEmittedLine = lineNum
                }
                afterRemaining -= 1
            }
            beforeBuf.push((lineNum, line))
        }

        // Trailing actions per file. Note: -l and -q exit early above
        // and never reach here.
        if opts.countOnly {
            // GNU prints `0` per file even with no matches.
            let n = matchCount
            if opts.showName {
                Shell.bashCurrent.stdout("\(input.displayName):\(n)\n")
            } else {
                Shell.bashCurrent.stdout("\(n)\n")
            }
        }
        return matchCount > 0
    }

    /// Render one output line. The "is the matched line" flag picks
    /// the right separator (`:` for matches, `-` for context lines —
    /// matches GNU grep's convention).
    private func emit(file: String,
                      lineNum: Int,
                      line: String,
                      isMatch: Bool,
                      opts: OutputOptions)
    {
        let sep = isMatch ? ":" : "-"
        var out = ""
        if opts.showName { out += file + sep }
        if opts.lineNumber { out += "\(lineNum)\(sep)" }
        out += line + "\n"
        Shell.bashCurrent.stdout(out)
    }

    // MARK: Match strategies

    /// Compiles the pattern once per command invocation and answers
    /// "does this line match?" for each input line.
    struct LineMatcher: Sendable {
        let invert: Bool
        let kind: Kind

        enum Kind: Sendable {
            case substring(needle: String, ignoreCase: Bool)
            case regex(NSRegularExpression)
        }

        init(pattern: String,
             extendedRegexp: Bool,
             ignoreCase: Bool,
             invert: Bool) throws
        {
            self.invert = invert
            if extendedRegexp {
                var opts: NSRegularExpression.Options = []
                if ignoreCase { opts.insert(.caseInsensitive) }
                self.kind = .regex(try NSRegularExpression(
                    pattern: pattern, options: opts))
            } else {
                self.kind = .substring(
                    needle: ignoreCase ? pattern.lowercased() : pattern,
                    ignoreCase: ignoreCase)
            }
        }

        func matches(_ line: String) -> Bool {
            let raw: Bool
            switch kind {
            case .substring(let needle, let ci):
                let h = ci ? line.lowercased() : line
                raw = h.contains(needle)
            case .regex(let re):
                let r = NSRange(line.startIndex..., in: line)
                raw = re.firstMatch(in: line, options: [], range: r) != nil
            }
            return invert ? !raw : raw
        }
    }

    // MARK: Helpers

    /// Fixed-capacity FIFO ring buffer used for `-B` before-context.
    /// Iterating `elements` walks oldest → newest.
    struct RingBuffer<T> {
        private var storage: [T] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            storage.reserveCapacity(max(capacity, 0))
        }

        mutating func push(_ element: T) {
            guard capacity > 0 else { return }
            if storage.count == capacity { storage.removeFirst() }
            storage.append(element)
        }

        var elements: [T] { storage }
    }

    // MARK: Glob matching for --include
    //
    // Same fnmatch-style matcher used elsewhere in BashCommandKit; the
    // public `BashInterpreter.GlobMatcher` is internal to that target.

    static func globMatch(pattern: String, string: String) -> Bool {
        let p = Array(pattern)
        let s = Array(string)
        return globMatch(p, 0, s, 0)
    }

    private static func globMatch(_ p: [Character], _ pi: Int,
                                  _ s: [Character], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        while pi < p.count {
            let c = p[pi]
            switch c {
            case "*":
                while pi < p.count, p[pi] == "*" { pi += 1 }
                if pi == p.count { return true }
                var k = si
                while k <= s.count {
                    if globMatch(p, pi, s, k) { return true }
                    k += 1
                }
                return false
            case "?":
                if si >= s.count { return false }
                pi += 1
                si += 1
            case "\\":
                guard pi + 1 < p.count, si < s.count,
                      p[pi + 1] == s[si]
                else { return false }
                pi += 2
                si += 1
            default:
                if si >= s.count || s[si] != c { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }
}
