import Foundation

/// `read [-r] [-p PROMPT] [VAR ...]` — read one line from stdin into
/// the named shell variables. With multiple variables, the line is
/// split on `$IFS` and the *last* variable receives the trailing
/// remainder. With no variables, the line is stored in `REPLY`.
///
/// Returns `.success` on a normal read, `.failure` (1) at EOF.
///
/// Supported options:
/// - `-r` — raw mode; backslashes don't escape the next character.
///   Without `-r`, `\` followed by any char yields just that char,
///   and `\<newline>` is a line-continuation.
/// - `-p PROMPT` — print PROMPT to stderr before reading. Mostly
///   useful for interactive prompts; safe in scripts too.
///
/// Out of scope (for now): `-n NCHARS`, `-t TIMEOUT`, `-d DELIM`,
/// `-a ARRAY`, `-s` silent mode.
public struct ReadCommand: Command {
    public let name = "read"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var raw = false
        var prompt: String? = nil
        var arrayName: String? = nil
        var i = 1

        while i < argv.count {
            let arg = argv[i]
            if arg == "-r" {
                raw = true
                i += 1
            } else if arg == "-p" {
                guard i + 1 < argv.count else {
                    Shell.bashCurrent.stderr("read: -p: missing argument\n")
                    return ExitStatus(2)
                }
                prompt = argv[i + 1]
                i += 2
            } else if arg.hasPrefix("-p") {
                prompt = String(arg.dropFirst(2))
                i += 1
            } else if arg == "-a" {
                guard i + 1 < argv.count else {
                    Shell.bashCurrent.stderr("read: -a: missing array name\n")
                    return ExitStatus(2)
                }
                arrayName = argv[i + 1]
                i += 2
            } else if arg.hasPrefix("-a"), arg.count > 2 {
                arrayName = String(arg.dropFirst(2))
                i += 1
            } else if arg.hasPrefix("-") && arg != "-" {
                // Unknown flag; surface and stop option parsing.
                Shell.bashCurrent.stderr("read: \(arg): invalid option\n")
                return ExitStatus(2)
            } else {
                break
            }
        }

        if let prompt {
            Shell.bashCurrent.stderr(prompt)
        }

        guard let line = await readOneLine(raw: raw) else {
            return .failure
        }

        // `read -a NAME` overrides the variable list; bash splits the
        // line on $IFS into the array NAME and ignores extra positional
        // var names.
        if let arrayName {
            assignToArray(line, name: arrayName)
            return .success
        }

        let names = Array(argv[i...])
        if names.isEmpty {
            Shell.bashCurrent.environment["REPLY"] = line
            return .success
        }
        assignSplitFields(line, into: names)
        return .success
    }

    /// Split `line` on $IFS and store the fields in `name` as an
    /// indexed array, dense from index 0.
    private func assignToArray(_ line: String,
                               name: String)
    {
        let ifsChars: [Character] = {
            if let ifs = Shell.bashCurrent.environment["IFS"] { return Array(ifs) }
            return [" ", "\t", "\n"]
        }()
        let ifsSet = Set(ifsChars)
        let whitespace: Set<Character> = [" ", "\t", "\n"]
        let isIfsWhitespace = ifsChars.allSatisfy { whitespace.contains($0) }

        // For whitespace-only IFS, runs collapse and leading/trailing
        // whitespace is stripped (matches `read VAR1 VAR2 …`).
        var fields: [String] = []
        var current = ""
        var prevWasSep = isIfsWhitespace
        for c in line {
            if ifsSet.contains(c) {
                if isIfsWhitespace {
                    if !prevWasSep, !current.isEmpty {
                        fields.append(current); current = ""
                    }
                    prevWasSep = true
                } else {
                    fields.append(current); current = ""
                }
            } else {
                current.append(c); prevWasSep = false
            }
        }
        if !current.isEmpty { fields.append(current) }

        Shell.bashCurrent.environment.arrays[name] = BashArray(dense: fields)
        Shell.bashCurrent.environment.variables.removeValue(forKey: name)
    }

    /// Read one line from `Shell.bashCurrent.stdin`. With `raw: false`, processes
    /// `\<newline>` as line-continuation and `\<char>` as the literal
    /// char (matching bash without `-r`).
    private func readOneLine(raw: Bool) async -> String? {
        guard let first = await Shell.bashCurrent.stdin.readLine() else { return nil }
        if raw { return first }

        // Process backslash escapes. `\<newline>` joins lines.
        var buf = ""
        var line = first
        while true {
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                if c == "\\" {
                    let next = line.index(after: i)
                    if next < line.endIndex {
                        buf.append(line[next])
                        i = line.index(after: next)
                    } else {
                        // Trailing backslash — line continuation. Pull
                        // another line and append (no newline).
                        guard let cont = await Shell.bashCurrent.stdin.readLine() else {
                            return buf
                        }
                        line = cont
                        i = line.startIndex
                        // Don't break — re-enter the inner loop.
                        // The outer-while will repeat too, but only
                        // once we hit endIndex.
                    }
                } else {
                    buf.append(c)
                    i = line.index(after: i)
                }
            }
            // Reached endIndex without a continuation? Done.
            return buf
        }
    }

    /// Assign IFS-split fields of `line` into `names`. The last name
    /// soaks up the rest, including any embedded IFS chars — bash's
    /// "n-1 splits, last variable gets remainder" rule.
    private func assignSplitFields(_ line: String,
                                   into names: [String])
    {
        let ifsChars: [Character] = {
            if let ifs = Shell.bashCurrent.environment["IFS"] {
                return Array(ifs)
            }
            return [" ", "\t", "\n"]
        }()
        let whitespace: Set<Character> = [" ", "\t", "\n"]
        let isIfsWhitespace = ifsChars.allSatisfy { whitespace.contains($0) }

        // Trim leading IFS whitespace (bash does this for the
        // pure-whitespace IFS case).
        var s = line
        if isIfsWhitespace {
            while let first = s.first, ifsChars.contains(first) {
                s.removeFirst()
            }
        }

        var fields: [String] = []
        var current = ""
        var i = s.startIndex
        let ifsSet = Set(ifsChars)

        // Stop after producing names.count - 1 split-fields; the last
        // field gets everything remaining.
        let maxSplits = names.count - 1
        while i < s.endIndex, fields.count < maxSplits {
            let c = s[i]
            if ifsSet.contains(c) {
                fields.append(current)
                current = ""
                if isIfsWhitespace {
                    // Skip a run of whitespace IFS chars.
                    while i < s.endIndex, ifsSet.contains(s[i]) {
                        i = s.index(after: i)
                    }
                } else {
                    i = s.index(after: i)
                }
            } else {
                current.append(c)
                i = s.index(after: i)
            }
        }
        // The remainder (current accumulator + everything still
        // unconsumed) becomes the last field.
        var remainder = current + String(s[i...])
        if isIfsWhitespace {
            while let last = remainder.last, ifsSet.contains(last) {
                remainder.removeLast()
            }
        }
        fields.append(remainder)

        for (j, name) in names.enumerated() {
            Shell.bashCurrent.environment[name] = j < fields.count ? fields[j] : ""
        }
    }
}
