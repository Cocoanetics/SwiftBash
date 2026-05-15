import Foundation

// Pattern binding (jq `as` destructuring) and string interpolation.

extension JqEvaluator {

    static func bindPattern(_ ctx: JqContext,
                            _ pat: JqPattern,
                            _ value: JqValue) -> JqContext? {
        switch pat {
        case .variable(let name):
            let nctx = ctx.fork()
            nctx.vars[name] = value
            return nctx
        case .array(let elems):
            return bindArrayPattern(ctx, elems: elems, value: value)
        case .object(let fields):
            return bindObjectPattern(ctx, fields: fields, value: value)
        }
    }

    private static func bindArrayPattern(_ ctx: JqContext,
                                         elems: [JqPattern],
                                         value: JqValue) -> JqContext? {
        guard case .array(let arr) = value else { return nil }
        var nctx = ctx
        for (index, elem) in elems.enumerated() {
            let elemValue = index < arr.count ? arr[index] : .null
            guard let bound = bindPattern(nctx, elem, elemValue) else { return nil }
            nctx = bound
        }
        return nctx
    }

    private static func bindObjectPattern(_ ctx: JqContext,
                                          fields: [JqPatternField],
                                          value: JqValue) -> JqContext? {
        guard case .object(let obj) = value else { return nil }
        var nctx = ctx
        for field in fields {
            let key: String
            switch field.key {
            case .literal(let str): key = str
            case .computed(let expr):
                guard let keyVal = (try? evalNode(value, expr, nctx))?.first,
                      case .string(let str) = keyVal else { return nil }
                key = str
            }
            let fieldVal = obj[key] ?? .null
            if let keyVarName = field.keyVar {
                let inner = nctx.fork()
                inner.vars[keyVarName] = fieldVal
                nctx = inner
            }
            guard let bound = bindPattern(nctx, field.pattern, fieldVal) else { return nil }
            nctx = bound
        }
        return nctx
    }

    static func evalStringInterp(_ value: JqValue,
                                 _ parts: [JqStringPart],
                                 _ ctx: JqContext) -> JqValue {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let str): out += str
            case .interp(let expr):
                let vals = (try? evalNode(value, expr, ctx)) ?? []
                for item in vals {
                    switch item {
                    case .string(let str): out += str
                    default: out += JqFormatter.compact(item)
                    }
                }
            }
        }
        return .string(out)
    }
}
