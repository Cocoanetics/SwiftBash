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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var inFmt = "yaml"
        var outFmt = "yaml"
        var compact = false
        var raw = false
        var positionals: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { positionals.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-o" || arg == "--output-format" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("yq: -o requires FORMAT\n"); return ExitStatus(2)
                }
                outFmt = rawArgv[index + 1]; index += 2; continue
            }
            if arg == "-p" || arg == "--input-format" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("yq: -p requires FORMAT\n"); return ExitStatus(2)
                }
                inFmt = rawArgv[index + 1]; index += 2; continue
            }
            if arg == "-c" || arg == "--compact" { compact = true; index += 1; continue }
            if arg == "-r" || arg == "--raw-output" { raw = true; index += 1; continue }
            if arg.hasPrefix("-") && arg != "-" {
                Shell.bashCurrent.stderr("yq: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            positionals.append(arg); index += 1
        }

        let filterStr = positionals.first ?? "."
        let filePath = positionals.count > 1 ? positionals[1] : nil

        // Read input.
        // swiftlint:disable:next identifier_name - YAML term: 'raw input' kept for readability
        let raw_input: String
        do {
            if let path = filePath {
                let data = try await Shell.bashCurrent.readDataAtPath(path)
                // swiftlint:disable:next optional_data_string_conversion - YAML files may be partial UTF-8
                raw_input = String(decoding: data, as: UTF8.self)
            } else {
                raw_input = await Shell.bashCurrent.stdin.readAllString()
            }
        } catch {
            Shell.bashCurrent.stderr("yq: \(error)\n")
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
                Shell.bashCurrent.stderr("yq: unsupported input format: \(inFmt)\n")
                return ExitStatus(2)
            }
        } catch let error as JqError {
            Shell.bashCurrent.stderr("yq: \(error.message)\n")
            return ExitStatus(2)
        } catch {
            Shell.bashCurrent.stderr("yq: \(error)\n")
            return ExitStatus(2)
        }

        // Compile and run the jq filter.
        let ast: JqAST
        do {
            ast = try JqParser.parse(filterStr)
        } catch let error as JqError {
            Shell.bashCurrent.stderr("yq: parse error: \(error.message)\n")
            return ExitStatus(3)
        }
        let ctx = JqContext()
        let results: [JqValue]
        do {
            results = try JqEvaluator.evaluate(value, ast, ctx: ctx)
        } catch let error as JqError {
            Shell.bashCurrent.stderr("yq: error: \(error.message)\n")
            return ExitStatus(5)
        } catch {
            Shell.bashCurrent.stderr("yq: error: \(error)\n")
            return ExitStatus(5)
        }

        // Format output.
        var out = ""
        for result in results {
            switch outFmt {
            case "json":
                let opts = JqFormatter.Options(compact: compact, raw: raw)
                out += JqFormatter.format(result, options: opts) + "\n"
            case "yaml":
                out += YamlEmitter.emit(result, raw: raw) + "\n"
            default:
                Shell.bashCurrent.stderr("yq: unsupported output format: \(outFmt)\n")
                return ExitStatus(2)
            }
        }
        Shell.bashCurrent.stdout(out)
        return .success
    }
}

// MARK: - YAML parser (subset)

// Minimal YAML parser. Handles:
// - Block mappings (`key: value`)
// - Block sequences (`- item`)
// - Scalars: plain, single-quoted, double-quoted (with `\n` `\t`
//   escapes)
// - Numbers (int / float), booleans (true/false/yes/no), null (~/null)
// - Flow style: `[a, b]` and `{x: 1, y: 2}`
// - Inline `# comment` is stripped
// - Multi-doc `---` separator: returns the first document
//
// Skipped: anchors / aliases / merge keys / tags / block scalars
// (`|` `>`). A real YAML parser would handle these — this one is
// intentionally pragmatic.
// swiftlint:disable:next type_body_length - pragmatic single-file YAML parser
enum YamlParser {

    static func parse(_ source: String) throws -> JqValue {
        // Strip front-matter or multi-doc markers and comments.
        let text = stripComments(source)
        let lines = text.components(separatedBy: "\n")
        // Multi-doc: take the first document up to the next `---`.
        var firstDoc: [String] = []
        var index = 0
        if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            index += 1
        }
        while index < lines.count {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            if stripped == "---" || stripped == "..." { break }
            firstDoc.append(lines[index]); index += 1
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
        var parser = Parser(lines: firstDoc, line: 0)
        return try parser.parseNode(indent: 0)
    }

    static func stripComments(_ source: String) -> String {
        var out = ""
        var inSQ = false
        var inDQ = false
        var idx = source.startIndex
        while idx < source.endIndex {
            let char = source[idx]
            if !inSQ && !inDQ && char == "#" {
                // Skip to end of line.
                while idx < source.endIndex && source[idx] != "\n" { idx = source.index(after: idx) }
                continue
            }
            if !inDQ && char == "'" { inSQ.toggle() }
            if !inSQ && char == "\"" { inDQ.toggle() }
            out.append(char)
            idx = source.index(after: idx)
        }
        return out
    }

    private struct Parser {
        var lines: [String]
        var line: Int
        var atEnd: Bool { line >= lines.count }

        func currentIndent() -> Int {
            guard !atEnd else { return -1 }
            let lineText = lines[line]
            var count = 0
            for char in lineText {
                if char == " " { count += 1 } else { break }
            }
            return count
        }

        mutating func parseNode(indent: Int) throws -> JqValue {
            // Skip blank lines.
            while !atEnd, lines[line].trimmingCharacters(in: .whitespaces).isEmpty {
                line += 1
            }
            if atEnd { return .null }
            let lineText = lines[line]
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)

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
            if trimmed.range(of: ":") != nil {
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
                let lineText = lines[line]
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
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
                let lineText = lines[line]
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
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

        // Find the first top-level `:` (not inside quotes / brackets).
        // swiftlint:disable:next cyclomatic_complexity
        func colonSplit(_ source: String) -> String.Index? {
            var depthBracket = 0
            var depthBrace = 0
            var inSQ = false
            var inDQ = false
            var idx = source.startIndex
            while idx < source.endIndex {
                let char = source[idx]
                if !inDQ, char == "'" { inSQ.toggle() }
                if !inSQ, char == "\"" { inDQ.toggle() }
                if !inSQ && !inDQ {
                    if char == "[" { depthBracket += 1 }
                    if char == "]" { depthBracket -= 1 }
                    if char == "{" { depthBrace += 1 }
                    if char == "}" { depthBrace -= 1 }
                    if char == ":" && depthBracket == 0 && depthBrace == 0 {
                        let next = source.index(after: idx)
                        if next == source.endIndex { return idx }
                        if source[next] == " " || source[next] == "\t" { return idx }
                    }
                }
                idx = source.index(after: idx)
            }
            return nil
        }
    }

    static func parseInlineValue(_ source: String) throws -> JqValue {
        if source.hasPrefix("[") || source.hasPrefix("{") {
            return try parseFlow(source)
        }
        return parseScalar(source)
    }

    static func parseFlow(_ source: String) throws -> JqValue {
        // Convert flow YAML to JSON-ish on the fly: replace bare keys
        // with quoted strings, then run JSON parser. Pragmatic but
        // covers the common cases.
        let cleaned = quoteBareIdents(source)
        if let value = try? JqJSON.parse(cleaned) { return value }
        return parseScalar(source)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func quoteBareIdents(_ source: String) -> String {
        // Walk and add quotes around any unquoted bareword that's
        // followed by `:` (keys) or that would parse as a scalar.
        // For simplicity: also quote bare string values.
        var out = ""
        let chars = Array(source)
        var idx = 0
        while idx < chars.count {
            let char = chars[idx]
            if char == "\"" {
                // Pass through the whole double-quoted string.
                out.append(char); idx += 1
                while idx < chars.count {
                    out.append(chars[idx])
                    if chars[idx] == "\\" && idx + 1 < chars.count {
                        out.append(chars[idx + 1]); idx += 2; continue
                    }
                    if chars[idx] == "\"" { idx += 1; break }
                    idx += 1
                }
                continue
            }
            if char == "'" {
                out.append("\"")
                idx += 1
                while idx < chars.count {
                    if chars[idx] == "'" { idx += 1; break }
                    if chars[idx] == "\"" { out += "\\\"" } else { out.append(chars[idx]) }
                    idx += 1
                }
                out.append("\"")
                continue
            }
            if char.isASCII, char.isLetter || char == "_" {
                var word = ""
                while idx < chars.count, chars[idx].isASCII,
                      chars[idx].isLetter || chars[idx].isNumber || chars[idx] == "_" || chars[idx] == "-" {
                    word.append(chars[idx]); idx += 1
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
            out.append(char); idx += 1
        }
        return out
    }

    // Parse a YAML scalar: numbers, true/false/null, quoted strings.
    static func parseScalar(_ raw: String) -> JqValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" || trimmed == "null" || trimmed == "Null" || trimmed == "NULL" {
            return .null
        }
        if trimmed == "true" || trimmed == "True" || trimmed == "TRUE" ||
            trimmed == "yes" || trimmed == "Yes" || trimmed == "YES" {
            return .bool(true)
        }
        if trimmed == "false" || trimmed == "False" || trimmed == "FALSE" ||
            trimmed == "no" || trimmed == "No" || trimmed == "NO" {
            return .bool(false)
        }
        // Numbers.
        if let number = Int64(trimmed) { return .number(Double(number)) }
        if let number = Double(trimmed),
           trimmed.contains(".") || trimmed.contains("e") || trimmed.contains("E") {
            return .number(number)
        }
        // Quoted strings.
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
            return .string(unescapeDouble(inner))
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            let inner = String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
            return .string(inner)
        }
        return .string(trimmed)
    }

    static func unquote(_ source: String) -> String {
        if source.count >= 2, source.hasPrefix("\""), source.hasSuffix("\"") {
            return unescapeDouble(String(source.dropFirst().dropLast()))
        }
        if source.count >= 2, source.hasPrefix("'"), source.hasSuffix("'") {
            return String(source.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return source
    }

    static func unescapeDouble(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\", idx + 1 < chars.count {
                let next = chars[idx + 1]
                switch next {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "\\": out += "\\"
                case "\"": out += "\""
                default: out.append(next)
                }
                idx += 2
            } else {
                out.append(chars[idx]); idx += 1
            }
        }
        return out
    }
}

// MARK: - YAML emitter (block style)

enum YamlEmitter {

    static func emit(_ value: JqValue, raw: Bool) -> String {
        if raw, case .string(let str) = value { return str }
        return emitNode(value, indent: 0)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func emitNode(_ value: JqValue, indent: Int) -> String {
        switch value {
        case .null: return "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number): return JqValue.formatDouble(number)
        case .string(let str): return needsQuoting(str) ? quote(str) : str
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
                    for line in restLines { lines.append("\(pad)  \(line)") }
                } else {
                    lines.append("\(pad)- \(body)")
                }
            }
            return lines.joined(separator: "\n")
        case .object(let obj):
            if obj.isEmpty { return "{}" }
            let pad = String(repeating: " ", count: indent)
            var lines: [String] = []
            for (key, value) in obj {
                let formattedKey = needsQuoting(key) ? quote(key) : key
                switch value {
                case .object(let nestedObj) where !nestedObj.isEmpty:
                    let nested = emitNode(value, indent: indent + 2)
                    lines.append("\(pad)\(formattedKey):")
                    lines.append(nested)
                case .array(let nestedArr) where !nestedArr.isEmpty:
                    let nested = emitNode(value, indent: indent)
                    lines.append("\(pad)\(formattedKey):")
                    lines.append(nested)
                default:
                    lines.append("\(pad)\(formattedKey): \(emitNode(value, indent: indent + 2))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    static func needsQuoting(_ source: String) -> Bool {
        if source.isEmpty { return true }
        if source == "null" || source == "true" || source == "false" ||
            source == "yes" || source == "no" { return true }
        if Double(source) != nil { return true }
        if source.hasPrefix("- ") || source.hasPrefix("? ") || source.hasPrefix(": ") { return true }
        for char in source {
            if char == ":" || char == "#" || char == "\n" ||
                char == "{" || char == "}" || char == "[" || char == "]" {
                return true
            }
        }
        return false
    }

    static func quote(_ source: String) -> String {
        var out = "\""
        for char in source {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(char)
            }
        }
        out += "\""
        return out
    }
    // swiftlint:disable:next file_length - yq + YAML parser/emitter cohesive in one file
}
