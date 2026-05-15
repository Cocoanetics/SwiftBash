import Foundation

// Dispatch table for every jq builtin. Mirrors the just-bash split into
// type / math / string / array / object / control / path / index /
// navigation / SQL groups, but kept in one file because Swift makes
// the cross-module wiring more painful than the sum of all groups put
// together. The enum collects every jq builtin in one place by design;
// splitting it across files would defeat the dispatch-table layout.
// swiftlint:disable:next type_body_length
enum JqBuiltins {

    // Top-level dispatch routes by builtin name across all groups;
    // body is intrinsically a long switch.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func evaluate(_ value: JqValue, name: String, args: [JqAST],
                         ctx: JqContext) throws -> [JqValue] {
        // 0. user-defined function (shadows builtins, matching real jq).
        if let userFunc = ctx.funcs["\(name)/\(args.count)"] {
            return try callUserFunc(userFunc, value: value, args: args, ctx: ctx, name: name)
        }

        // 1. simple math (single-value: floor / ceil / sqrt / etc.)
        if let results = try simpleMath(value, name) { return results }

        // 2. group dispatch — first match wins
        if let results = try typeBuiltin(value, name) { return results }
        if let results = try mathBuiltin(value, name, args, ctx) { return results }
        if let results = try stringBuiltin(value, name, args, ctx) { return results }
        if let results = try objectBuiltin(value, name, args, ctx) { return results }
        if let results = try arrayBuiltin(value, name, args, ctx) { return results }
        if let results = try controlBuiltin(value, name, args, ctx) { return results }
        if let results = try indexBuiltin(value, name, args, ctx) { return results }
        if let results = try pathBuiltin(value, name, args, ctx) { return results }
        if let results = try navigationBuiltin(value, name, args, ctx) { return results }
        if let results = try sqlBuiltin(value, name, args, ctx) { return results }
        if let results = try dateBuiltin(value, name, args, ctx) { return results }

        switch name {
        case "env":
            var obj = JqObject()
            for (key, val) in ctx.env { obj[key] = .string(val) }
            return [.object(obj)]
        case "$ENV":
            var obj = JqObject()
            for (key, val) in ctx.env { obj[key] = .string(val) }
            return [.object(obj)]
        case "debug":
            FileHandle.standardError.write(Data("[\"DEBUG:\",\(JqFormatter.compact(value))]\n".utf8))
            return [value]
        case "stderr":
            FileHandle.standardError.write(Data(JqFormatter.compact(value).utf8))
            return [value]
        case "input_line_number":
            return [.number(1)]
        case "error":
            if args.isEmpty {
                throw JqThrown(value)
            }
            let payload = try JqEvaluator.evalNode(value, args[0], ctx).first ?? .null
            throw JqThrown(payload)
        case "halt":
            exit(0)
        case "halt_error":
            let code: Int32
            let firstArg = try args.first.map { try JqEvaluator.evalNode(value, $0, ctx).first ?? .null }
            if args.isEmpty {
                code = 5
            } else if case .number(let num) = firstArg ?? .null {
                code = Int32(num)
            } else {
                code = 5
            }
            switch value {
            case .string(let str): FileHandle.standardError.write(Data(str.utf8))
            default: FileHandle.standardError.write(Data((JqFormatter.compact(value) + "\n").utf8))
            }
            exit(code)
        case "input", "inputs":
            return []
        case "getpath":
            // Already in pathBuiltin
            return []
        case "min", "max":
            return []  // handled in arrayBuiltin
        case "builtins":
            return [.array(builtinsList.sorted().map { .string($0) })]
        case "ascii":
            if case .string(let str) = value, let first = str.unicodeScalars.first {
                return [.number(Double(first.value))]
            }
            return [.null]
        case "splits":
            return try stringBuiltin(value, "splits", args, ctx) ?? []
        case "test", "match", "capture", "scan", "sub", "gsub":
            return try stringBuiltin(value, name, args, ctx) ?? []
        case "ascii_downcase", "ascii_upcase":
            return try stringBuiltin(value, name, args, ctx) ?? []
        default:
            throw JqError("\(name)/\(args.count) is not defined")
        }
    }

    // MARK: - User-defined function call

    static func callUserFunc(_ userFunc: JqFunc, value: JqValue,
                             args: [JqAST], ctx: JqContext,
                             name: String) throws -> [JqValue] {
        // jq parameters are filters. If a parameter is referenced
        // multiple times in the body, each reference re-runs the
        // expression — but for simplicity we fold to call-by-name via
        // synthetic 0-arg defs.
        let nctx = ctx.fork()
        nctx.funcs = userFunc.closure
        let key = "\(name)/\(userFunc.params.count)"
        nctx.funcs[key] = userFunc
        for (idx, paramName) in userFunc.params.enumerated() {
            if paramName.hasPrefix("$") {
                // value-parameter: bind the variable directly to the
                // single result.
                let result = try JqEvaluator.evalNode(value, args[idx], ctx)
                nctx.vars[paramName] = result.first ?? .null
            } else {
                // filter-parameter: store the expression as a 0-arg
                // function in the new context. Capture the *caller's*
                // funcs/vars so the expression resolves names from the
                // call site, not the callee's body.
                let argExpr = args[idx]
                let captured = ctx.funcs
                let capturedVars = ctx.vars
                let synthetic = JqFunc(params: [], body: argExpr, closure: captured)
                nctx.funcs["\(paramName)/0"] = synthetic
                // also pre-bind any vars closed over (best-effort: copy
                // current vars onto a hidden marker; called func can
                // access them via VarRef which already reads ctx.vars).
                _ = capturedVars
            }
        }
        return try JqEvaluator.evalNode(value, userFunc.body, nctx)
    }

    // MARK: - Simple math (single-arg double->double)

    static func simpleMath(_ value: JqValue, _ name: String) throws -> [JqValue]? {
        let map: [String: (Double) -> Double] = [
            "floor": { $0.rounded(.down) },
            "ceil": { $0.rounded(.up) },
            "round": { $0.rounded() },
            "sqrt": { $0.squareRoot() },
            "log": { Foundation.log($0) },
            "log10": { Foundation.log10($0) },
            "log2": { Foundation.log2($0) },
            "exp": { Foundation.exp($0) },
            "sin": { Foundation.sin($0) },
            "cos": { Foundation.cos($0) },
            "tan": { Foundation.tan($0) },
            "asin": { Foundation.asin($0) },
            "acos": { Foundation.acos($0) },
            "atan": { Foundation.atan($0) },
            "sinh": { Foundation.sinh($0) },
            "cosh": { Foundation.cosh($0) },
            "tanh": { Foundation.tanh($0) },
            "asinh": { Foundation.asinh($0) },
            "acosh": { Foundation.acosh($0) },
            "atanh": { Foundation.atanh($0) },
            "cbrt": { Foundation.cbrt($0) },
            "expm1": { Foundation.expm1($0) },
            "log1p": { Foundation.log1p($0) },
            "trunc": { $0.rounded(.towardZero) }
        ]
        guard let mathFn = map[name] else { return nil }
        if case .number(let num) = value { return [.number(mathFn(num))] }
        return [.null]
    }

    // MARK: - Type group

    // One switch case per jq type predicate; complexity is intrinsic.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func typeBuiltin(_ value: JqValue, _ name: String) throws -> [JqValue]? {
        switch name {
        case "type": return [.string(value.typeName)]
        case "infinite": return [.number(.infinity)]
        case "nan": return [.number(.nan)]
        case "isinfinite":
            if case .number(let num) = value { return [.bool(num.isInfinite)] }
            return [.bool(false)]
        case "isnan":
            if case .number(let num) = value { return [.bool(num.isNaN)] }
            return [.bool(false)]
        case "isnormal":
            if case .number(let num) = value { return [.bool(num.isNormal)] }
            return [.bool(false)]
        case "isfinite":
            if case .number(let num) = value { return [.bool(num.isFinite)] }
            return [.bool(false)]
        case "numbers":
            if case .number = value { return [value] }
            return []
        case "strings":
            if case .string = value { return [value] }
            return []
        case "booleans":
            if case .bool = value { return [value] }
            return []
        case "nulls":
            if case .null = value { return [value] }
            return []
        case "arrays":
            if case .array = value { return [value] }
            return []
        case "objects":
            if case .object = value { return [value] }
            return []
        case "iterables":
            switch value {
            case .array, .object: return [value]
            default: return []
            }
        case "scalars":
            switch value {
            case .array, .object: return []
            default: return [value]
            }
        case "values":
            if case .null = value { return [] }
            return [value]
        case "not":
            return [.bool(!value.isTruthy)]
        case "null": return [.null]
        case "true": return [.bool(true)]
        case "false": return [.bool(false)]
        case "empty": return []
        case "leaf_paths":
            return try pathBuiltin(value, "leaf_paths", [], JqContext()) ?? []
        default: return nil
        }
    }

    // MARK: - Math group

    // Math switch: one branch per jq math builtin.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func mathBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "fabs", "abs":
            switch value {
            case .number(let num): return [.number(abs(num))]
            case .string: return [value]
            default: return [.null]
            }
        case "exp10":
            if case .number(let num) = value { return [.number(pow(10.0, num))] }
            return [.null]
        case "exp2":
            if case .number(let num) = value { return [.number(pow(2.0, num))] }
            return [.null]
        case "pow":
            guard args.count == 2 else { return [.null] }
            let bases = try JqEvaluator.evalNode(value, args[0], ctx)
            let exps = try JqEvaluator.evalNode(value, args[1], ctx)
            guard case .number(let base) = bases.first ?? .null,
                  case .number(let exp) = exps.first ?? .null else { return [.null] }
            return [.number(pow(base, exp))]
        case "atan2":
            guard args.count == 2 else { return [.null] }
            let yVals = try JqEvaluator.evalNode(value, args[0], ctx)
            let xVals = try JqEvaluator.evalNode(value, args[1], ctx)
            guard case .number(let yVal) = yVals.first ?? .null,
                  case .number(let xVal) = xVals.first ?? .null else { return [.null] }
            return [.number(atan2(yVal, xVal))]
        case "logb":
            if case .number(let num) = value { return [.number(Foundation.log2(abs(num)).rounded(.down))] }
            return [.null]
        case "significand":
            if case .number(let num) = value {
                let exp = Foundation.log2(abs(num)).rounded(.down)
                return [.number(num / pow(2.0, exp))]
            }
            return [.null]
        case "frexp":
            if case .number(let num) = value {
                if num == 0 { return [.array([.number(0), .number(0)])] }
                let exp = Foundation.log2(abs(num)).rounded(.down) + 1
                let mantissa = num / pow(2.0, exp)
                return [.array([.number(mantissa), .number(exp)])]
            }
            return [.null]
        case "modf":
            if case .number(let num) = value {
                let intPart = num.rounded(.towardZero)
                return [.array([.number(num - intPart), .number(intPart)])]
            }
            return [.null]
        case "nearbyint":
            if case .number(let num) = value { return [.number(num.rounded())] }
            return [.null]
        default: return nil
        }
    }

    // MARK: - Date group — see JqBuiltins+Dates.swift

    // MARK: - List of builtins (for `builtins` builtin)

    static let builtinsList: [String] = [
        "add/0", "all/0", "all/1", "all/2", "any/0", "any/1", "any/2",
        "arrays/0", "ascii/0", "ascii_downcase/0", "ascii_upcase/0",
        "atan2/2", "atan/0", "booleans/0", "bsearch/1", "builtins/0",
        "capture/1", "capture/2", "ceil/0", "combinations/0", "combinations/1",
        "contains/1", "cos/0", "cosh/0", "debug/0", "del/1", "delpaths/1",
        "empty/0", "endswith/1", "env/0", "error/0", "error/1", "exp/0",
        "exp10/0", "exp2/0", "explode/0", "fabs/0", "false/0", "first/0",
        "first/1", "flatten/0", "flatten/1", "floor/0", "fromdate/0",
        "fromdateiso8601/0", "fromjson/0", "fromstream/1", "from_entries/0",
        "frexp/0", "getpath/1", "gmtime/0", "group_by/1", "gsub/2", "gsub/3",
        "halt/0", "halt_error/0", "halt_error/1", "has/1", "hypot/1",
        "implode/0", "IN/1", "IN/2", "INDEX/1", "INDEX/2", "in/1",
        "index/1", "indices/1", "infinite/0", "input/0", "inputs/0",
        "input_line_number/0", "inside/1", "isempty/1", "isfinite/0",
        "isinfinite/0", "isnan/0", "isnormal/0", "isvalid/1",
        "iterables/0", "join/1", "keys/0", "keys_unsorted/0", "last/0",
        "last/1", "leaf_paths/0", "length/0", "limit/2", "localtime/0",
        "log/0", "log10/0", "log2/0", "ltrim/0", "ltrimstr/1",
        "map/1", "map_values/1", "match/1", "match/2", "max/0", "max_by/1",
        "min/0", "min_by/1", "mktime/0", "modf/0", "nan/0", "nearbyint/0",
        "not/0", "now/0", "nth/1", "nth/2", "null/0", "nulls/0",
        "numbers/0", "objects/0", "parent/0", "parents/0", "path/1",
        "paths/0", "paths/1", "pick/1", "pow/2", "range/1", "range/2",
        "range/3", "recurse/0", "recurse/1", "recurse_down/0", "repeat/1",
        "reverse/0", "rindex/1", "root/0", "round/0", "rtrim/0",
        "rtrimstr/1", "scalars/0", "scan/1", "scan/2", "select/1",
        "setpath/2", "significand/0", "sin/0", "sinh/0", "skip/2",
        "sort/0", "sort_by/1", "split/1", "splits/1", "splits/2",
        "sqrt/0", "startswith/1", "stderr/0", "strftime/1", "strings/0",
        "strptime/1", "sub/2", "sub/3", "tan/0", "tanh/0", "test/1",
        "test/2", "to_entries/0", "toboolean/0", "todate/0",
        "todateiso8601/0", "tojson/0", "tonumber/0", "tostream/0",
        "tostring/0", "transpose/0", "trim/0", "true/0", "trimstr/1",
        "truncate_stream/1", "type/0", "unique/0", "unique_by/1",
        "until/2", "utf8bytelength/0", "values/0", "walk/1", "while/2",
        "with_entries/1"
    ]
}
