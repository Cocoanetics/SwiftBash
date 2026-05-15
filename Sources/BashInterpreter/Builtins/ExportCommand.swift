import Foundation

/// `export NAME[=VALUE]...`
///
/// Sets one or more environment variables. In real bash, `export` marks a
/// variable as eligible for inheritance by child processes; since this
/// skeleton doesn't spawn children, the mark is implicit — every
/// variable in `Environment.variables` is conceptually "exported".
public struct ExportCommand: Command {
    public let name = "export"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = argv.dropFirst()
        if args.isEmpty {
            // Print every variable as `declare -x NAME="value"`.
            for (key, value) in Shell.bashCurrent.environment.variables.sorted(by: { $0.key < $1.key }) {
                Shell.bashCurrent.stdout("declare -x \(key)=\"\(value)\"\n")
            }
            return .success
        }
        for arg in args {
            if let eqIdx = arg.firstIndex(of: "=") {
                let name = String(arg[..<eqIdx])
                let value = String(arg[arg.index(after: eqIdx)...])
                Shell.bashCurrent.environment[name] = value
            } else {
                // `export NAME` without `=` ensures the variable exists
                // (empty if previously unset).
                if Shell.bashCurrent.environment[arg] == nil {
                    Shell.bashCurrent.environment[arg] = ""
                }
            }
        }
        return .success
    }
}
