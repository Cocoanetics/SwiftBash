import Foundation

// Binary operator evaluation. Split into a short-circuit dispatch
// (evalBinary) and a per-operator value reducer (applyBinary).

extension JqEvaluator {

    static func evalBinary(_ value: JqValue, _ binOp: JqBinaryOp,
                           _ left: JqAST, _ right: JqAST,
                           _ ctx: JqContext) throws -> [JqValue] {
        // Short-circuit logical operators
        switch binOp {
        case .and:
            return try evalBoolReduce(value, left: left, right: right,
                                      stopOnTruthy: false, ctx: ctx)
        case .or:
            return try evalBoolReduce(value, left: left, right: right,
                                      stopOnTruthy: true, ctx: ctx)
        case .alt:
            let lefts = try evalNode(value, left, ctx)
            let nonNull = lefts.filter { item in
                if case .null = item { return false }
                if case .bool(false) = item { return false }
                return true
            }
            if !nonNull.isEmpty { return nonNull }
            return try evalNode(value, right, ctx)
        default:
            break
        }
        let lefts = try evalNode(value, left, ctx)
        let rights = try evalNode(value, right, ctx)
        var out: [JqValue] = []
        for leftVal in lefts {
            for rightVal in rights {
                out.append(try applyBinary(binOp, leftVal, rightVal))
            }
        }
        return out
    }

    private static func evalBoolReduce(_ value: JqValue,
                                       left: JqAST, right: JqAST,
                                       stopOnTruthy: Bool,
                                       ctx: JqContext) throws -> [JqValue] {
        let lefts = try evalNode(value, left, ctx)
        var out: [JqValue] = []
        for leftVal in lefts {
            if leftVal.isTruthy == stopOnTruthy {
                out.append(.bool(stopOnTruthy))
                continue
            }
            let rights = try evalNode(value, right, ctx)
            for rightVal in rights { out.append(.bool(rightVal.isTruthy)) }
        }
        return out
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func applyBinary(_ binOp: JqBinaryOp,
                            _ left: JqValue,
                            _ right: JqValue) throws -> JqValue {
        switch binOp {
        case .add: return try addValues(left, right)
        case .sub: return try subValues(left, right)
        case .mul: return try mulValues(left, right)
        case .div: return try divValues(left, right)
        case .mod: return try modValues(left, right)
        case .eq: return .bool(JqValue.jqEqual(left, right))
        case .ne: return .bool(!JqValue.jqEqual(left, right))
        case .lt: return .bool(JqValue.jqCompare(left, right) < 0)
        case .le: return .bool(JqValue.jqCompare(left, right) <= 0)
        case .gt: return .bool(JqValue.jqCompare(left, right) > 0)
        case .ge: return .bool(JqValue.jqCompare(left, right) >= 0)
        case .and, .or, .alt:
            return .null  // handled by evalBinary
        }
    }

    private static func addValues(_ left: JqValue, _ right: JqValue) throws -> JqValue {
        switch (left, right) {
        case (.null, _): return right
        case (_, .null): return left
        case (.number(let leftNum), .number(let rightNum)):
            return .number(leftNum + rightNum)
        case (.string(let leftStr), .string(let rightStr)):
            return .string(leftStr + rightStr)
        case (.array(let leftArr), .array(let rightArr)):
            return .array(leftArr + rightArr)
        case (.object(var leftObj), .object(let rightObj)):
            for (key, item) in rightObj { leftObj[key] = item }
            return .object(leftObj)
        default:
            throw JqError("\(left.typeName) and \(right.typeName) cannot be added")
        }
    }

    private static func subValues(_ left: JqValue, _ right: JqValue) throws -> JqValue {
        switch (left, right) {
        case (.number(let leftNum), .number(let rightNum)):
            return .number(leftNum - rightNum)
        case (.array(let leftArr), .array(let rightArr)):
            return .array(leftArr.filter { item in
                !rightArr.contains { JqValue.jqEqual($0, item) }
            })
        default:
            throw JqError("\(left.typeName) and \(right.typeName) cannot be subtracted")
        }
    }

    private static func mulValues(_ left: JqValue, _ right: JqValue) throws -> JqValue {
        switch (left, right) {
        case (.number(let leftNum), .number(let rightNum)):
            return .number(leftNum * rightNum)
        case (.string(let leftStr), .number(let rightNum)):
            if rightNum.isNaN || rightNum <= 0 { return .null }
            return .string(String(repeating: leftStr, count: Int(rightNum)))
        case (.string(let leftStr), .string(let rightStr)):
            // jq's "splat join" semantics: split a by b
            return .array(leftStr.components(separatedBy: rightStr).map { .string($0) })
        case (.null, _), (_, .null): return .null
        case (.object(let leftObj), .object(let rightObj)):
            return .object(deepMerge(leftObj, rightObj))
        default:
            throw JqError("\(left.typeName) and \(right.typeName) cannot be multiplied")
        }
    }

    private static func divValues(_ left: JqValue, _ right: JqValue) throws -> JqValue {
        switch (left, right) {
        case (.number(let leftNum), .number(let rightNum)):
            if rightNum == 0 {
                let leftStr = JqValue.formatDouble(leftNum)
                let rightStr = JqValue.formatDouble(rightNum)
                throw JqError("number (\(leftStr)) and number (\(rightStr)) "
                              + "cannot be divided because the divisor is zero")
            }
            return .number(leftNum / rightNum)
        case (.string(let leftStr), .string(let rightStr)):
            if rightStr.isEmpty { return .array([]) }
            return .array(leftStr.components(separatedBy: rightStr).map { .string($0) })
        default:
            throw JqError("\(left.typeName) and \(right.typeName) cannot be divided")
        }
    }

    private static func modValues(_ left: JqValue, _ right: JqValue) throws -> JqValue {
        switch (left, right) {
        case (.number(let leftNum), .number(let rightNum)):
            if rightNum == 0 {
                let leftStr = JqValue.formatDouble(leftNum)
                let rightStr = JqValue.formatDouble(rightNum)
                throw JqError("number (\(leftStr)) and number (\(rightStr)) "
                              + "cannot be divided (remainder) because the divisor is zero")
            }
            let remainder = Int(leftNum).quotientAndRemainder(dividingBy: Int(rightNum)).remainder
            return .number(Double(remainder))
        default:
            throw JqError("\(left.typeName) and \(right.typeName) cannot be divided (mod)")
        }
    }

    static func deepMerge(_ left: JqObject, _ right: JqObject) -> JqObject {
        var result = left
        for (key, item) in right {
            if let existing = result[key],
               case .object(let leftInner) = existing,
               case .object(let rightInner) = item {
                result[key] = .object(deepMerge(leftInner, rightInner))
            } else {
                result[key] = item
            }
        }
        return result
    }
}
