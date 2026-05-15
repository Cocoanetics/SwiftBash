import Foundation

// Indexing, slicing, and object-construction helpers used by the
// per-case dispatch in JqEvaluator.

extension JqEvaluator {

    static func indexInto(_ baseVal: JqValue, _ idx: JqValue) throws -> JqValue {
        switch (baseVal, idx) {
        case (.null, _): return .null
        case (.array(let arr), .number(let num)):
            if num.isNaN { return .null }
            let pos = Int(num.rounded(.towardZero))
            let real = pos < 0 ? arr.count + pos : pos
            return real >= 0 && real < arr.count ? arr[real] : .null
        case (.object(let obj), .string(let key)):
            return obj[key] ?? .null
        case (.array, _):
            throw JqError("Cannot index array with \(idx.typeName)")
        case (.object, _):
            throw JqError("Cannot index object with \(idx.typeName)")
        default:
            throw JqError("Cannot index \(baseVal.typeName) with \(idx.typeName)")
        }
    }

    static func sliceValue(_ baseVal: JqValue,
                           _ startVal: JqValue,
                           _ endVal: JqValue,
                           length: Int) throws -> JqValue {
        let sNum: Double
        if case .number(let num) = startVal {
            sNum = num.isNaN ? 0 : num
        } else if case .null = startVal {
            sNum = 0
        } else {
            throw JqError("Slice bound is not a number")
        }
        let eNum: Double
        if case .number(let num) = endVal {
            eNum = num.isNaN ? Double(length) : num
        } else if case .null = endVal {
            eNum = Double(length)
        } else {
            throw JqError("Slice bound is not a number")
        }
        let startRaw = sNum.rounded(.down)
        let endRaw = eNum.rounded(.up)
        let start = normalize(Int(startRaw), len: length)
        let end = normalize(Int(endRaw), len: length)
        switch baseVal {
        case .array(let arr):
            if start >= end { return .array([]) }
            return .array(Array(arr[start..<end]))
        case .string(let str):
            let chars = Array(str)
            if start >= end { return .string("") }
            return .string(String(chars[start..<end]))
        default:
            throw JqError("Cannot slice \(baseVal.typeName)")
        }
    }

    static func normalize(_ idx: Int, len: Int) -> Int {
        var pos = idx
        if pos < 0 { pos = max(0, len + pos) }
        return min(max(pos, 0), len)
    }

    static func evalObject(_ value: JqValue,
                           _ entries: [JqObjectEntry],
                           _ ctx: JqContext) throws -> [JqValue] {
        var results: [JqObject] = [JqObject()]
        for entry in entries {
            let keys: [String]
            switch entry.key {
            case .literal(let str): keys = [str]
            case .computed(let expr):
                let keyVals = try evalNode(value, expr, ctx)
                var out: [String] = []
                for key in keyVals {
                    guard case .string(let str) = key else {
                        throw JqError("Object key must be a string")
                    }
                    out.append(str)
                }
                keys = out
            }
            let values = try evalNode(value, entry.value, ctx)
            var newResults: [JqObject] = []
            for partial in results {
                for key in keys {
                    for item in values {
                        var next = partial
                        next[key] = item
                        newResults.append(next)
                    }
                }
            }
            results = newResults
        }
        return results.map { .object($0) }
    }
}
