import Foundation

/// The state behind bash's dynamic variables — `$RANDOM`, `$SECONDS`,
/// `$LINENO`, `$BASHPID`, `$BASH_SUBSHELL` and the call stack that
/// `FUNCNAME`, `BASH_SOURCE` and `BASH_LINENO` show. Their values are
/// computed when read rather than stored in the environment, so `env`
/// doesn't list them; bash doesn't export them either.
struct DynamicVariables {
    /// `$RANDOM`'s generator.
    var random = RandomGenerator()
    /// `$SECONDS` reads as `secondsBase` plus the whole seconds since
    /// `secondsStart`. Assigning `SECONDS` restarts the count.
    var secondsBase = 0
    var secondsStart = Date()
    /// `$BASH_SUBSHELL`: how many subshell levels deep this shell is.
    var subshellLevel = 0
    /// `$BASHPID` in a subshell; `nil` for the shell itself (`$$`).
    var subshellPID: Int32?
    /// A pipeline stage that's a simple command counts toward
    /// `$BASH_SUBSHELL` only if it runs shell code — a function, `eval`
    /// or `source` — which its first dispatch decides.
    var deferredNesting = false
    /// Names `unset` has stripped of their special meaning: after
    /// `unset RANDOM`, `RANDOM` is an ordinary variable, as in bash.
    var disabled: Set<String> = []
    /// Function and `source` frames, outermost first.
    var callStack: [CallFrame] = []
    /// While an ERR or DEBUG trap runs, `$LINENO` stays at the line of
    /// the command that triggered it.
    var frozenLine: Int?
    /// Where the last simple command to finish started, in
    /// ``Shell/currentSource`` — the line an ERR trap reports.
    var lastCommandStart: Int?
    /// Added to line numbers within ``Shell/currentSource``: inside
    /// `eval`, the text continues the caller's line count.
    var lineOffset = 0
    /// The shell runs a `bash -c` string, so `$-` shows `c`. Subshells
    /// keep it; a script the shell starts doesn't.
    var commandString = false
}

/// One function call or `source` on bash's call stack.
struct CallFrame {
    /// The function's name, or `source`.
    var name: String
    /// The file the function was defined in, or the sourced file.
    var file: String
    /// The line it was called from.
    var callLine: Int
}

/// SplitMix64, reduced to `$RANDOM`'s 0…32767 range. Assigning
/// `RANDOM` seeds it, so a seeded sequence repeats.
struct RandomGenerator {
    private var state = UInt64.random(in: .min ... .max)

    /// Seed from an assigned value. Like bash, a non-number seeds as 0.
    mutating func seed(_ text: String) {
        let value = Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0
        state = UInt64(bitPattern: value)
    }

    mutating func next() -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Int(mixed % 32768)
    }
}

/// Hands out `$BASHPID` values for subshells. They're synthetic —
/// subshells aren't in the process table — and start well above the
/// table's `&`-job PIDs so the two don't meet in practice.
final class SubshellPIDs: @unchecked Sendable {
    static let shared = SubshellPIDs()
    private let lock = NSLock()
    private var next: Int32 = 10_000

    func allocate() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return next
    }
}

extension Shell {

    /// The dynamic variables `unset` can turn into ordinary ones.
    static let unsettableDynamicVariables: Set<String> = [
        "RANDOM", "SECONDS", "LINENO", "BASHPID", "BASH_SUBSHELL",
        "FUNCNAME", "BASH_SOURCE", "BASH_LINENO"
    ]

    /// The current value of bash's dynamic variable `name`, or `nil`
    /// when `name` isn't one (or `unset` made it ordinary).
    func dynamicVariable(_ name: String) -> String? {
        guard !dynamicVariables.disabled.contains(name) else { return nil }
        switch name {
        case "RANDOM":
            return String(nextRandom())
        case "SECONDS":
            return String(elapsedSeconds())
        case "LINENO":
            return String(currentLineNumber)
        case "BASHPID":
            return String(dynamicVariables.subshellPID ?? virtualPID)
        case "BASH_SUBSHELL":
            return String(dynamicVariables.subshellLevel)
        case "UID", "EUID":
            return String(hostInfo.uid)
        case "PPID":
            // The virtual shell is PID 1 by default, with no parent.
            return "0"
        default:
            return nil
        }
    }

    /// The variables bash makes read-only: `UID=5` fails with
    /// `UID: readonly variable`, and `unset` refuses them.
    static let readonlyVariables: Set<String> = ["UID", "EUID", "PPID"]

    /// Whether assigning to `target` would write a read-only variable.
    /// `target` is a name, or an assignment's left side such as
    /// `NAME+` or `NAME[1]`.
    func isReadonlyVariable(_ target: String) -> Bool {
        Self.readonlyVariables.contains(Self.assignedName(target))
    }

    /// The variable an assignment's left side names: `NAME` for
    /// `NAME`, `NAME+` and `NAME[sub]`.
    private static func assignedName(_ target: String) -> String {
        var name = Substring(target)
        if let bracket = name.firstIndex(of: "[") { name = name[..<bracket] }
        if name.hasSuffix("+") { name = name.dropLast() }
        return String(name)
    }

    /// When `target` is read-only, print bash's `NAME: readonly
    /// variable` (after `builtin: `, for the builtins that name
    /// themselves) and return `true`: the caller skips the assignment
    /// and fails.
    func refuseReadonlyAssignment(_ target: String,
                                  builtin: String? = nil) -> Bool {
        guard isReadonlyVariable(target) else { return false }
        let name = Self.assignedName(target)
        let label = builtin.map { "\($0): " } ?? ""
        stderr("\(errorLocationPrefix())\(label)\(name): readonly variable\n")
        return true
    }

    /// `unset NAME`: a dynamic variable becomes an ordinary one, as in
    /// bash.
    func stripDynamicMeaning(_ name: String) {
        if Self.unsettableDynamicVariables.contains(name) {
            dynamicVariables.disabled.insert(name)
        }
    }

    /// The next `$RANDOM`. An assignment since the last read seeds the
    /// generator first.
    private func nextRandom() -> Int {
        if let seed = environment.variables.removeValue(forKey: "RANDOM") {
            dynamicVariables.random.seed(seed)
        }
        return dynamicVariables.random.next()
    }

    /// `$SECONDS`. An assignment since the last read restarts the count
    /// from the assigned value (a non-number counts as 0).
    private func elapsedSeconds() -> Int {
        if let assigned = environment.variables.removeValue(forKey: "SECONDS") {
            let base = assigned.trimmingCharacters(in: .whitespaces)
            dynamicVariables.secondsBase = Int(base) ?? 0
            dynamicVariables.secondsStart = Date()
        }
        let elapsed = Date().timeIntervalSince(dynamicVariables.secondsStart)
        return dynamicVariables.secondsBase + Int(elapsed)
    }

    /// `$-`: the single-letter options in effect, in bash's order.
    var optionFlags: String {
        var flags = ""
        if errexit { flags += "e" }
        if noglob { flags += "f" }
        flags += "h"
        if interactive { flags += "i" }
        if nounset { flags += "u" }
        if verbose { flags += "v" }
        if xtrace { flags += "x" }
        flags += "B"
        if noclobber { flags += "C" }
        if dynamicVariables.commandString { flags += "c" }
        return flags
    }

    /// `$LINENO`: the line of the command running now.
    var currentLineNumber: Int {
        if let frozen = dynamicVariables.frozenLine { return frozen }
        let position = currentCommandRange?.lowerBound ?? 0
        return dynamicVariables.lineOffset + lineNumber(for: position)
    }

    /// `BASH_SOURCE[0]`: the file the code running now came from — the
    /// innermost function's or sourced file, else the script. Without
    /// a script file, bash says `main` interactively and `environment`
    /// for `bash -c`.
    var currentSourceFile: String {
        if let frame = dynamicVariables.callStack.last { return frame.file }
        return scriptFile ?? (interactive ? "main" : "environment")
    }

    /// Whether a function is running — not just a sourced file, which
    /// ``functionCallDepth`` also counts. A `declare` here makes a local.
    var inFunction: Bool {
        dynamicVariables.callStack.contains { $0.name != "source" }
    }

    /// Run `body` with `frame` on the call stack.
    func withCallFrame<T>(
        _ frame: CallFrame, _ body: () async throws -> T
    ) async rethrows -> T {
        dynamicVariables.callStack.append(frame)
        syncCallStackArrays()
        defer {
            dynamicVariables.callStack.removeLast()
            syncCallStackArrays()
        }
        return try await body()
    }

    /// Refresh `FUNCNAME`, `BASH_SOURCE` and `BASH_LINENO` from the
    /// call stack, innermost first. A script adds a bottom `main`
    /// frame; `FUNCNAME` is set only while a function runs.
    func syncCallStackArrays() {
        let frames = dynamicVariables.callStack.reversed()
        var names = frames.map(\.name)
        var files = frames.map(\.file)
        var lines = frames.map { String($0.callLine) }
        if let scriptFile {
            names.append("main")
            files.append(scriptFile)
            lines.append("0")
        }
        setCallStackArray("FUNCNAME", inFunction ? names : [])
        setCallStackArray("BASH_SOURCE", files)
        setCallStackArray("BASH_LINENO", lines)
    }

    private func setCallStackArray(_ name: String, _ values: [String]) {
        guard !dynamicVariables.disabled.contains(name) else { return }
        if values.isEmpty {
            environment.arrays.removeValue(forKey: name)
        } else {
            environment.arrays[name] = BashArray(dense: values)
        }
    }

    /// Run an ERR or DEBUG trap body with `$LINENO` held at `line`, the
    /// line of the command that triggered it, as bash does.
    func withFrozenLineNumber<T>(
        _ line: Int, _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = dynamicVariables.frozenLine
        dynamicVariables.frozenLine = line
        defer { dynamicVariables.frozenLine = saved }
        return try await body()
    }

    /// The line of the last simple command to finish: what `$LINENO`
    /// reads in an ERR trap.
    var lastCommandLineNumber: Int {
        guard let start = dynamicVariables.lastCommandStart else {
            return currentLineNumber
        }
        return dynamicVariables.lineOffset + lineNumber(for: start)
    }
}
