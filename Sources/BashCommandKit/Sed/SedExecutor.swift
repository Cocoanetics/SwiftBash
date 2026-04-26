import Foundation

/// Runs a parsed sed script over a buffered input. Designed to be
/// stateless across instances — the caller drives the loop and feeds
/// the lines; we mutate ``SedRunState`` (passed by reference) to
/// preserve hold space, range membership, and other persistent state
/// across cycles.
final class SedExecutor {

    let commands: [SedCommandNode]
    let silent: Bool
    let limits: SedExecutionLimits
    let filename: String?

    /// Cumulative pending file-write contents, flushed after the run.
    var pendingFileWrites: [String: String] = [:]

    init(commands: [SedCommandNode], silent: Bool,
         limits: SedExecutionLimits = SedExecutionLimits(),
         filename: String? = nil) {
        self.commands = commands
        self.silent = silent
        self.limits = limits
        self.filename = filename
    }

    /// Run the script over `lines` (already split by `\n`). Returns the
    /// concatenated stdout output and an optional exit code (set by `q`
    /// / `Q` / `v` failure).
    func run(lines: [String], inputEndsWithNewline: Bool,
             readFile: (String) throws -> String) -> RunResult {
        var output = ""
        var lastWasAutoPrint = false
        var exitCode: Int32? = nil
        var holdSpace = ""
        var lastPattern: String? = nil
        var rangeStates: [String: SedRangeState] = [:]
        var fileLineCache: [String: [String]] = [:]
        var fileLinePos: [String: Int] = [:]

        var lineIndex = 0
        outer: while lineIndex < lines.count {
            var state = SedRunState()
            state.patternSpace = lines[lineIndex]
            state.holdSpace = holdSpace
            state.lastPattern = lastPattern
            state.lineNumber = lineIndex + 1
            state.totalLines = lines.count

            var cycleIters = 0
            repeat {
                cycleIters += 1
                if cycleIters > 10_000 { break }
                state.restartCycle = false
                state.pendingFileReads.removeAll()
                state.pendingFileWrites.removeAll()
                _ = execute(commands, state: &state, lines: lines,
                            currentLineIndex: lineIndex,
                            rangeStates: &rangeStates)
                // Pending file reads
                for read in state.pendingFileReads {
                    do {
                        if read.wholeFile {
                            var content = try readFile(read.filename)
                            if content.hasSuffix("\n") { content.removeLast() }
                            state.appendBuffer.append(.append(content))
                        } else {
                            if fileLineCache[read.filename] == nil {
                                let raw = try readFile(read.filename)
                                fileLineCache[read.filename] = SedExecutor.splitLines(raw)
                                fileLinePos[read.filename] = 0
                            }
                            let p = fileLinePos[read.filename] ?? 0
                            let lns = fileLineCache[read.filename] ?? []
                            if p < lns.count {
                                state.appendBuffer.append(.append(lns[p]))
                                fileLinePos[read.filename] = p + 1
                            }
                        }
                    } catch {
                        // Silently ignore — matches GNU sed behaviour.
                    }
                }
                for write in state.pendingFileWrites {
                    pendingFileWrites[write.filename, default: ""] += write.content
                }
            } while state.restartCycle && !state.deleted && !state.quit && !state.quitSilent

            lineIndex += state.linesConsumedInCycle
            holdSpace = state.holdSpace
            lastPattern = state.lastPattern

            // n command output (respects silent mode)
            if !silent {
                for ln in state.nCommandOutput { output += ln + "\n" }
            }

            // = / l / F / p outputs
            let hadExplicit = !state.lineNumberOutput.isEmpty
            for ln in state.lineNumberOutput { output += ln + "\n" }

            var inserts: [String] = []
            var appends: [String] = []
            for item in state.appendBuffer {
                switch item {
                case .insert(let t): inserts.append(t)
                case .append(let t): appends.append(t)
                }
            }
            for t in inserts { output += t + "\n" }

            var hadPatternSpaceOutput = false
            if !state.deleted && !state.quitSilent {
                if silent {
                    if state.printed {
                        output += state.patternSpace + "\n"
                        hadPatternSpaceOutput = true
                    }
                } else {
                    output += state.patternSpace + "\n"
                    hadPatternSpaceOutput = true
                }
            } else if let changed = state.changedText {
                output += changed + "\n"
                hadPatternSpaceOutput = true
            }

            for t in appends { output += t + "\n" }
            lastWasAutoPrint = (hadExplicit || hadPatternSpaceOutput) && appends.isEmpty

            if let err = state.errorMessage {
                return RunResult(output: "", exitCode: Int32(state.exitCode ?? 1),
                                 errorMessage: err)
            }
            if state.quit || state.quitSilent {
                if let c = state.exitCode { exitCode = Int32(c) }
                break outer
            }

            lineIndex += 1
        }

        if !inputEndsWithNewline && lastWasAutoPrint && output.hasSuffix("\n") {
            output.removeLast()
        }
        return RunResult(output: output, exitCode: exitCode, errorMessage: nil)
    }

    struct RunResult {
        let output: String
        let exitCode: Int32?
        let errorMessage: String?
    }

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - Command execution

    /// Returns whether a branch request crossed our scope (the caller
    /// — usually the enclosing group — needs to honour it).
    @discardableResult
    private func execute(_ cmds: [SedCommandNode],
                         state: inout SedRunState,
                         lines: [String],
                         currentLineIndex: Int,
                         rangeStates: inout [String: SedRangeState]) -> Bool {
        // Build label index for THIS scope.
        var labels: [String: Int] = [:]
        for (i, c) in cmds.enumerated() {
            if case .label(let n) = c { labels[n] = i }
        }
        var i = 0
        var iterations = 0
        while i < cmds.count {
            iterations += 1
            if iterations > limits.maxIterations {
                state.errorMessage = "sed: command execution exceeded maximum iterations (\(limits.maxIterations))"
                state.quit = true
                return false
            }
            if state.deleted || state.quit || state.quitSilent || state.restartCycle { break }
            let cmd = cmds[i]

            // n / N / branches / group must be inspected here because
            // they affect the cycle's control flow.
            switch cmd {
            case .label:
                i += 1; continue
            case .next(let r):
                if matches(range: r, state: &state, rangeStates: &rangeStates) {
                    state.nCommandOutput.append(state.patternSpace)
                    let nextIdx = currentLineIndex + state.linesConsumedInCycle + 1
                    if nextIdx < lines.count {
                        state.linesConsumedInCycle += 1
                        state.patternSpace = lines[nextIdx]
                        state.lineNumber = nextIdx + 1
                        state.substitutionMade = false
                    } else {
                        state.quit = true; state.deleted = true; break
                    }
                }
                i += 1; continue
            case .nextAppend(let r):
                if matches(range: r, state: &state, rangeStates: &rangeStates) {
                    let nextIdx = currentLineIndex + state.linesConsumedInCycle + 1
                    if nextIdx < lines.count {
                        state.linesConsumedInCycle += 1
                        state.patternSpace += "\n" + lines[nextIdx]
                        state.lineNumber = nextIdx + 1
                    } else {
                        state.quit = true; break
                    }
                }
                i += 1; continue
            case .branch(let r, let label):
                if matches(range: r, state: &state, rangeStates: &rangeStates) {
                    if let lbl = label {
                        if let target = labels[lbl] { i = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false  // jump to end of THIS scope (script or group)
                }
                i += 1; continue
            case .branchOnSubst(let r, let label):
                if matches(range: r, state: &state, rangeStates: &rangeStates),
                   state.substitutionMade {
                    state.substitutionMade = false
                    if let lbl = label {
                        if let target = labels[lbl] { i = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false
                }
                i += 1; continue
            case .branchOnNoSubst(let r, let label):
                if matches(range: r, state: &state, rangeStates: &rangeStates),
                   !state.substitutionMade {
                    if let lbl = label {
                        if let target = labels[lbl] { i = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false
                }
                i += 1; continue
            case .group(let r, let inner):
                if matches(range: r, state: &state, rangeStates: &rangeStates) {
                    let propagated = execute(inner, state: &state, lines: lines,
                                             currentLineIndex: currentLineIndex,
                                             rangeStates: &rangeStates)
                    if propagated, let lbl = state.branchRequest {
                        if let target = labels[lbl] {
                            state.branchRequest = nil
                            i = target
                            continue
                        }
                        return true
                    }
                }
                i += 1; continue
            default:
                break
            }

            executeOne(cmd, state: &state, rangeStates: &rangeStates)
            i += 1
        }
        return false
    }

    private func executeOne(_ cmd: SedCommandNode,
                            state: inout SedRunState,
                            rangeStates: inout [String: SedRangeState]) {
        // For commands carrying an addressed range, gate execution.
        if let r = addressOf(cmd), !matches(range: r, state: &state, rangeStates: &rangeStates) {
            return
        }
        switch cmd {
        case .substitute(_, let pattern, let replacement, let global, let ignoreCase,
                         let printOnMatch, let nth, let extendedRegex, let writeFile):
            applySubstitute(pattern: pattern, replacement: replacement,
                            global: global, ignoreCase: ignoreCase,
                            printOnMatch: printOnMatch, nth: nth,
                            extendedRegex: extendedRegex,
                            writeFile: writeFile, state: &state)
        case .print:
            state.lineNumberOutput.append(state.patternSpace)
        case .printFirstLine:
            if let nl = state.patternSpace.firstIndex(of: "\n") {
                state.lineNumberOutput.append(String(state.patternSpace[..<nl]))
            } else {
                state.lineNumberOutput.append(state.patternSpace)
            }
        case .delete:
            state.deleted = true
        case .deleteFirstLine:
            if let nl = state.patternSpace.firstIndex(of: "\n") {
                state.patternSpace = String(state.patternSpace[state.patternSpace.index(after: nl)...])
                state.restartCycle = true
            } else {
                state.deleted = true
            }
        case .zap:
            state.patternSpace = ""
        case .append(_, let text):
            state.appendBuffer.append(.append(text))
        case .insert(_, let text):
            state.appendBuffer.append(.insert(text))
        case .change(_, let text):
            // c: drop pattern space, output `text` in its place.
            // For ranges, GNU sed only prints the text on the last
            // line of the range; we approximate by always replacing.
            state.deleted = true
            state.changedText = text
        case .hold:
            state.holdSpace = state.patternSpace
        case .holdAppend:
            if state.holdSpace.isEmpty { state.holdSpace = state.patternSpace }
            else { state.holdSpace += "\n" + state.patternSpace }
        case .get:
            state.patternSpace = state.holdSpace
        case .getAppend:
            state.patternSpace += "\n" + state.holdSpace
        case .exchange:
            let tmp = state.patternSpace
            state.patternSpace = state.holdSpace
            state.holdSpace = tmp
        case .quit:
            state.quit = true
        case .quitSilent:
            state.quit = true
            state.quitSilent = true
        case .lineNumber:
            state.lineNumberOutput.append(String(state.lineNumber))
        case .list:
            state.lineNumberOutput.append(SedRegex.escapeForList(state.patternSpace))
        case .printFilename:
            if let f = filename { state.lineNumberOutput.append(f) }
        case .version(_, let minVersion):
            // We claim 4.8.0
            let ours = [4, 8, 0]
            if let v = minVersion {
                let parts = v.split(separator: ".").map { Int($0) ?? -1 }
                if parts.contains(where: { $0 < 0 }) {
                    state.errorMessage = "sed: invalid version string: \(v)"
                    state.quit = true; state.exitCode = 1
                } else {
                    var padded = parts
                    while padded.count < 3 { padded.append(0) }
                    for i in 0..<3 {
                        if padded[i] > ours[i] {
                            state.errorMessage = "sed: this is not GNU sed version \(v)"
                            state.quit = true; state.exitCode = 1
                            break
                        }
                        if padded[i] < ours[i] { break }
                    }
                }
            }
        case .transliterate(_, let source, let dest):
            state.patternSpace = transliterate(state.patternSpace, source: source, dest: dest)
        case .readFile(_, let filename):
            state.pendingFileReads.append(.init(filename: filename, wholeFile: true))
        case .readFileLine(_, let filename):
            state.pendingFileReads.append(.init(filename: filename, wholeFile: false))
        case .writeFile(_, let filename):
            state.pendingFileWrites.append(.init(filename: filename,
                                                content: state.patternSpace + "\n"))
        case .writeFirstLine(_, let filename):
            let first: String
            if let nl = state.patternSpace.firstIndex(of: "\n") {
                first = String(state.patternSpace[..<nl])
            } else {
                first = state.patternSpace
            }
            state.pendingFileWrites.append(.init(filename: filename, content: first + "\n"))
        case .execute:
            state.errorMessage = "sed: e command (shell execution) is not supported"
            state.quit = true
        case .label, .next, .nextAppend, .branch, .branchOnSubst, .branchOnNoSubst, .group:
            break  // already handled
        }
    }

    // MARK: - Substitute

    private func applySubstitute(pattern: String, replacement: String,
                                 global: Bool, ignoreCase: Bool,
                                 printOnMatch: Bool, nth: Int?,
                                 extendedRegex: Bool, writeFile: String?,
                                 state: inout SedRunState) {
        var raw = pattern
        if raw.isEmpty, let last = state.lastPattern {
            raw = last
        } else if !raw.isEmpty {
            state.lastPattern = raw
        }
        guard let regex = try? SedRegex.compile(raw, extendedRegex: extendedRegex,
                                                ignoreCase: ignoreCase) else {
            return
        }
        let nsstr = state.patternSpace as NSString
        let fullRange = NSRange(location: 0, length: nsstr.length)
        let matches = regex.matches(in: state.patternSpace, range: fullRange)
        if matches.isEmpty { return }
        state.substitutionMade = true

        var result = ""
        var pos = 0
        var matchCount = 0
        var didReplace = false
        for m in matches {
            matchCount += 1
            // Append the unmatched gap.
            if m.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: m.range.location - pos))
            }
            let shouldReplace: Bool
            if let n = nth, !global {
                shouldReplace = matchCount == n
            } else if !global && didReplace {
                shouldReplace = false
            } else {
                shouldReplace = true
            }
            if shouldReplace {
                let replaced = expandReplacement(replacement, match: m, in: state.patternSpace)
                result += replaced
                didReplace = true
            } else {
                result += nsstr.substring(with: m.range)
            }
            pos = m.range.location + m.range.length
            if !global, didReplace, nth == nil { break }
        }
        // Tail
        if pos < nsstr.length {
            result += nsstr.substring(from: pos)
        }
        state.patternSpace = result
        if printOnMatch {
            state.lineNumberOutput.append(state.patternSpace)
        }
        if let wf = writeFile {
            state.pendingFileWrites.append(.init(filename: wf, content: state.patternSpace + "\n"))
        }
    }

    /// Expand sed's replacement syntax into the literal output:
    /// `&` and `\0` → whole match, `\1`..`\9` → groups, `\n/\t/\r`
    /// → control chars, `\\` → `\`, other `\X` → `X`.
    private func expandReplacement(_ rep: String, match: NSTextCheckingResult, in source: String) -> String {
        let nsstr = source as NSString
        var out = ""
        let chars = Array(rep)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "&" { out += "&"; i += 2; continue }
                if n == "n" { out += "\n"; i += 2; continue }
                if n == "t" { out += "\t"; i += 2; continue }
                if n == "r" { out += "\r"; i += 2; continue }
                if n == "\\" { out += "\\"; i += 2; continue }
                if let d = n.asciiValue, d >= 0x30, d <= 0x39 {
                    let idx = Int(d - 0x30)
                    if idx == 0 {
                        out += nsstr.substring(with: match.range)
                    } else if idx < match.numberOfRanges {
                        let r = match.range(at: idx)
                        if r.location != NSNotFound {
                            out += nsstr.substring(with: r)
                        }
                    }
                    i += 2
                    continue
                }
                out.append(n); i += 2; continue
            }
            if c == "&" {
                out += nsstr.substring(with: match.range); i += 1; continue
            }
            out.append(c); i += 1
        }
        return out
    }

    // MARK: - Transliterate

    private func transliterate(_ input: String, source: String, dest: String) -> String {
        let src = Array(source)
        let dst = Array(dest)
        var out = ""
        for c in input {
            if let i = src.firstIndex(of: c), i < dst.count {
                out.append(dst[i])
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Address matching

    private func addressOf(_ cmd: SedCommandNode) -> SedAddressRange? {
        switch cmd {
        case .substitute(let r, _, _, _, _, _, _, _, _): return r
        case .print(let r), .printFirstLine(let r), .delete(let r),
             .deleteFirstLine(let r), .hold(let r), .holdAppend(let r),
             .get(let r), .getAppend(let r), .exchange(let r),
             .quit(let r), .quitSilent(let r), .lineNumber(let r),
             .zap(let r), .list(let r), .printFilename(let r):
            return r
        case .append(let r, _), .insert(let r, _), .change(let r, _):
            return r
        case .transliterate(let r, _, _): return r
        case .readFile(let r, _), .readFileLine(let r, _),
             .writeFile(let r, _), .writeFirstLine(let r, _):
            return r
        case .execute(let r, _): return r
        case .version(let r, _): return r
        // already inspected in execute()
        case .next(let r), .nextAppend(let r),
             .branch(let r, _), .branchOnSubst(let r, _), .branchOnNoSubst(let r, _),
             .group(let r, _):
            return r
        case .label:
            return nil
        }
    }

    private func matches(range r: SedAddressRange,
                         state: inout SedRunState,
                         rangeStates: inout [String: SedRangeState]) -> Bool {
        let result = matchesRaw(range: r, state: &state, rangeStates: &rangeStates)
        return r.negated ? !result : result
    }

    private func matchesRaw(range r: SedAddressRange,
                            state: inout SedRunState,
                            rangeStates: inout [String: SedRangeState]) -> Bool {
        if r.start == nil && r.end == nil { return true }
        guard let start = r.start else { return true }
        if r.end == nil {
            return matchAddress(start, state: &state)
        }
        let end = r.end!
        let key = serialize(r)
        if case .relative(let off) = end {
            var rs = rangeStates[key] ?? SedRangeState()
            if !rs.active {
                if matchAddress(start, state: &state) {
                    rs.active = true
                    rs.startLine = state.lineNumber
                    if off == 0 { rs.active = false }
                    rangeStates[key] = rs
                    return true
                }
                rangeStates[key] = rs
                return false
            } else {
                if state.lineNumber >= rs.startLine + off {
                    rs.active = false
                    rangeStates[key] = rs
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
            var rs = rangeStates[key] ?? SedRangeState()
            if !rs.completed {
                if state.lineNumber >= startN {
                    rs.completed = true
                    rangeStates[key] = rs
                    return true
                }
            }
            return false
        }

        // Pattern range: tracked with state.
        var rs = rangeStates[key] ?? SedRangeState()
        if !rs.active {
            if rs.completed { return false }
            var startMatches = false
            if case .line(let n) = start {
                startMatches = state.lineNumber >= n
            } else {
                startMatches = matchAddress(start, state: &state)
            }
            if startMatches {
                rs.active = true
                rs.startLine = state.lineNumber
                rangeStates[key] = rs
                if matchAddress(end, state: &state) {
                    rs.active = false
                    if case .line = start { rs.completed = true }
                    rangeStates[key] = rs
                }
                return true
            }
            return false
        } else {
            if matchAddress(end, state: &state) {
                rs.active = false
                if case .line = start { rs.completed = true }
                rangeStates[key] = rs
            }
            return true
        }
    }

    private func numericAddress(_ a: SedAddress, state: SedRunState) -> Int {
        switch a {
        case .line(let n): return n
        case .last: return state.totalLines
        case .step(let first, let step):
            // Treat as numeric "first"; not part of typical num,num
            // ranges but harmless.
            return step == 0 ? first : first
        case .relative: return state.totalLines
        case .regex: return state.totalLines
        }
    }

    private func matchAddress(_ a: SedAddress, state: inout SedRunState) -> Bool {
        switch a {
        case .line(let n): return state.lineNumber == n
        case .last: return state.lineNumber == state.totalLines
        case .step(let first, let step):
            if step == 0 { return state.lineNumber == first }
            return state.lineNumber >= first && (state.lineNumber - first) % step == 0
        case .regex(var pat):
            if pat.isEmpty, let last = state.lastPattern { pat = last }
            else if !pat.isEmpty { state.lastPattern = pat }
            guard let regex = try? SedRegex.compile(pat, extendedRegex: false) else { return false }
            let ns = state.patternSpace as NSString
            return regex.firstMatch(in: state.patternSpace,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        case .relative:
            return false  // only valid as range end
        }
    }

    private func serialize(_ r: SedAddressRange) -> String {
        func ser(_ a: SedAddress?) -> String {
            guard let a else { return "_" }
            switch a {
            case .line(let n): return "L\(n)"
            case .last: return "$"
            case .regex(let p): return "/\(p)/"
            case .step(let f, let s): return "S\(f)~\(s)"
            case .relative(let o): return "+\(o)"
            }
        }
        return "\(ser(r.start)),\(ser(r.end))"
    }
}

/// Per-line execution state.
struct SedRunState {
    var patternSpace: String = ""
    var holdSpace: String = ""
    var lineNumber: Int = 0
    var totalLines: Int = 0
    var deleted: Bool = false
    var printed: Bool = false
    var quit: Bool = false
    var quitSilent: Bool = false
    var exitCode: Int? = nil
    var errorMessage: String? = nil
    var appendBuffer: [AppendItem] = []
    var changedText: String? = nil
    var substitutionMade: Bool = false
    var lineNumberOutput: [String] = []
    var nCommandOutput: [String] = []
    var restartCycle: Bool = false
    var lastPattern: String? = nil
    var branchRequest: String? = nil
    var linesConsumedInCycle: Int = 0
    var pendingFileReads: [PendingRead] = []
    var pendingFileWrites: [PendingWrite] = []

    enum AppendItem {
        case insert(String)
        case append(String)
    }
    struct PendingRead {
        let filename: String
        let wholeFile: Bool
    }
    struct PendingWrite {
        let filename: String
        let content: String
    }
}
