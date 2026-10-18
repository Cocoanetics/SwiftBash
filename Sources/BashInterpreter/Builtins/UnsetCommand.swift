import Foundation

/// `unset [-fv] NAME…` — removes each named variable, function, or
/// array element from the shell's env.
///
/// Supported forms:
/// - `unset NAME` — removes the variable / array (or function if `-f`).
/// - `unset 'arr[N]'` — removes element N from the indexed array
///   (negative indices count from the end of the highest set slot).
/// - `unset 'arr[key]'` — removes one key from an associative array.
/// - `-v` (default) operates on variables, `-f` on functions.
public struct UnsetCommand: Command {
    public let name = "unset"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var index = 1
        var operateOnFunctions = false
        while index < argv.count, argv[index].hasPrefix("-"), argv[index] != "--" {
            switch argv[index] {
            case "-f": operateOnFunctions = true
            case "-v": operateOnFunctions = false
            default:
                Shell.bashCurrent.stderr("unset: invalid option: \(argv[index])\n")
                return ExitStatus(2)
            }
            index += 1
        }
        if index < argv.count, argv[index] == "--" { index += 1 }

        var status = ExitStatus.success
        for raw in argv[index...] {
            if operateOnFunctions {
                // Functions live in the command registry alongside
                // builtins; remove only function-defined commands.
                if Shell.bashCurrent.commands[raw] is FunctionCommand {
                    Shell.bashCurrent.commands.removeValue(forKey: raw)
                }
                continue
            }

            let shell = Shell.bashCurrent
            if shell.isReadonlyVariable(raw) {
                shell.stderr("\(shell.errorLocationPrefix())unset: \(raw): "
                             + "cannot unset: readonly variable\n")
                status = .failure
                continue
            }

            // `arr[N]` — element-level unset.
            if let lbracket = raw.firstIndex(of: "["), raw.last == "]" {
                unsetElement(raw, bracket: lbracket)
                continue
            }

            Shell.bashCurrent.environment.variables.removeValue(forKey: raw)
            Shell.bashCurrent.environment.arrays.removeValue(forKey: raw)
            Shell.bashCurrent.environment.associativeArrays.removeValue(forKey: raw)
            // `unset RANDOM` (or `SECONDS`, `LINENO`, `FUNCNAME`, …)
            // leaves an ordinary variable, as in bash.
            Shell.bashCurrent.stripDynamicMeaning(raw)
        }
        return status
    }

    /// `unset 'arr[N]'` / `unset 'map[key]'`; `arr[@]` removes the
    /// whole array.
    private func unsetElement(_ raw: String, bracket lbracket: String.Index) {
        let head = String(raw[..<lbracket])
        let after = raw.index(after: lbracket)
        let last = raw.index(before: raw.endIndex)
        let sub = String(raw[after..<last])

        if var assoc = Shell.bashCurrent.environment.associativeArrays[head] {
            assoc.removeValue(forKey: sub)
            Shell.bashCurrent.environment.associativeArrays[head] = assoc
            return
        }
        if var array = Shell.bashCurrent.environment.arrays[head] {
            if sub == "@" || sub == "*" {
                // `unset arr[@]` removes the whole array.
                Shell.bashCurrent.environment.arrays.removeValue(forKey: head)
            } else if let idxValue = Int(sub) {
                let resolved = idxValue >= 0 ? idxValue
                    : ((array.entries.keys.max() ?? -1) + 1 + idxValue)
                array[resolved] = nil
                Shell.bashCurrent.environment.arrays[head] = array
            }
        }
    }
}
