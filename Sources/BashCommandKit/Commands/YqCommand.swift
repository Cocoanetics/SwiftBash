import ArgumentParser
import BashInterpreter
import Foundation

/// `yq [OPTIONS] [FILTER] [FILE]` — YAML processor reusing the jq
/// engine for queries.
///
/// - Reads YAML by default (also JSON, since JSON is valid YAML).
/// - `-o json` / `-o yaml` selects output format (default: yaml).
/// - `-p json` / `-p yaml` forces input format.
/// - `-c` / `--compact` — compact JSON output (no-op for YAML).
/// - `-r` / `--raw-output` — print strings without quotes / wrapping.
///
/// Supported YAML subset: block mappings, block sequences, scalars
/// (plain / single-quoted / double-quoted), inline comments, flow
/// style `[1, 2, 3]` and `{a: 1, b: 2}`. Anchors / aliases / multi-
/// document streams (`---`) read the first document only. Tags are
/// ignored.
public struct YqCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "yq",
        abstract: "YAML processor reusing the jq engine."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, [FILTER] [FILE]")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var inFmt = "yaml"
        var outFmt = "yaml"
        var compact = false
        var raw = false
        var positionals: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { positionals.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-o" || a == "--output-format" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("yq: -o requires FORMAT\n"); return ExitStatus(2)
                }
                outFmt = rawArgv[i + 1]; i += 2; continue
            }
            if a == "-p" || a == "--input-format" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("yq: -p requires FORMAT\n"); return ExitStatus(2)
                }
                inFmt = rawArgv[i + 1]; i += 2; continue
            }
            if a == "-c" || a == "--compact" { compact = true; i += 1; continue }
            if a == "-r" || a == "--raw-output" { raw = true; i += 1; continue }
            if a.hasPrefix("-") && a != "-" {
                Shell.current.stderr("yq: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            positionals.append(a); i += 1
        }

        let filterStr = positionals.first ?? "."
        let filePath = positionals.count > 1 ? positionals[1] : nil

        // Read input.
        let raw_input: String
        do {
            if let p = filePath {
                let data = try await Shell.current.readDataAtPath(p)
                raw_input = String(decoding: data, as: UTF8.self)
            } else {
                raw_input = await Shell.current.stdin.readAllString()
            }
        } catch {
            Shell.current.stderr("yq: \(error)\n")
            return ExitStatus(2)
        }

        // Parse input → JqValue.
        let value: JqValue
        do {
            switch inFmt {
            case "json":
                value = try JqJSON.parse(raw_input)
            case "yaml":
                value = try YamlParser.parse(raw_input)
            default:
                Shell.current.stderr("yq: unsupported input format: \(inFmt)\n")
                return ExitStatus(2)
            }
        } catch let e as JqError {
            Shell.current.stderr("yq: \(e.message)\n")
            return ExitStatus(2)
        } catch {
            Shell.current.stderr("yq: \(error)\n")
            return ExitStatus(2)
        }

        // Compile and run the jq filter.
        let ast: JqAST
        do {
            ast = try JqParser.parse(filterStr)
        } catch let e as JqError {
            Shell.current.stderr("yq: parse error: \(e.message)\n")
            return ExitStatus(3)
        }
        let ctx = JqContext()
        let results: [JqValue]
        do {
            results = try JqEvaluator.evaluate(value, ast, ctx: ctx)
        } catch let e as JqError {
            Shell.current.stderr("yq: error: \(e.message)\n")
            return ExitStatus(5)
        } catch {
            Shell.current.stderr("yq: error: \(error)\n")
            return ExitStatus(5)
        }

        // Format output.
        var out = ""
        for r in results {
            switch outFmt {
            case "json":
                let opts = JqFormatter.Options(compact: compact, raw: raw)
                out += JqFormatter.format(r, options: opts) + "\n"
            case "yaml":
                out += YamlEmitter.emit(r, raw: raw) + "\n"
            default:
                Shell.current.stderr("yq: unsupported output format: \(outFmt)\n")
                return ExitStatus(2)
            }
        }
        Shell.current.stdout(out)
        return .success
    }
}

// MARK: - YAML parser (subset)

/// Minimal YAML parser. Handles:
/// - Block mappings (`key: value`)
/// - Block sequences (`- item`)
/// - Scalars: plain, single-quoted, double-quoted (with `\n` `\t`
///   escapes)
/// - Numbers (int / float), booleans (true/false/yes/no), null (~/null)
/// - Flow style: `[a, b]` and `{x: 1, y: 2}`
/// - Inline `# comment` is stripped
/// - Multi-doc `---` separator: returns the first document
///
/// Skipped: anchors / aliases / merge keys / tags / block scalars
/// (`|` `>`). A real YAML parser would handle these — this one is
/// intentionally pragmatic.
enum YamlParser {

    static func parse(_ source: String) throws -> JqValue {
        // Strip front-matter or multi-doc markers and comments.
        let text = stripComments(source)
        let lines = text.components(separatedBy: "\n")
        // Multi-doc: take the first document up to the next `---`.
        var firstDoc: [String] = []
        var i = 0
        if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            i += 1
        }
        while i < lines.count {
            let stripped = lines[i].trimmingCharacters(in: .whitespaces)
            if stripped == "---" || stripped == "..." { break }
            firstDoc.append(lines[i]); i += 1
        }
        // Remove leading and trailing blank lines.
        while let first = firstDoc.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            firstDoc.removeFirst()
        }
        while let last = firstDoc.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            firstDoc.removeLast()
        }
        if firstDoc.isEmpty { return .null }
        var p = Parser(lines: firstDoc, line: 0)
        return try p.parseNode(indent: 0)
    }

    static func stripComments(_ s: String) -> String {
        var out = ""
        var inSQ = false
        var inDQ = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if !inSQ && !inDQ && c == "#" {
                // Skip to end of line.
                while i < s.endIndex && s[i] != "\n" { i = s.index(after: i) }
                continue
            }
            if !inDQ && c == "'" { inSQ.toggle() }
            if !inSQ && c == "\"" { inDQ.toggle() }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private struct Parser {
        var lines: [String]
        var line: Int
        var atEnd: Bool { line >= lines.count }

        func currentIndent() -> Int {
            guard !atEnd else { return -1 }
            let l = lines[line]
            var n = 0
            for c in l {
                if c == " " { n += 1 } else { break }
            }
            return n
        }

        mutating func parseNode(indent: Int) throws -> JqValue {
            // Skip blank lines.
            while !atEnd, lines[line].trimmingCharacters(in: .whitespaces).isEmpty {
                line += 1
            }
            if atEnd { return .null }
            let l = lines[line]
            let trimmed = l.trimmingCharacters(in: .whitespaces)

            // Flow style — handled inline if the value is on one line.
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                line += 1
                return try YamlParser.parseFlow(trimmed)
            }

            // Block sequence: line starts with `- `.
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                return try parseBlockSequence(indent: indent)
            }

            // Block mapping: line contains `: ` or ends with `:`.
            if let _ = trimmed.range(of: ":") {
                return try parseBlockMapping(indent: indent)
            }

            // Bare scalar.
            line += 1
            return YamlParser.parseScalar(trimmed)
        }

        mutating func parseBlockSequence(indent: Int) throws -> JqValue {
            var items: [JqValue] = []
            while !atEnd {
                let cur = currentIndent()
                if cur < indent { break }
                let l = lines[line]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if cur == indent, trimmed.hasPrefix("-") {
                    // Inline value after `- `: consume it as a scalar
                    // or nested mapping/sequence.
                    if trimmed == "-" {
                        line += 1
                        let value = try parseNode(indent: indent + 2)
                        items.append(value)
                    } else {
                        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        // If the body looks like `key: value`, parse as
                        // a single-line mapping in this sequence slot.
                        if body.contains(":") && !body.hasPrefix("[") && !body.hasPrefix("{") {
                            // Treat the rest of this line + any deeper-
                            // indented continuation as a nested mapping.
                            // Replace this line with the body indented
                            // further so parseBlockMapping can re-enter.
                            let pad = String(repeating: " ", count: cur + 2)
                            lines[line] = pad + body
                            let value = try parseBlockMapping(indent: cur + 2)
                            items.append(value)
                        } else {
                            line += 1
                            items.append(YamlParser.parseScalar(body))
                        }
                    }
                } else {
                    break
                }
            }
            return .array(items)
        }

        mutating func parseBlockMapping(indent: Int) throws -> JqValue {
            var obj = JqObject()
            while !atEnd {
                let cur = currentIndent()
                if cur < indent { break }
                let l = lines[line]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                guard cur == indent else { break }
                guard let colon = colonSplit(trimmed) else { break }
                let rawKey = String(trimmed[..<colon])
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                let key = YamlParser.unquote(rawKey.trimmingCharacters(in: .whitespaces))
                line += 1
                if value.isEmpty {
                    // Nested block under this key.
                    let nested = try parseNode(indent: indent + 2)
                    obj[key] = nested
                } else {
                    obj[key] = try YamlParser.parseInlineValue(value)
                }
            }
            return .object(obj)
        }

        /// Find the first top-level `:` (not inside quotes / brackets).
        func colonSplit(_ s: String) -> String.Index? {
            var depthBracket = 0
            var depthBrace = 0
            var inSQ = false
            var inDQ = false
            var i = s.startIndex
            while i < s.endIndex {
                let c = s[i]
                if !inDQ, c == "'" { inSQ.toggle() }
                if !inSQ, c == "\"" { inDQ.toggle() }
                if !inSQ && !inDQ {
                    if c == "[" { depthBracket += 1 }
                    if c == "]" { depthBracket -= 1 }
                    if c == "{" { depthBrace += 1 }
                    if c == "}" { depthBrace -= 1 }
                    if c == ":" && depthBracket == 0 && depthBrace == 0 {
                        let next = s.index(after: i)
                        if next == s.endIndex { return i }
                        if s[next] == " " || s[next] == "\t" { return i }
                    }
                }
                i = s.index(after: i)
            }
            return nil
        }
    }

    static func parseInlineValue(_ s: String) throws -> JqValue {
        if s.hasPrefix("[") || s.hasPrefix("{") {
            return try parseFlow(s)
        }
        return parseScalar(s)
    }

    static func parseFlow(_ s: String) throws -> JqValue {
        // Convert flow YAML to JSON-ish on the fly: replace bare keys
        // with quoted strings, then run JSON parser. Pragmatic but
        // covers the common cases.
        let cleaned = quoteBareIdents(s)
        if let v = try? JqJSON.parse(cleaned) { return v }
        return parseScalar(s)
    }

    static func quoteBareIdents(_ s: String) -> String {
        // Walk and add quotes around any unquoted bareword that's
        // followed by `:` (keys) or that would parse as a scalar.
        // For simplicity: also quote bare string values.
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                // Pass through the whole double-quoted string.
                out.append(c); i += 1
                while i < chars.count {
                    out.append(chars[i])
                    if chars[i] == "\\" && i + 1 < chars.count {
                        out.append(chars[i + 1]); i += 2; continue
                    }
                    if chars[i] == "\"" { i += 1; break }
                    i += 1
                }
                continue
            }
            if c == "'" {
                out.append("\"")
                i += 1
                while i < chars.count {
                    if chars[i] == "'" { i += 1; break }
                    if chars[i] == "\"" { out += "\\\"" } else { out.append(chars[i]) }
                    i += 1
                }
                out.append("\"")
                continue
            }
            if c.isASCII, c.isLetter || c == "_" {
                var word = ""
                while i < chars.count, chars[i].isASCII,
                      chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "-" {
                    word.append(chars[i]); i += 1
                }
                // Boolean / null literals — emit as JSON literal.
                let lower = word.lowercased()
                if lower == "true" || lower == "false" || lower == "null" {
                    out += lower
                } else {
                    out += "\"" + word + "\""
                }
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// Parse a YAML scalar: numbers, true/false/null, quoted strings.
    static func parseScalar(_ raw: String) -> JqValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "~" || s == "null" || s == "Null" || s == "NULL" { return .null }
        if s == "true" || s == "True" || s == "TRUE" || s == "yes" || s == "Yes" || s == "YES" {
            return .bool(true)
        }
        if s == "false" || s == "False" || s == "FALSE" || s == "no" || s == "No" || s == "NO" {
            return .bool(false)
        }
        // Numbers.
        if let n = Int64(s) { return .number(Double(n)) }
        if let n = Double(s), s.contains(".") || s.contains("e") || s.contains("E") {
            return .number(n)
        }
        // Quoted strings.
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            let inner = String(s.dropFirst().dropLast())
            return .string(unescapeDouble(inner))
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            let inner = String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            return .string(inner)
        }
        return .string(s)
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return unescapeDouble(String(s.dropFirst().dropLast()))
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    static func unescapeDouble(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "\\": out += "\\"
                case "\"": out += "\""
                default: out.append(n)
                }
                i += 2
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }
}

// MARK: - YAML emitter (block style)

enum YamlEmitter {

    static func emit(_ value: JqValue, raw: Bool) -> String {
        if raw, case .string(let s) = value { return s }
        return emitNode(value, indent: 0)
    }

    static func emitNode(_ v: JqValue, indent: Int) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JqValue.formatDouble(n)
        case .string(let s): return needsQuoting(s) ? quote(s) : s
        case .array(let arr):
            if arr.isEmpty { return "[]" }
            let pad = String(repeating: " ", count: indent)
            var lines: [String] = []
            for item in arr {
                let body = emitNode(item, indent: indent + 2)
                if body.contains("\n") {
                    let firstLine = body.components(separatedBy: "\n").first!
                    let restLines = body.components(separatedBy: "\n").dropFirst()
                    lines.append("\(pad)- \(firstLine)")
                    for l in restLines { lines.append("\(pad)  \(l)") }
                } else {
                    lines.append("\(pad)- \(body)")
                }
            }
            return lines.joined(separator: "\n")
        case .object(let obj):
            if obj.isEmpty { return "{}" }
            let pad = String(repeating: " ", count: indent)
            var lines: [String] = []
            for (k, value) in obj {
                let key = needsQuoting(k) ? quote(k) : k
                switch value {
                case .object(let o) where !o.isEmpty:
                    let nested = emitNode(value, indent: indent + 2)
                    lines.append("\(pad)\(key):")
                    lines.append(nested)
                case .array(let a) where !a.isEmpty:
                    let nested = emitNode(value, indent: indent)
                    lines.append("\(pad)\(key):")
                    lines.append(nested)
                default:
                    lines.append("\(pad)\(key): \(emitNode(value, indent: indent + 2))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s == "null" || s == "true" || s == "false" || s == "yes" || s == "no" { return true }
        if Double(s) != nil { return true }
        if s.hasPrefix("- ") || s.hasPrefix("? ") || s.hasPrefix(": ") { return true }
        for c in s {
            if c == ":" || c == "#" || c == "\n" || c == "{" || c == "}" || c == "[" || c == "]" {
                return true
            }
        }
        return false
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        out += "\""
        return out
    }
}
