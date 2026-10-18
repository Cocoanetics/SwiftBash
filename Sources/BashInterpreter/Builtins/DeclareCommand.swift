import Foundation

/// `declare [-A] NAME[=VALUE] …` — minimal subset that handles the
/// bash-4 `-A` flag for associative arrays.
///
/// `declare -A m` registers `m` as an associative array (a `[String:
/// String]`-backed dict). Subsequent `m[key]=value` assignments
/// store under `key`; without `-A` the name would be treated as an
/// indexed array and `key` would be an integer subscript.
///
/// Other `declare` flags (`-r`, `-x`, `-i`, `-a`, etc.) are accepted
/// silently — most scripts use `declare -A` and `declare -r` /
/// `declare -i` rarely change observable behaviour.
public struct DeclareCommand: Command {
    public let name: String
    public init(name: String = "declare") { self.name = name }

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var index = 1
        var associative = false
        var global = false

        // Option pass — accept multiple flags, e.g. `declare -Ar map`.
        while index < argv.count, argv[index].hasPrefix("-"), argv[index] != "-" {
            for char in argv[index].dropFirst() {
                switch char {
                case "A": associative = true
                case "g": global = true
                case "r", "x", "i", "a": break
                default:
                    Shell.bashCurrent.stderr("declare: -\(char): invalid option\n")
                    return ExitStatus(2)
                }
            }
            index += 1
        }

        // Each remaining arg is `NAME` or `NAME=VALUE`. A read-only
        // `NAME=VALUE` fails without stopping the others, as in bash.
        // In a function, even `declare UID` would make a local: also
        // refused, unless `-g`.
        let makesLocal = Shell.bashCurrent.functionCallDepth > 0 && !global
        var status = ExitStatus.success
        for raw in argv[index...]
        where !applyAssignment(raw, associative: associative, makesLocal: makesLocal) {
            status = .failure
        }
        return status
    }

    /// Apply one `NAME[=VALUE]`; `false` when `NAME` is read-only.
    private func applyAssignment(_ raw: String, associative: Bool,
                                 makesLocal: Bool) -> Bool {
        let nameOnly: String
        let value: String?
        if let eqIdx = raw.firstIndex(of: "=") {
            nameOnly = String(raw[..<eqIdx])
            value = String(raw[raw.index(after: eqIdx)...])
        } else {
            nameOnly = raw
            value = nil
        }
        if value != nil || makesLocal,
           Shell.bashCurrent.refuseReadonlyAssignment(nameOnly, builtin: name) {
            return false
        }

        if associative {
            if Shell.bashCurrent.environment.associativeArrays[nameOnly] == nil {
                // `declare -A UID` keeps the identity as element `0`.
                let identity = Shell.bashCurrent.isReadonlyVariable(nameOnly)
                    ? Shell.bashCurrent.dynamicVariable(nameOnly) : nil
                Shell.bashCurrent.environment.associativeArrays[nameOnly] =
                    identity.map { ["0": $0] } ?? [:]
            }
            Shell.bashCurrent.environment.arrays.removeValue(forKey: nameOnly)
            Shell.bashCurrent.environment.variables.removeValue(forKey: nameOnly)
            if let value {
                // `declare -A m=value` is unusual in real scripts
                // (typically followed by `m[k]=v` lines instead);
                // we treat the bare value as the empty-key entry.
                Shell.bashCurrent.environment.associativeArrays[nameOnly]?[""] = value
            }
        } else if let value {
            Shell.bashCurrent.environment[nameOnly] = value
        }
        return true
    }
}
