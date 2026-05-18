import Foundation

/// `compgen [option]... [word]` — generate possible completion
/// matches for `word`.
///
/// The builtin is a thin argument-parser on top of
/// ``CompletionSources``: action flags choose which catalog to
/// enumerate (`-c` commands, `-d` directories, `-f` files, `-v`
/// variables, …), modifier flags filter and transform the result
/// (`-W` word list, `-X` exclude pattern, `-P` prefix, `-S` suffix).
///
/// Exit status: `0` when at least one candidate was printed, `1`
/// when no candidates matched, `2` on a usage error. This matches
/// real bash, including the "no matches = non-zero" convention that
/// dotfile completion scripts rely on (`compgen … || return`).
///
/// Not implemented (silently treated as no-op / empty):
/// - `-F function` / `-C command` — invoking a completion function
///   to populate `COMPREPLY`. Will land alongside `complete -F`.
/// - `-G globpat` — pathname-glob action.
/// - `-o option` — compopt-style options. Accepted and ignored so
///   `compgen -o nospace …` from a dotfile doesn't error.
public struct CompgenCommand: Command {
    public let name = "compgen"
    public init() {}

    // Reserved words for `-k` / `-A keyword`. Bash lists shell
    // grammar tokens; we expose the ones SwiftBash actually parses.
    private static let reservedWords: [String] = [
        "!", "[[", "]]", "{", "}",
        "case", "do", "done", "elif", "else", "esac", "fi",
        "for", "function", "if", "in", "select", "then",
        "time", "until", "while"
    ]

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var options = ParsedOptions()
        switch parse(argv, into: &options) {
        case .success: break
        case .failure(let status): return status
        }

        let shell = Shell.bashCurrent
        var candidates = await gather(options: options, shell: shell)

        if let raw = options.wordList {
            candidates.append(contentsOf: splitWordList(raw))
        }

        let word = options.word ?? ""
        if !word.isEmpty {
            // Path-completion actions already filtered by basename;
            // for non-path candidates apply the prefix filter here.
            candidates = candidates.filter { $0.hasPrefix(word) }
        }

        if let pattern = options.excludePattern, !pattern.isEmpty {
            candidates = candidates.filter { !fnmatch(pattern, $0) }
        }

        if let prefix = options.prefix, !prefix.isEmpty {
            candidates = candidates.map { prefix + $0 }
        }
        if let suffix = options.suffix, !suffix.isEmpty {
            candidates = candidates.map { $0 + suffix }
        }

        if candidates.isEmpty {
            // Real bash returns 1 only when an action / wordlist was
            // specified and produced no matches. A bare `compgen` (no
            // generating options) is a no-op that succeeds — scripts
            // sometimes use it as a probe, so don't fail them.
            let hadGenerator = !options.actions.isEmpty
                || options.wordList != nil
            return hadGenerator ? ExitStatus(1) : .success
        }
        for candidate in candidates {
            shell.stdout("\(candidate)\n")
        }
        return .success
    }
}

// MARK: - Argument parsing

extension CompgenCommand {

    struct ParsedOptions {
        var actions: Set<Action> = []
        var wordList: String?
        var excludePattern: String?
        var prefix: String?
        var suffix: String?
        var word: String?
    }

    enum Action: Hashable {
        case alias, builtin, command, directory, exported, file,
             group, job, keyword, service, user, variable, function
    }

    enum ParseResult {
        case success
        case failure(ExitStatus)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func parse(_ argv: [String], into options: inout ParsedOptions) -> ParseResult {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                index += 1
                break
            }
            guard arg.hasPrefix("-"), arg.count > 1 else { break }

            switch arg {
            case "-a": options.actions.insert(.alias)
            case "-b": options.actions.insert(.builtin)
            case "-c": options.actions.insert(.command)
            case "-d": options.actions.insert(.directory)
            case "-e": options.actions.insert(.exported)
            case "-f": options.actions.insert(.file)
            case "-g": options.actions.insert(.group)
            case "-j": options.actions.insert(.job)
            case "-k": options.actions.insert(.keyword)
            case "-s": options.actions.insert(.service)
            case "-u": options.actions.insert(.user)
            case "-v": options.actions.insert(.variable)
            case "-A":
                index += 1
                guard index < argv.count,
                      let action = Self.action(forName: argv[index]) else {
                    Shell.bashCurrent.stderr("compgen: -A: invalid action name\n")
                    return .failure(ExitStatus(2))
                }
                options.actions.insert(action)
            case "-W":
                index += 1
                guard index < argv.count else {
                    Shell.bashCurrent.stderr("compgen: -W: option requires an argument\n")
                    return .failure(ExitStatus(2))
                }
                options.wordList = argv[index]
            case "-X":
                index += 1
                guard index < argv.count else {
                    Shell.bashCurrent.stderr("compgen: -X: option requires an argument\n")
                    return .failure(ExitStatus(2))
                }
                options.excludePattern = argv[index]
            case "-P":
                index += 1
                guard index < argv.count else {
                    Shell.bashCurrent.stderr("compgen: -P: option requires an argument\n")
                    return .failure(ExitStatus(2))
                }
                options.prefix = argv[index]
            case "-S":
                index += 1
                guard index < argv.count else {
                    Shell.bashCurrent.stderr("compgen: -S: option requires an argument\n")
                    return .failure(ExitStatus(2))
                }
                options.suffix = argv[index]
            case "-o", "-F", "-C", "-G":
                // Accepted-and-ignored: -o is compopt fluff, -F/-C/-G
                // need the `complete` registry that hasn't landed yet.
                // Still bash-strict about argument presence — these
                // flags require a value, and dotfile completion code
                // distinguishes usage-error status 2 from "no matches".
                index += 1
                guard index < argv.count else {
                    Shell.bashCurrent.stderr(
                        "compgen: \(arg): option requires an argument\n")
                    return .failure(ExitStatus(2))
                }
            default:
                Shell.bashCurrent.stderr("compgen: \(arg): invalid option\n")
                return .failure(ExitStatus(2))
            }
            index += 1
        }
        if index < argv.count {
            options.word = argv[index]
        }
        return .success
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func action(forName name: String) -> Action? {
        switch name {
        case "alias":     return .alias
        case "builtin":   return .builtin
        case "command":   return .command
        case "directory": return .directory
        case "export", "exported": return .exported
        case "file":      return .file
        case "function":  return .function
        case "group":     return .group
        case "job":       return .job
        case "keyword":   return .keyword
        case "service":   return .service
        case "user":      return .user
        case "variable":  return .variable
        default: return nil
        }
    }
}

// MARK: - Candidate gathering

extension CompgenCommand {

    // swiftlint:disable:next cyclomatic_complexity
    fileprivate func gather(options: ParsedOptions, shell: Shell) async -> [String] {
        let sources = shell.completionSources
        var out: [String] = []
        let word = options.word ?? ""

        // Stable iteration order so output is deterministic when
        // multiple actions are combined.
        let ordered = options.actions.sorted {
            String(describing: $0) < String(describing: $1)
        }
        for action in ordered {
            switch action {
            case .alias:
                out.append(contentsOf: sources.listAliases())
            case .builtin:
                out.append(contentsOf: sources.listCommands(kind: .builtin))
            case .command:
                out.append(contentsOf: sources.listCommands(kind: .all))
            case .function:
                out.append(contentsOf: sources.listCommands(kind: .function))
            case .keyword:
                out.append(contentsOf: Self.reservedWords)
            case .variable:
                out.append(contentsOf: sources.listVariables(scope: .all))
            case .exported:
                out.append(contentsOf: sources.listVariables(scope: .scalar))
            case .user:
                out.append(shell.hostInfo.userName)
            case .directory:
                out.append(contentsOf: await pathMatches(
                    prefix: word, shell: shell, directoriesOnly: true))
            case .file:
                out.append(contentsOf: await pathMatches(
                    prefix: word, shell: shell, directoriesOnly: false))
            case .group, .job, .service:
                break
            }
        }
        return out
    }

    /// Filesystem-backed completion for `-d` / `-f`.
    ///
    /// Splits `prefix` into (directory, basename) like real bash does:
    /// `/usr/lo` → list `/usr/`, filter entries starting with `lo`,
    /// then prepend `/usr/` so callers see `/usr/local` rather than
    /// just `local`. A bare prefix without a slash lists the shell's
    /// working directory.
    private func pathMatches(prefix: String, shell: Shell,
                             directoriesOnly: Bool) async -> [String] {
        let dirPart: String
        let basePart: String
        if let slash = prefix.lastIndex(of: "/") {
            let after = prefix.index(after: slash)
            dirPart = String(prefix[...slash])
            basePart = String(prefix[after...])
        } else {
            dirPart = ""
            basePart = prefix
        }

        let listing = await shell.completionSources.listDirectory(
            dirPart.isEmpty ? "." : dirPart)
        var hits: [String] = []
        for entry in listing {
            if directoriesOnly && entry.metadata.kind != .directory { continue }
            if !basePart.isEmpty && !entry.name.hasPrefix(basePart) { continue }
            hits.append(dirPart + entry.name)
        }
        return hits.sorted()
    }
}

// MARK: - Helpers

extension CompgenCommand {

    /// Tokenize a `-W` word list the way bash does: whitespace-
    /// separated, with single quotes preserving literal contents,
    /// double quotes preserving contents (minus escape processing),
    /// and `\` escaping the next character outside quotes. Outer
    /// quotes have already been stripped by the shell parser before
    /// argv hits us, so what we receive here is the inner list — the
    /// quoting we still see is intentional.
    fileprivate func splitWordList(_ raw: String) -> [String] { // swiftlint:disable:this cyclomatic_complexity
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var hasToken = false

        var iter = raw.makeIterator()
        while let char = iter.next() {
            if inSingle {
                if char == "'" { inSingle = false } else { current.append(char) }
                continue
            }
            if inDouble {
                if char == "\"" {
                    inDouble = false
                } else if char == "\\" {
                    if let next = iter.next() {
                        // In bash, only $`"\\ and newline are special
                        // after backslash inside double quotes; keep
                        // it simple — pass the next char through.
                        current.append(next)
                    }
                } else {
                    current.append(char)
                }
                continue
            }
            switch char {
            case " ", "\t", "\n":
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            case "'":
                inSingle = true
                hasToken = true
            case "\"":
                inDouble = true
                hasToken = true
            case "\\":
                if let next = iter.next() { current.append(next) }
                hasToken = true
            default:
                current.append(char)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Minimal fnmatch for `-X` patterns — supports `*` and `?`,
    /// anchored to the whole word (bash anchors `-X` patterns to the
    /// full candidate). A leading `!` inverts the match, matching
    /// bash's `-X '!*.o'` "keep only `*.o`" idiom.
    fileprivate func fnmatch(_ pattern: String, _ value: String) -> Bool {
        if pattern.hasPrefix("!") {
            return !globMatch(Array(pattern.dropFirst()), 0, Array(value), 0)
        }
        return globMatch(Array(pattern), 0, Array(value), 0)
    }

    private func globMatch(_ pat: [Character], _ patIdx: Int,
                           _ val: [Character], _ valIdx: Int) -> Bool {
        if patIdx == pat.count { return valIdx == val.count }
        let pchar = pat[patIdx]
        if pchar == "*" {
            if patIdx + 1 == pat.count { return true }
            for split in valIdx...val.count
                where globMatch(pat, patIdx + 1, val, split) {
                return true
            }
            return false
        }
        if valIdx == val.count { return false }
        if pchar == "?" || pchar == val[valIdx] {
            return globMatch(pat, patIdx + 1, val, valIdx + 1)
        }
        return false
    }
}

// `-W "list"` filter coexists with the `word` trailing prefix in
// real bash: the wordlist is split, then the prefix filter applies
// to all candidates (including those from -W). The `run` method
// above implements that order — gather first, append -W, prefix
// filter, exclude, then prefix/suffix wrap.
