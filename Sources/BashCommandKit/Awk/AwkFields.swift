import Foundation

/// Field handling: split by FS (default: runs of whitespace, with
/// leading/trailing trimmed), `$0` reflects/rebuilds, NF tracks count.
enum AwkFields {

    /// Split a line into fields per current FS. Empty input → no fields.
    static func split(_ line: String, fs: String) -> [String] {
        if line.isEmpty { return [] }
        if fs == " " {
            // Default: any run of whitespace; trim leading/trailing.
            return line.split(omittingEmptySubsequences: true,
                              whereSeparator: { $0.isWhitespace })
                .map { String($0) }
        }
        if fs.count == 1 && !"\\.*+?^${}()|[]".contains(fs) {
            return line.components(separatedBy: fs)
        }
        // FS may be a regex.
        if let regex = try? NSRegularExpression(pattern: fs) {
            let nsstr = line as NSString
            var parts: [String] = []
            var lastEnd = 0
            regex.enumerateMatches(in: line,
                                   range: NSRange(location: 0, length: nsstr.length)) { m, _, _ in
                guard let m else { return }
                parts.append(nsstr.substring(with: NSRange(location: lastEnd,
                                                          length: m.range.location - lastEnd)))
                lastEnd = m.range.location + m.range.length
            }
            parts.append(nsstr.substring(from: lastEnd))
            return parts
        }
        return line.components(separatedBy: fs)
    }

    /// Set $0 and re-derive fields + NF.
    static func setLine(_ ctx: AwkContext, _ line: String) {
        ctx.line = line
        ctx.fields = split(line, fs: ctx.FS)
        ctx.NF = ctx.fields.count
    }

    /// `$index` read.
    static func getField(_ ctx: AwkContext, _ index: Int) -> AwkValue {
        if index == 0 { return .string(ctx.line) }
        if index < 0 { return .empty }
        if index > ctx.fields.count { return .empty }
        return .string(ctx.fields[index - 1])
    }

    /// `$index = value` — extends fields when index > NF, then
    /// rebuilds $0 from joined fields.
    static func setField(_ ctx: AwkContext, _ index: Int, _ value: AwkValue) {
        if index == 0 {
            setLine(ctx, value.asString)
        } else if index > 0 {
            while ctx.fields.count < index { ctx.fields.append("") }
            ctx.fields[index - 1] = value.asString
            ctx.NF = ctx.fields.count
            ctx.line = ctx.fields.joined(separator: ctx.OFS)
        }
    }

    /// Update NF — truncate or extend with empty strings, then
    /// rebuild $0.
    static func setNF(_ ctx: AwkContext, _ newNF: Int) {
        if newNF < ctx.NF {
            ctx.fields = Array(ctx.fields.prefix(newNF))
        } else if newNF > ctx.NF {
            while ctx.fields.count < newNF { ctx.fields.append("") }
        }
        ctx.NF = newNF
        ctx.line = ctx.fields.joined(separator: ctx.OFS)
    }
}
