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

    // Run the script over `lines` (already split by `\n`). Returns the
    // concatenated stdout output and an optional exit code (set by `q`
    // / `Q` / `v` failure).
    // Sed top-level cycle: per-line driver that runs the entire command
    // list, applies pending file reads/writes, and emits the cycle's
    // output. The branches (n output / pattern-space output / changed-
    // text / appends) all interact with the same state variables; one
    // cohesive routine is clearer than several tightly-coupled helpers.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func run(lines: [String], inputEndsWithNewline: Bool,
             readFile: (String) throws -> String) -> RunResult {
        var output = ""
        var lastWasAutoPrint = false
        var exitCode: Int32?
        var holdSpace = ""
        var lastPattern: String?
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
                            let pos = fileLinePos[read.filename] ?? 0
                            let lns = fileLineCache[read.filename] ?? []
                            if pos < lns.count {
                                state.appendBuffer.append(.append(lns[pos]))
                                fileLinePos[read.filename] = pos + 1
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
                for line in state.nCommandOutput { output += line + "\n" }
            }

            // = / l / F / p outputs
            let hadExplicit = !state.lineNumberOutput.isEmpty
            for line in state.lineNumberOutput { output += line + "\n" }

            var inserts: [String] = []
            var appends: [String] = []
            for item in state.appendBuffer {
                switch item {
                case .insert(let text): inserts.append(text)
                case .append(let text): appends.append(text)
                }
            }
            for text in inserts { output += text + "\n" }

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

            for text in appends { output += text + "\n" }
            lastWasAutoPrint = (hadExplicit || hadPatternSpaceOutput) && appends.isEmpty

            if let err = state.errorMessage {
                return RunResult(output: "", exitCode: Int32(state.exitCode ?? 1),
                                 errorMessage: err)
            }
            if state.quit || state.quitSilent {
                if let code = state.exitCode { exitCode = Int32(code) }
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
}
