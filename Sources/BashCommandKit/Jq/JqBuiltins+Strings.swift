import Foundation

// String-related jq builtins. Split from `JqBuiltins.swift` to keep
// that file under SwiftLint's file-length limit. Includes the
// `stringBuiltin` dispatch plus the `subOrGsub` / regex helpers used
// by `sub`, `gsub`, `match`, `capture`, `scan`, `splits`, `test`.
extension JqBuiltins {

    // String switch: branch per jq string builtin (join/split/scan/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func stringBuiltin(_ value: JqValue, _ name: String,
                              _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "join":
            guard case .array(let arr) = value else { return [.null] }
            let seps = try args.first.map { try JqEvaluator.evalNode(value, $0, ctx) } ?? [.string("")]
            return seps.map { sep -> JqValue in
                var sepStr = ""
                if case .string(let str) = sep { sepStr = str } else { sepStr = JqFormatter.compact(sep) }
                let pieces = arr.map { item -> String in
                    switch item {
                    case .null: return ""
                    case .string(let str): return str
                    default: return JqFormatter.compact(item)
                    }
                }
                return .string(pieces.joined(separator: sepStr))
            }
        case "split":
            guard case .string(let str) = value, !args.isEmpty else { return [.null] }
            let seps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let sep) = seps.first ?? .null else { return [.null] }
            if sep.isEmpty {
                return [.array(str.map { .string(String($0)) })]
            }
            return [.array(str.components(separatedBy: sep).map { .string($0) })]
        case "splits":
            guard case .string(let str) = value, !args.isEmpty else { return [] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [] }
            do {
                let regex = try NSRegularExpression(pattern: pat)
                let nsstr = str as NSString
                var results: [String] = []
                var lastEnd = 0
                regex.enumerateMatches(in: str, range: NSRange(location: 0, length: nsstr.length)) { match, _, _ in
                    guard let match else { return }
                    results.append(nsstr.substring(with: NSRange(location: lastEnd,
                                                                  length: match.range.location - lastEnd)))
                    lastEnd = match.range.location + match.range.length
                }
                results.append(nsstr.substring(from: lastEnd))
                return results.map { .string($0) }
            } catch {
                return []
            }
        case "ascii_downcase":
            guard case .string(let str) = value else { return [.null] }
            var out = ""
            for char in str {
                if let ascii = char.asciiValue, ascii >= 0x41, ascii <= 0x5A {
                    out.append(Character(Unicode.Scalar(ascii + 32)))
                } else {
                    out.append(char)
                }
            }
            return [.string(out)]
        case "ascii_upcase":
            guard case .string(let str) = value else { return [.null] }
            var out = ""
            for char in str {
                if let ascii = char.asciiValue, ascii >= 0x61, ascii <= 0x7A {
                    out.append(Character(Unicode.Scalar(ascii - 32)))
                } else {
                    out.append(char)
                }
            }
            return [.string(out)]
        case "ltrimstr":
            guard case .string(let str) = value, !args.isEmpty else { return [value] }
            let prefixes = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let prefix) = prefixes.first ?? .null else { return [value] }
            if str.hasPrefix(prefix) { return [.string(String(str.dropFirst(prefix.count)))] }
            return [value]
        case "rtrimstr":
            guard case .string(let str) = value, !args.isEmpty else { return [value] }
            let suffixes = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let suffix) = suffixes.first ?? .null else { return [value] }
            if suffix.isEmpty { return [value] }
            if str.hasSuffix(suffix) { return [.string(String(str.dropLast(suffix.count)))] }
            return [value]
        case "trimstr":
            guard case .string(let str) = value, !args.isEmpty else { return [value] }
            let probes = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let probe) = probes.first ?? .null, !probe.isEmpty else { return [value] }
            var result = str
            if result.hasPrefix(probe) { result = String(result.dropFirst(probe.count)) }
            if result.hasSuffix(probe) { result = String(result.dropLast(probe.count)) }
            return [.string(result)]
        case "trim":
            guard case .string(let str) = value else { throw JqError("trim input must be a string") }
            return [.string(str.trimmingCharacters(in: .whitespacesAndNewlines))]
        case "ltrim":
            guard case .string(let str) = value else { throw JqError("trim input must be a string") }
            var cursor = str.startIndex
            while cursor < str.endIndex, str[cursor].isWhitespace { cursor = str.index(after: cursor) }
            return [.string(String(str[cursor...]))]
        case "rtrim":
            guard case .string(let str) = value else { throw JqError("trim input must be a string") }
            var end = str.endIndex
            while end > str.startIndex {
                let prev = str.index(before: end)
                if !str[prev].isWhitespace { break }
                end = prev
            }
            return [.string(String(str[..<end]))]
        case "startswith":
            guard case .string(let str) = value, !args.isEmpty else { return [.bool(false)] }
            let prefixes = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let prefix) = prefixes.first ?? .null else { return [.bool(false)] }
            return [.bool(str.hasPrefix(prefix))]
        case "endswith":
            guard case .string(let str) = value, !args.isEmpty else { return [.bool(false)] }
            let suffixes = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let suffix) = suffixes.first ?? .null else { return [.bool(false)] }
            return [.bool(str.hasSuffix(suffix))]
        case "explode":
            guard case .string(let str) = value else { return [.null] }
            return [.array(str.unicodeScalars.map { .number(Double($0.value)) })]
        case "implode":
            guard case .array(let arr) = value else {
                throw JqError("implode input must be an array")
            }
            var out = ""
            for codepoint in arr {
                guard case .number(let num) = codepoint else {
                    throw JqError("implode requires numeric code points")
                }
                let code = UInt32(num)
                if let scalar = Unicode.Scalar(code), code <= 0x10FFFF, !(0xD800...0xDFFF).contains(code) {
                    out.append(Character(scalar))
                } else {
                    out.append("\u{FFFD}")
                }
            }
            return [.string(out)]
        case "test":
            guard case .string(let str) = value, !args.isEmpty else { return [.bool(false)] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.bool(false)] }
            var flags = ""
            if args.count > 1 {
                let flagsArr = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let flagStr) = flagsArr.first ?? .null { flags = flagStr }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let match = regex.firstMatch(in: str, range: NSRange(location: 0,
                                                                      length: (str as NSString).length))
                return [.bool(match != nil)]
            } catch {
                return [.bool(false)]
            }
        case "match":
            guard case .string(let str) = value, !args.isEmpty else { return [.null] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.null] }
            var flags = ""
            if args.count > 1 {
                let flagsArr = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let flagStr) = flagsArr.first ?? .null { flags = flagStr }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = str as NSString
                let global = flags.contains("g")
                let matches: [NSTextCheckingResult] = global ?
                    regex.matches(in: str, range: NSRange(location: 0, length: nsstr.length)) :
                    (regex.firstMatch(in: str, range: NSRange(location: 0, length: nsstr.length)).map { [$0] } ?? [])
                if matches.isEmpty { return [] }
                return matches.map { match -> JqValue in
                    var entry = JqObject()
                    entry["offset"] = .number(Double(match.range.location))
                    entry["length"] = .number(Double(match.range.length))
                    entry["string"] = .string(nsstr.substring(with: match.range))
                    var captures: [JqValue] = []
                    for groupIdx in 1..<match.numberOfRanges {
                        let groupRange = match.range(at: groupIdx)
                        var cap = JqObject()
                        if groupRange.location == NSNotFound {
                            cap["offset"] = .number(-1)
                            cap["length"] = .number(0)
                            cap["string"] = .null
                        } else {
                            cap["offset"] = .number(Double(groupRange.location))
                            cap["length"] = .number(Double(groupRange.length))
                            cap["string"] = .string(nsstr.substring(with: groupRange))
                        }
                        cap["name"] = .null
                        captures.append(.object(cap))
                    }
                    entry["captures"] = .array(captures)
                    return .object(entry)
                }
            } catch {
                return []
            }
        case "capture":
            guard case .string(let str) = value, !args.isEmpty else { return [.null] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.null] }
            var flags = ""
            if args.count > 1 {
                let flagsArr = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let flagStr) = flagsArr.first ?? .null { flags = flagStr }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = str as NSString
                let match = regex.firstMatch(in: str, range: NSRange(location: 0, length: nsstr.length))
                guard let match else { return [] }
                // Extract named captures via regex pattern parsing.
                let names = parseNamedGroups(pat)
                var obj = JqObject()
                for (groupIdx, groupName) in names where groupIdx < match.numberOfRanges {
                    let range = match.range(at: groupIdx)
                    if range.location == NSNotFound {
                        obj[groupName] = .null
                    } else {
                        obj[groupName] = .string(nsstr.substring(with: range))
                    }
                }
                return [.object(obj)]
            } catch {
                return [.null]
            }
        case "scan":
            guard case .string(let str) = value, !args.isEmpty else { return [] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [] }
            var flags = "g"
            if args.count > 1 {
                let flagsArr = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let flagStr) = flagsArr.first ?? .null {
                    flags = flagStr.contains("g") ? flagStr : flagStr + "g"
                }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = str as NSString
                let matches = regex.matches(in: str, range: NSRange(location: 0, length: nsstr.length))
                return matches.map { match -> JqValue in
                    if match.numberOfRanges > 1 {
                        var caps: [JqValue] = []
                        for groupIdx in 1..<match.numberOfRanges {
                            let range = match.range(at: groupIdx)
                            if range.location == NSNotFound {
                                caps.append(.null)
                            } else {
                                caps.append(.string(nsstr.substring(with: range)))
                            }
                        }
                        return .array(caps)
                    }
                    return .string(nsstr.substring(with: match.range))
                }
            } catch {
                return []
            }
        case "sub":
            return try subOrGsub(value, args, ctx, global: false)
        case "gsub":
            return try subOrGsub(value, args, ctx, global: true)
        default: return nil
        }
    }

    static func subOrGsub(_ value: JqValue, _ args: [JqAST],
                          _ ctx: JqContext, global: Bool) throws -> [JqValue] {
        guard case .string(let str) = value, args.count >= 2 else { return [.null] }
        let pats = try JqEvaluator.evalNode(value, args[0], ctx)
        let reps = try JqEvaluator.evalNode(value, args[1], ctx)
        guard case .string(let pat) = pats.first ?? .null,
              case .string(let rep) = reps.first ?? .null else { return [value] }
        var flags = global ? "g" : ""
        if args.count > 2 {
            let flagsArr = try JqEvaluator.evalNode(value, args[2], ctx)
            if case .string(let flagStr) = flagsArr.first ?? .null {
                flags = global && !flagStr.contains("g") ? flagStr + "g" : flagStr
            }
        }
        do {
            let regex = try buildRegex(pat, flags: flags)
            let nsstr = str as NSString
            let range = NSRange(location: 0, length: nsstr.length)
            let limit = global ? regex.matches(in: str, range: range).count : 1
            var result = str
            for _ in 0..<limit {
                let nsResult = result as NSString
                let firstMatch = regex.firstMatch(in: result, range: NSRange(location: 0,
                                                                              length: nsResult.length))
                guard let match = firstMatch else { break }
                let replaced = regex.replacementString(for: match, in: result, offset: 0, template: rep)
                result = nsResult.replacingCharacters(in: match.range, with: replaced)
                if !global { break }
            }
            return [.string(result)]
        } catch {
            return [value]
        }
    }

    static func buildRegex(_ pattern: String, flags: String) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    static func parseNamedGroups(_ pattern: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var groupIndex = 0
        let chars = Array(pattern)
        var cursor = 0
        while cursor < chars.count {
            if chars[cursor] == "\\" { cursor += 2; continue }
            if chars[cursor] == "(" {
                if cursor + 1 < chars.count && chars[cursor + 1] == "?" {
                    if cursor + 3 < chars.count && chars[cursor + 2] == "P" && chars[cursor + 3] == "<" {
                        cursor += 4
                        var name = ""
                        while cursor < chars.count, chars[cursor] != ">" {
                            name.append(chars[cursor]); cursor += 1
                        }
                        groupIndex += 1
                        result.append((groupIndex, name))
                    } else if cursor + 2 < chars.count && chars[cursor + 2] == "<" {
                        cursor += 3
                        var name = ""
                        while cursor < chars.count, chars[cursor] != ">" {
                            name.append(chars[cursor]); cursor += 1
                        }
                        groupIndex += 1
                        result.append((groupIndex, name))
                    } else {
                        // non-capturing or modifier
                    }
                } else {
                    groupIndex += 1
                }
            }
            cursor += 1
        }
        return result
    }
}
