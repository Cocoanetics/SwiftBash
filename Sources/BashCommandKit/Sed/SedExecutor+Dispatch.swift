import Foundation

extension SedExecutor {

    // Returns whether a branch request crossed our scope (the caller
    // — usually the enclosing group — needs to honour it).
    // Sed cycle dispatch: branch-table over every control-flow command
    // (n, N, b, t, T, group, label). Each case is a few lines but the
    // dispatch must stay together to share the `index`/`labels`/state
    // loop. The handful of plain commands fall through to executeOne.
    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func execute(_ cmds: [SedCommandNode],
                 state: inout SedRunState,
                 lines: [String],
                 currentLineIndex: Int,
                 rangeStates: inout [String: SedRangeState]) -> Bool {
        // Build label index for THIS scope.
        var labels: [String: Int] = [:]
        for (idx, cmd) in cmds.enumerated() {
            if case .label(let name) = cmd { labels[name] = idx }
        }
        var index = 0
        var iterations = 0
        while index < cmds.count {
            iterations += 1
            if iterations > limits.maxIterations {
                state.errorMessage = "sed: command execution exceeded maximum iterations (\(limits.maxIterations))"
                state.quit = true
                return false
            }
            if state.deleted || state.quit || state.quitSilent || state.restartCycle { break }
            let cmd = cmds[index]

            // n / N / branches / group must be inspected here because
            // they affect the cycle's control flow.
            switch cmd {
            case .label:
                index += 1; continue
            case .next(let range):
                if matches(range: range, state: &state, rangeStates: &rangeStates) {
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
                index += 1; continue
            case .nextAppend(let range):
                if matches(range: range, state: &state, rangeStates: &rangeStates) {
                    let nextIdx = currentLineIndex + state.linesConsumedInCycle + 1
                    if nextIdx < lines.count {
                        state.linesConsumedInCycle += 1
                        state.patternSpace += "\n" + lines[nextIdx]
                        state.lineNumber = nextIdx + 1
                    } else {
                        state.quit = true; break
                    }
                }
                index += 1; continue
            case .branch(let range, let label):
                if matches(range: range, state: &state, rangeStates: &rangeStates) {
                    if let lbl = label {
                        if let target = labels[lbl] { index = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false  // jump to end of THIS scope (script or group)
                }
                index += 1; continue
            case .branchOnSubst(let range, let label):
                if matches(range: range, state: &state, rangeStates: &rangeStates),
                   state.substitutionMade {
                    state.substitutionMade = false
                    if let lbl = label {
                        if let target = labels[lbl] { index = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false
                }
                index += 1; continue
            case .branchOnNoSubst(let range, let label):
                if matches(range: range, state: &state, rangeStates: &rangeStates),
                   !state.substitutionMade {
                    if let lbl = label {
                        if let target = labels[lbl] { index = target; continue }
                        state.branchRequest = lbl
                        return true
                    }
                    return false
                }
                index += 1; continue
            case .group(let range, let inner):
                if matches(range: range, state: &state, rangeStates: &rangeStates) {
                    let propagated = execute(inner, state: &state, lines: lines,
                                             currentLineIndex: currentLineIndex,
                                             rangeStates: &rangeStates)
                    if propagated, let lbl = state.branchRequest {
                        if let target = labels[lbl] {
                            state.branchRequest = nil
                            index = target
                            continue
                        }
                        return true
                    }
                }
                index += 1; continue
            default:
                break
            }

            executeOne(cmd, state: &state, rangeStates: &rangeStates)
            index += 1
        }
        return false
    }

    // Per-command effects: enum dispatch across the entire sed command
    // set. Each case is short but they must stay together since they
    // share state mutation patterns and the address-gating check above.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func executeOne(_ cmd: SedCommandNode,
                    state: inout SedRunState,
                    rangeStates: inout [String: SedRangeState]) {
        // For commands carrying an addressed range, gate execution.
        if let range = addressOf(cmd), !matches(range: range, state: &state, rangeStates: &rangeStates) {
            return
        }
        switch cmd {
        case .substitute(_, let pattern, let replacement, let global, let ignoreCase,
                         let printOnMatch, let nth, let extendedRegex, let writeFile):
            let opts = SubstituteOptions(
                pattern: pattern, replacement: replacement,
                global: global, ignoreCase: ignoreCase,
                printOnMatch: printOnMatch, nth: nth,
                extendedRegex: extendedRegex, writeFile: writeFile)
            applySubstitute(options: opts, state: &state)
        case .print:
            state.lineNumberOutput.append(state.patternSpace)
        case .printFirstLine:
            if let newlineIdx = state.patternSpace.firstIndex(of: "\n") {
                state.lineNumberOutput.append(String(state.patternSpace[..<newlineIdx]))
            } else {
                state.lineNumberOutput.append(state.patternSpace)
            }
        case .delete:
            state.deleted = true
        case .deleteFirstLine:
            if let newlineIdx = state.patternSpace.firstIndex(of: "\n") {
                state.patternSpace = String(state.patternSpace[state.patternSpace.index(after: newlineIdx)...])
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
            if state.holdSpace.isEmpty {
                state.holdSpace = state.patternSpace
            } else {
                state.holdSpace += "\n" + state.patternSpace
            }
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
            if let file = filename { state.lineNumberOutput.append(file) }
        case .version(_, let minVersion):
            applyVersion(minVersion, state: &state)
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
            if let newlineIdx = state.patternSpace.firstIndex(of: "\n") {
                first = String(state.patternSpace[..<newlineIdx])
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

    /// Process the `v` (version) command. Compares the script's required
    /// version against our claimed `4.8.0` and errors if we're behind.
    private func applyVersion(_ minVersion: String?, state: inout SedRunState) {
        let ours = [4, 8, 0]
        guard let version = minVersion else { return }
        let parts = version.split(separator: ".").map { Int($0) ?? -1 }
        if parts.contains(where: { $0 < 0 }) {
            state.errorMessage = "sed: invalid version string: \(version)"
            state.quit = true; state.exitCode = 1
            return
        }
        var padded = parts
        while padded.count < 3 { padded.append(0) }
        for idx in 0..<3 {
            if padded[idx] > ours[idx] {
                state.errorMessage = "sed: this is not GNU sed version \(version)"
                state.quit = true; state.exitCode = 1
                return
            }
            if padded[idx] < ours[idx] { return }
        }
    }
}
