import Foundation

// MARK: - Array operations split out to keep `AwkExpressions` body lean.

extension AwkExpressions {
    static func resolveArray(_ ctx: AwkContext, _ name: String) -> String {
        // Follow alias chain (for function param pass-by-reference).
        var resolved = name
        var seen = Set<String>()
        while let alias = ctx.arrayAliases[resolved], !seen.contains(resolved) {
            seen.insert(resolved)
            resolved = alias
        }
        return resolved
    }

    static func getArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) -> AwkValue {
        if name == "ARGV" { return ctx.ARGV[key] ?? .empty }
        if name == "ENVIRON" { return ctx.ENVIRON[key] ?? .empty }
        let resolved = resolveArray(ctx, name)
        return ctx.arrays[resolved]?[key] ?? .empty
    }

    static func setArrayElement(_ ctx: AwkContext, _ name: String, _ key: String, _ value: AwkValue) {
        let resolved = resolveArray(ctx, name)
        if ctx.arrays[resolved] == nil { ctx.arrays[resolved] = AwkArray() }
        ctx.arrays[resolved]![key] = value
    }

    static func hasArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) -> Bool {
        if name == "ARGV" { return ctx.ARGV[key] != nil }
        if name == "ENVIRON" { return ctx.ENVIRON[key] != nil }
        let resolved = resolveArray(ctx, name)
        return ctx.arrays[resolved]?[key] != nil
    }

    static func deleteArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) {
        let resolved = resolveArray(ctx, name)
        ctx.arrays[resolved]?.remove(key)
    }

    static func deleteArray(_ ctx: AwkContext, _ name: String) {
        let resolved = resolveArray(ctx, name)
        ctx.arrays[resolved]?.clear()
    }

    /// `(i, j) in arr` joins the tuple parts with SUBSEP.
    static func evalArrayKey(_ ctx: AwkContext, _ key: AwkExpr) throws -> String {
        if case .tuple(let elems) = key {
            var parts: [String] = []
            for elem in elems { parts.append(try eval(ctx, elem).asString) }
            return parts.joined(separator: ctx.SUBSEP)
        }
        return try eval(ctx, key).asString
    }
}
