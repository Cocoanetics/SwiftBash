import Foundation

// Date-related jq builtins. Split from `JqBuiltins.swift` to keep that
// file under SwiftLint's 1000-line limit without sacrificing the
// dispatch-table layout the rest of the builtins share.
extension JqBuiltins {

    // Date switch: branch per jq date builtin (strftime/strptime/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func dateBuiltin(_ value: JqValue, _ name: String,
                            _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "now":
            return [.number(Date().timeIntervalSince1970)]
        case "gmtime":
            guard case .number(let timeInterval) = value else { return [.null] }
            let date = Date(timeIntervalSince1970: timeInterval)
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
            let weekday = (comps.weekday ?? 1) - 1
            let yearday = computeDayOfYear(comps)
            return [.array([
                .number(Double(comps.year ?? 1970)),
                .number(Double((comps.month ?? 1) - 1)),
                .number(Double(comps.day ?? 1)),
                .number(Double(comps.hour ?? 0)),
                .number(Double(comps.minute ?? 0)),
                .number(Double(comps.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday))
            ])]
        case "mktime":
            guard case .array(let parts) = value, parts.count >= 6 else {
                throw JqError("mktime requires parsed datetime inputs")
            }
            var comps = DateComponents()
            comps.timeZone = TimeZone(identifier: "UTC")
            if case .number(let num) = parts[0] { comps.year = Int(num) }
            if case .number(let num) = parts[1] { comps.month = Int(num) + 1 }
            if case .number(let num) = parts[2] { comps.day = Int(num) }
            if case .number(let num) = parts[3] { comps.hour = Int(num) }
            if case .number(let num) = parts[4] { comps.minute = Int(num) }
            if case .number(let num) = parts[5] { comps.second = Int(num) }
            let cal = Calendar(identifier: .gregorian)
            guard let date = cal.date(from: comps) else { throw JqError("invalid time") }
            return [.number(date.timeIntervalSince1970)]
        case "strftime":
            guard !args.isEmpty else { return [.null] }
            let fmts = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let fmt) = fmts.first ?? .null else {
                throw JqError("strftime requires a string format")
            }
            let date: Date
            switch value {
            case .number(let timeInterval): date = Date(timeIntervalSince1970: timeInterval)
            case .array(let parts) where parts.count >= 6:
                var comps = DateComponents()
                comps.timeZone = TimeZone(identifier: "UTC")
                if case .number(let num) = parts[0] { comps.year = Int(num) }
                if case .number(let num) = parts[1] { comps.month = Int(num) + 1 }
                if case .number(let num) = parts[2] { comps.day = Int(num) }
                if case .number(let num) = parts[3] { comps.hour = Int(num) }
                if case .number(let num) = parts[4] { comps.minute = Int(num) }
                if case .number(let num) = parts[5] { comps.second = Int(num) }
                guard let made = Calendar(identifier: .gregorian).date(from: comps) else {
                    throw JqError("invalid time")
                }
                date = made
            default:
                throw JqError("strftime requires parsed datetime inputs")
            }
            return [.string(formatDate(date, fmt))]
        case "strptime":
            guard !args.isEmpty, case .string(let text) = value else {
                throw JqError("strptime requires a string input")
            }
            let fmts = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let fmt) = fmts.first ?? .null else {
                throw JqError("strptime requires a string format")
            }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = strftimeToICU(fmt)
            guard let date = formatter.date(from: text) else {
                throw JqError("date \"\(text)\" does not match format \"\(fmt)\"")
            }
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
            let weekday = (comps.weekday ?? 1) - 1
            let yearday = computeDayOfYear(comps)
            return [.array([
                .number(Double(comps.year ?? 1970)),
                .number(Double((comps.month ?? 1) - 1)),
                .number(Double(comps.day ?? 1)),
                .number(Double(comps.hour ?? 0)),
                .number(Double(comps.minute ?? 0)),
                .number(Double(comps.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday))
            ])]
        case "fromdate", "fromdateiso8601":
            guard case .string(let text) = value else {
                throw JqError("fromdate requires a string input")
            }
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: text) else {
                throw JqError("date \"\(text)\" does not match format")
            }
            return [.number(date.timeIntervalSince1970)]
        case "todate", "todateiso8601":
            guard case .number(let timeInterval) = value else {
                throw JqError("todate requires a number input")
            }
            let formatter = ISO8601DateFormatter()
            return [.string(formatter.string(from: Date(timeIntervalSince1970: timeInterval)))]
        case "localtime":
            guard case .number(let timeInterval) = value else { return [.null] }
            let date = Date(timeIntervalSince1970: timeInterval)
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: .current, from: date)
            let weekday = (comps.weekday ?? 1) - 1
            let yearday = computeDayOfYear(comps)
            return [.array([
                .number(Double(comps.year ?? 1970)),
                .number(Double((comps.month ?? 1) - 1)),
                .number(Double(comps.day ?? 1)),
                .number(Double(comps.hour ?? 0)),
                .number(Double(comps.minute ?? 0)),
                .number(Double(comps.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday))
            ])]
        default: return nil
        }
    }

    /// 0-based day of year. Pre-macOS 15 we don't have
    /// `DateComponents.dayOfYear` — compute it from year+month+day.
    static func computeDayOfYear(_ comps: DateComponents) -> Int {
        guard let year = comps.year,
              let month = comps.month,
              let day = comps.day else { return 0 }
        let daysBefore = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        var doy = daysBefore[max(0, min(11, month - 1))] + day - 1
        if month > 2 && isLeap(year) { doy += 1 }
        return doy
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    // strftime → ICU has one mapping branch per %-conversion.
    // swiftlint:disable:next cyclomatic_complexity
    static func strftimeToICU(_ fmt: String) -> String {
        var out = ""
        var cursor = fmt.startIndex
        while cursor < fmt.endIndex {
            let char = fmt[cursor]
            if char == "%" {
                cursor = fmt.index(after: cursor)
                if cursor >= fmt.endIndex { break }
                switch fmt[cursor] {
                case "Y": out += "yyyy"
                case "m": out += "MM"
                case "d": out += "dd"
                case "H": out += "HH"
                case "M": out += "mm"
                case "S": out += "ss"
                case "Z": out += "zzz"
                case "%": out += "%"
                default: out.append(fmt[cursor])
                }
                cursor = fmt.index(after: cursor)
            } else {
                if char.isLetter { out += "'\(char)'" } else { out.append(char) }
                cursor = fmt.index(after: cursor)
            }
        }
        return out
    }

    // formatDate handles all strftime conversions in one pass.
    // swiftlint:disable:next cyclomatic_complexity
    static func formatDate(_ date: Date, _ fmt: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE"
        let dayName = formatter.string(from: date)
        formatter.dateFormat = "MMMM"
        let monthName = formatter.string(from: date)
        var out = ""
        var cursor = fmt.startIndex
        while cursor < fmt.endIndex {
            let char = fmt[cursor]
            if char == "%" {
                cursor = fmt.index(after: cursor)
                if cursor >= fmt.endIndex { break }
                switch fmt[cursor] {
                case "Y": out += String(format: "%04d", comps.year ?? 1970)
                case "m": out += String(format: "%02d", comps.month ?? 1)
                case "d": out += String(format: "%02d", comps.day ?? 1)
                case "H": out += String(format: "%02d", comps.hour ?? 0)
                case "M": out += String(format: "%02d", comps.minute ?? 0)
                case "S": out += String(format: "%02d", comps.second ?? 0)
                case "A": out += dayName
                case "B": out += monthName
                case "Z": out += "UTC"
                case "%": out += "%"
                default: out.append(fmt[cursor])
                }
                cursor = fmt.index(after: cursor)
            } else {
                out.append(char)
                cursor = fmt.index(after: cursor)
            }
        }
        _ = comps
        return out
    }
}
