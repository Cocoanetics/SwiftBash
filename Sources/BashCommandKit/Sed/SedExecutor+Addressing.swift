import Foundation

extension SedExecutor {

    func addressOf(_ cmd: SedCommandNode) -> SedAddressRange? {
        switch cmd {
        case .substitute(let range, _, _, _, _, _, _, _, _): return range
        case .print(let range), .printFirstLine(let range), .delete(let range),
             .deleteFirstLine(let range), .hold(let range), .holdAppend(let range),
             .get(let range), .getAppend(let range), .exchange(let range),
             .quit(let range), .quitSilent(let range), .lineNumber(let range),
             .zap(let range), .list(let range), .printFilename(let range):
            return range
        case .append(let range, _), .insert(let range, _), .change(let range, _):
            return range
        case .transliterate(let range, _, _): return range
        case .readFile(let range, _), .readFileLine(let range, _),
             .writeFile(let range, _), .writeFirstLine(let range, _):
            return range
        case .execute(let range, _): return range
        case .version(let range, _): return range
        // already inspected in execute()
        case .next(let range), .nextAppend(let range),
             .branch(let range, _), .branchOnSubst(let range, _), .branchOnNoSubst(let range, _),
             .group(let range, _):
            return range
        case .label:
            return nil
        }
    }

    func matches(range: SedAddressRange,
                 state: inout SedRunState,
                 rangeStates: inout [String: SedRangeState]) -> Bool {
        let result = matchesRaw(range: range, state: &state, rangeStates: &rangeStates)
        return range.negated ? !result : result
    }

    // Pure dispatch over numeric vs pattern address ranges with
    // per-range bookkeeping. Splitting per-arm helpers would scatter
    // the inherently coupled `rangeStates` reads/writes.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func matchesRaw(range: SedAddressRange,
                    state: inout SedRunState,
                    rangeStates: inout [String: SedRangeState]) -> Bool {
        if range.start == nil && range.end == nil { return true }
        guard let start = range.start else { return true }
        if range.end == nil {
            return matchAddress(start, state: &state)
        }
        let end = range.end!
        let key = serialize(range)
        if case .relative(let off) = end {
            var rangeState = rangeStates[key] ?? SedRangeState()
            if !rangeState.active {
                if matchAddress(start, state: &state) {
                    rangeState.active = true
                    rangeState.startLine = state.lineNumber
                    if off == 0 { rangeState.active = false }
                    rangeStates[key] = rangeState
                    return true
                }
                rangeStates[key] = rangeState
                return false
            } else {
                if state.lineNumber >= rangeState.startLine + off {
                    rangeState.active = false
                    rangeStates[key] = rangeState
                }
                return true
            }
        }

        let startIsPattern: Bool = { if case .regex = start { return true } else { return false } }()
        let endIsPattern: Bool = { if case .regex = end { return true } else { return false } }()

        // Pure-numeric range: handle backward via state.
        if !startIsPattern && !endIsPattern {
            let startN = numericAddress(start, state: state)
            let endN = numericAddress(end, state: state)
            if startN <= endN {
                return state.lineNumber >= startN && state.lineNumber <= endN
            }
            // Backward: GNU behaviour.
            var rangeState = rangeStates[key] ?? SedRangeState()
            if !rangeState.completed {
                if state.lineNumber >= startN {
                    rangeState.completed = true
                    rangeStates[key] = rangeState
                    return true
                }
            }
            return false
        }

        // Pattern range: tracked with state.
        var rangeState = rangeStates[key] ?? SedRangeState()
        if !rangeState.active {
            if rangeState.completed { return false }
            var startMatches = false
            if case .line(let lineNo) = start {
                startMatches = state.lineNumber >= lineNo
            } else {
                startMatches = matchAddress(start, state: &state)
            }
            if startMatches {
                rangeState.active = true
                rangeState.startLine = state.lineNumber
                rangeStates[key] = rangeState
                if matchAddress(end, state: &state) {
                    rangeState.active = false
                    if case .line = start { rangeState.completed = true }
                    rangeStates[key] = rangeState
                }
                return true
            }
            return false
        } else {
            if matchAddress(end, state: &state) {
                rangeState.active = false
                if case .line = start { rangeState.completed = true }
                rangeStates[key] = rangeState
            }
            return true
        }
    }

    func numericAddress(_ address: SedAddress, state: SedRunState) -> Int {
        switch address {
        case .line(let lineNo): return lineNo
        case .last: return state.totalLines
        case .step(let first, let step):
            // Treat as numeric "first"; not part of typical num,num
            // ranges but harmless.
            return step == 0 ? first : first
        case .relative: return state.totalLines
        case .regex: return state.totalLines
        }
    }

    func matchAddress(_ address: SedAddress, state: inout SedRunState) -> Bool {
        switch address {
        case .line(let lineNo): return state.lineNumber == lineNo
        case .last: return state.lineNumber == state.totalLines
        case .step(let first, let step):
            if step == 0 { return state.lineNumber == first }
            return state.lineNumber >= first && (state.lineNumber - first) % step == 0
        case .regex(var pat):
            if pat.isEmpty, let last = state.lastPattern {
                pat = last
            } else if !pat.isEmpty {
                state.lastPattern = pat
            }
            guard let regex = try? SedRegex.compile(pat, extendedRegex: false) else { return false }
            let nsstr = state.patternSpace as NSString
            return regex.firstMatch(in: state.patternSpace,
                                    range: NSRange(location: 0, length: nsstr.length)) != nil
        case .relative:
            return false  // only valid as range end
        }
    }

    func serialize(_ range: SedAddressRange) -> String {
        func ser(_ address: SedAddress?) -> String {
            guard let address else { return "_" }
            switch address {
            case .line(let lineNo): return "L\(lineNo)"
            case .last: return "$"
            case .regex(let pat): return "/\(pat)/"
            case .step(let first, let step): return "S\(first)~\(step)"
            case .relative(let off): return "+\(off)"
            }
        }
        return "\(ser(range.start)),\(ser(range.end))"
    }
}
