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

    // swiftlint:disable:next cyclomatic_complexity
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

        for raw in argv[index...] {
            if operateOnFunctions {
                // Functions live in the command registry alongside
                // builtins; remove only function-defined commands.
                if Shell.bashCurrent.commands[raw] is FunctionCommand {
                    Shell.bashCurrent.commands.removeValue(forKey: raw)
                }
                continue
            }

            // `arr[N]` — element-level unset.
            if let lbracket = raw.firstIndex(of: "["), raw.last == "]" {
                let head = String(raw[..<lbracket])
                let after = raw.index(after: lbracket)
                let last = raw.index(before: raw.endIndex)
                let sub = String(raw[after..<last])

                if var assoc = Shell.bashCurrent.environment.associativeArrays[head] {
                    assoc.removeValue(forKey: sub)
                    Shell.bashCurrent.environment.associativeArrays[head] = assoc
                    continue
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
                    continue
                }
                continue
            }

            Shell.bashCurrent.environment.variables.removeValue(forKey: raw)
            Shell.bashCurrent.environment.arrays.removeValue(forKey: raw)
            Shell.bashCurrent.environment.associativeArrays.removeValue(forKey: raw)
        }
        return .success
    }
}
