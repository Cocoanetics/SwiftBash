import ArgumentParser
import BashInterpreter
import Foundation

/// `rg [OPTIONS] PATTERN [PATH...]` — pragmatic ripgrep subset.
///
/// Defaults that differ from `grep`:
/// - Recursive by default; `PATH` defaults to `.`.
/// - Skips dotfiles / dot-directories unless `--hidden` is set.
/// - Pattern is always interpreted as an ERE regex (no substring fallback).
/// - Filename is always shown in output.
///
/// Streams line-by-line so `tail -f log | rg ERROR` works.
///
/// ### Output / matching flags
/// - `-i` / `--ignore-case`
/// - `-S` / `--smart-case` — case-insensitive only when the pattern has
///   no uppercase letters
/// - `-n` / `--line-number` — prefix line numbers
/// - `-l` / `--files-with-matches` — print only the matching file names
/// - `-q` / `--quiet` — no output; exit 0 on first match, 1 otherwise
/// - `-m NUM` / `--max-count NUM` — stop after N matches per file
///
/// ### Context
/// - `-A NUM` / `--after-context`
/// - `-B NUM` / `--before-context`
/// - `-C NUM` / `--context`
///
/// ### File selection
/// - `-g GLOB` / `--glob GLOB` — include only matching basenames; prefix
///   with `!` to exclude (repeatable)
/// - `--hidden` — also descend into / read hidden files
/// - `--files` — print the list of candidate files; do not search them.
///   `PATTERN` becomes optional in this mode.
///
/// ### Out of scope
/// `--type LANG` (and shorthand `--swift`/etc.) — no language→glob
/// table; pass `-g '*.swift'` instead. `.gitignore` honoring. `-F`
/// fixed-string mode. `--type-add`.
public struct RgCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rg",
        abstract: "Recursive regex line search (ripgrep subset)."
    )

    @Argument(help: "Pattern (required unless --files), then paths.")
    public var positionals: [String] = []

    @Flag(name: [.customShort("i"), .customLong("ignore-case")],
          help: "Case-insensitive matching.")
    public var ignoreCase: Bool = false

    @Flag(name: [.customShort("S"), .customLong("smart-case")],
          help: "Case-insensitive only when PATTERN has no uppercase.")
    public var smartCase: Bool = false

    @Flag(name: [.customShort("n"), .customLong("line-number")],
          help: "Prefix each output line with its line number.")
    public var lineNumber: Bool = false

    @Flag(name: [.customShort("l"), .customLong("files-with-matches")],
          help: "Print only filenames that have at least one match.")
    public var filesWithMatches: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress output; exit 0 on the first match.")
    public var quiet: Bool = false

    @Option(name: [.customShort("m"), .customLong("max-count")],
            help: "Stop after NUM matches per file.")
    public var maxCount: Int?

    @Option(name: [.customShort("A"), .customLong("after-context")],
            help: "Print N lines after each match.")
    public var afterContext: Int = 0

    @Option(name: [.customShort("B"), .customLong("before-context")],
            help: "Print N lines before each match.")
    public var beforeContext: Int = 0

    @Option(name: [.customShort("C"), .customLong("context")],
            help: "Print N lines of context around each match.")
    public var context: Int = 0

    @Option(name: [.customShort("g"), .customLong("glob")],
            parsing: .singleValue,
            help: "Glob filter; prefix `!` to exclude (repeatable).")
    public var globs: [String] = []

    @Flag(name: .customLong("hidden"),
          help: "Don't skip files / directories whose name starts with `.`.")
    public var hidden: Bool = false

    @Flag(name: .customLong("files"),
          help: "List candidate files; do not search.")
    public var listFiles: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let pattern: String?
        let paths: [String]
        if listFiles {
            pattern = nil
            paths = positionals.isEmpty ? ["."] : positionals
        } else {
            guard let p = positionals.first else {
                shell.stderr("rg: missing PATTERN\n")
                return ExitStatus(2)
            }
            pattern = p
            let rest = Array(positionals.dropFirst())
            paths = rest.isEmpty ? ["."] : rest
        }

        let parsedGlobs = globs.map(GlobRule.init(raw:))

        // --files mode: walk and print, no matching.
        if listFiles {
            for path in paths {
                let abs = shell.resolvePath(path)
                await listOne(displayPath: path,
                              absolutePath: abs,
                              globs: parsedGlobs,
                              shell: shell)
            }
            return .success
        }

        // Smart-case: only down-case when there's no uppercase.
        let effIgnore = ignoreCase
            || (smartCase
                && !(pattern!.contains(where: {
                    $0.isLetter && $0.isUppercase
                })))

        let matcher: LineMatcher
        do {
            matcher = try LineMatcher(pattern: pattern!,
                                      ignoreCase: effIgnore)
        } catch {
            shell.stderr("rg: \(pattern!): \(error)\n")
            return ExitStatus(2)
        }

        let after = max(afterContext, context)
        let before = max(beforeContext, context)
        let opts = OutputOptions(
            lineNumber: lineNumber,
            filesWithMatches: filesWithMatches,
            quiet: quiet,
            maxCount: maxCount ?? Int.max,
            after: after,
            before: before)

        var anyMatched = false
        for path in paths {
            let abs = shell.resolvePath(path)
            let r = await searchPath(displayPath: path,
                                     absolutePath: abs,
                                     globs: parsedGlobs,
                                     matcher: matcher,
                                     opts: opts,
                                     shell: shell)
            if r { anyMatched = true }
            if quiet, anyMatched { break }
        }
        return anyMatched ? .success : .failure
    }

    // MARK: --files mode

    private func listOne(displayPath: String,
                         absolutePath: String,
                         globs: [GlobRule],
                         shell: Shell) async {
        let meta = try? await shell.metadataAtPath(displayPath)
        guard let meta else {
            shell.stderr("rg: \(displayPath): No such file or directory\n")
            return
        }
        if meta.kind == .directory {
            await walk(displayPath: displayPath,
                       absolutePath: absolutePath,
                       globs: globs,
                       shell: shell) { dp, _ in
                shell.stdout(dp + "\n")
                return true
            }
        } else {
            let name = (displayPath as NSString).lastPathComponent
            if Self.passesGlobs(name: name, rules: globs) {
                shell.stdout(displayPath + "\n")
            }
        }
    }

    // MARK: Search dispatch

    private func searchPath(displayPath: String,
                            absolutePath: String,
                            globs: [GlobRule],
                            matcher: LineMatcher,
                            opts: OutputOptions,
                            shell: Shell) async -> Bool {
        let meta = try? await shell.metadataAtPath(displayPath)
        guard let meta else {
            shell.stderr("rg: \(displayPath): No such file or directory\n")
            return false
        }
        if meta.kind == .directory {
            var any = false
            await walk(displayPath: displayPath,
                       absolutePath: absolutePath,
                       globs: globs,
                       shell: shell) { dp, abs in
                let r = await searchFile(displayPath: dp,
                                         absolutePath: abs,
                                         matcher: matcher,
                                         opts: opts,
                                         shell: shell)
                if r { any = true }
                return !(opts.quiet && any)
            }
            return any
        }
        return await searchFile(displayPath: displayPath,
                                absolutePath: absolutePath,
                                matcher: matcher,
                                opts: opts,
                                shell: shell)
    }

    /// Recursively visit every file under `absolutePath`, sorted, calling
    /// `visit` for each. Honors `--hidden` (default: skip dot entries)
    /// and `globs`. Returns once `visit` returns false.
    private func walk(displayPath: String,
                      absolutePath: String,
                      globs: [GlobRule],
                      shell: Shell,
                      visit: (String, String) async -> Bool) async {
        let entries: [String]
        do {
            entries = try await shell.fileSystem.list(absolutePath)
        } catch {
            shell.stderr("rg: \(displayPath): \(error)\n")
            return
        }
        for name in entries.sorted() {
            if !hidden, name.hasPrefix(".") { continue }
            let childAbs = (absolutePath as NSString)
                .appendingPathComponent(name)
            let childDisplay = (displayPath as NSString)
                .appendingPathComponent(name)
            let meta = try? await shell.fileSystem.metadata(childAbs)
            guard let meta else { continue }
            if meta.kind == .directory {
                await walk(displayPath: childDisplay,
                           absolutePath: childAbs,
                           globs: globs,
                           shell: shell,
                           visit: visit)
            } else {
                if !Self.passesGlobs(name: name, rules: globs) { continue }
                if !(await visit(childDisplay, childAbs)) { return }
            }
        }
    }

    // MARK: Per-file search

    private struct OutputOptions {
        let lineNumber: Bool
        let filesWithMatches: Bool
        let quiet: Bool
        let maxCount: Int
        let after: Int
        let before: Int
    }

    private func searchFile(displayPath: String,
                            absolutePath: String,
                            matcher: LineMatcher,
                            opts: OutputOptions,
                            shell: Shell) async -> Bool {
        let input: InputSource
        do {
            input = try await shell.openInputPath(displayPath)
        } catch {
            shell.stderr("rg: \(displayPath): \(error)\n")
            return false
        }
        let needsContext = opts.before > 0 || opts.after > 0
        var beforeBuf = RingBuffer<(Int, String)>(capacity: opts.before)
        var afterRemaining = 0
        var lastEmitted = 0
        var matchCount = 0
        var lineNum = 0

        for await line in input.lines {
            lineNum += 1
            let isMatch = matcher.matches(line)
            if isMatch {
                matchCount += 1
                if opts.quiet { return true }
                if opts.filesWithMatches {
                    shell.stdout(displayPath + "\n")
                    return true
                }
                if needsContext, lastEmitted > 0,
                   lineNum - opts.before > lastEmitted + 1 {
                    shell.stdout("--\n")
                }
                for (bn, bl) in beforeBuf.elements where bn > lastEmitted {
                    emit(file: displayPath, lineNum: bn, line: bl,
                         isMatch: false, opts: opts, shell: shell)
                    lastEmitted = bn
                }
                emit(file: displayPath, lineNum: lineNum, line: line,
                     isMatch: true, opts: opts, shell: shell)
                lastEmitted = lineNum
                afterRemaining = opts.after
                if matchCount >= opts.maxCount { break }
            } else if afterRemaining > 0 {
                emit(file: displayPath, lineNum: lineNum, line: line,
                     isMatch: false, opts: opts, shell: shell)
                lastEmitted = lineNum
                afterRemaining -= 1
            }
            beforeBuf.push((lineNum, line))
        }
        return matchCount > 0
    }

    private func emit(file: String,
                      lineNum: Int,
                      line: String,
                      isMatch: Bool,
                      opts: OutputOptions,
                      shell: Shell) {
        let sep = isMatch ? ":" : "-"
        var out = file + sep
        if opts.lineNumber { out += "\(lineNum)\(sep)" }
        out += line + "\n"
        shell.stdout(out)
    }

    // MARK: Glob rules

    /// One `-g`/`--glob` value: either an inclusive pattern, or a
    /// negation (leading `!`).
    struct GlobRule: Sendable {
        let pattern: String
        let negated: Bool

        init(raw: String) {
            if raw.hasPrefix("!") {
                self.pattern = String(raw.dropFirst())
                self.negated = true
            } else {
                self.pattern = raw
                self.negated = false
            }
        }
    }

    /// Apply a list of glob rules to a basename. Semantics mirror
    /// ripgrep at a high level:
    /// - If there are *only* exclude rules, default is "include
    ///   everything not excluded".
    /// - If any include rules are present, the default flips to
    ///   "exclude everything not included" — but excludes still win.
    static func passesGlobs(name: String, rules: [GlobRule]) -> Bool {
        if rules.isEmpty { return true }
        let hasIncludes = rules.contains(where: { !$0.negated })
        var included = !hasIncludes ? true : false
        for r in rules {
            if Self.globMatch(pattern: r.pattern, string: name) {
                if r.negated { return false }
                included = true
            }
        }
        return included
    }

    // MARK: Match strategy
    //
    // rg patterns are always regex; substring mode would be `-F` which
    // we skip. NSRegex's syntax is close to PCRE / Rust regex for the
    // common subset (anchors, classes, alternation, quantifiers, groups).

    struct LineMatcher: Sendable {
        let regex: NSRegularExpression

        init(pattern: String, ignoreCase: Bool) throws {
            var opts: NSRegularExpression.Options = []
            if ignoreCase { opts.insert(.caseInsensitive) }
            self.regex = try NSRegularExpression(
                pattern: pattern, options: opts)
        }

        func matches(_ line: String) -> Bool {
            let r = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, options: [], range: r) != nil
        }
    }

    /// Mirrors `GrepCommand.RingBuffer`; small enough that duplicating
    /// it is cheaper than wiring up a shared module.
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

    // MARK: Glob matching
    //
    // Same fnmatch-style matcher used in `GrepCommand` and `FindCommand`.

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
