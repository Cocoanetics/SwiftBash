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
        var i = 1
        var operateOnFunctions = false
        while i < argv.count, argv[i].hasPrefix("-"), argv[i] != "--" {
            switch argv[i] {
            case "-f": operateOnFunctions = true
            case "-v": operateOnFunctions = false
            default:
                Shell.current.stderr("unset: invalid option: \(argv[i])\n")
                return ExitStatus(2)
            }
            i += 1
        }
        if i < argv.count, argv[i] == "--" { i += 1 }

        for raw in argv[i...] {
            if operateOnFunctions {
                // Functions live in the command registry alongside
                // builtins; remove only function-defined commands.
                if Shell.current.commands[raw] is FunctionCommand {
                    Shell.current.commands.removeValue(forKey: raw)
                }
                continue
            }

            // `arr[N]` — element-level unset.
            if let lb = raw.firstIndex(of: "["), raw.last == "]" {
                let head = String(raw[..<lb])
                let after = raw.index(after: lb)
                let last = raw.index(before: raw.endIndex)
                let sub = String(raw[after..<last])

                if var assoc = Shell.current.environment.associativeArrays[head] {
                    assoc.removeValue(forKey: sub)
                    Shell.current.environment.associativeArrays[head] = assoc
                    continue
                }
                if var array = Shell.current.environment.arrays[head] {
                    if sub == "@" || sub == "*" {
                        // `unset arr[@]` removes the whole array.
                        Shell.current.environment.arrays.removeValue(forKey: head)
                    } else if let n = Int(sub) {
                        let resolved = n >= 0 ? n
                            : ((array.entries.keys.max() ?? -1) + 1 + n)
                        array[resolved] = nil
                        Shell.current.environment.arrays[head] = array
                    }
                    continue
                }
                continue
            }

            Shell.current.environment.variables.removeValue(forKey: raw)
            Shell.current.environment.arrays.removeValue(forKey: raw)
            Shell.current.environment.associativeArrays.removeValue(forKey: raw)
        }
        return .success
    }
}
