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

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        var i = 1
        var associative = false

        // Option pass — accept multiple flags, e.g. `declare -Ar map`.
        while i < argv.count, argv[i].hasPrefix("-"), argv[i] != "-" {
            for c in argv[i].dropFirst() {
                switch c {
                case "A": associative = true
                case "r", "x", "i", "a", "g": break
                default:
                    shell.stderr("declare: -\(c): invalid option\n")
                    return ExitStatus(2)
                }
            }
            i += 1
        }

        // Each remaining arg is `NAME` or `NAME=VALUE`.
        for raw in argv[i...] {
            let nameOnly: String
            let value: String?
            if let eq = raw.firstIndex(of: "=") {
                nameOnly = String(raw[..<eq])
                value = String(raw[raw.index(after: eq)...])
            } else {
                nameOnly = raw
                value = nil
            }

            if associative {
                if shell.environment.associativeArrays[nameOnly] == nil {
                    shell.environment.associativeArrays[nameOnly] = [:]
                }
                shell.environment.arrays.removeValue(forKey: nameOnly)
                shell.environment.variables.removeValue(forKey: nameOnly)
                if let value {
                    // `declare -A m=value` is unusual in real scripts
                    // (typically followed by `m[k]=v` lines instead);
                    // we treat the bare value as the empty-key entry.
                    shell.environment.associativeArrays[nameOnly]?[""] = value
                }
            } else if let value {
                shell.environment[nameOnly] = value
            }
        }
        return .success
    }
}
