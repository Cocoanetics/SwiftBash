import Foundation

/// `local NAME[=VALUE]…` — declare variables that revert to their
/// previous values when the enclosing function returns. Only valid
/// inside a function; outside, this is an error.
///
/// ```bash
/// f() {
///   local x=hello   # x is local to f; doesn't leak
///   echo "$x"
/// }
/// ```
public struct LocalCommand: Command {
    public let name = "local"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        if Shell.bashCurrent.functionCallDepth == 0 {
            Shell.bashCurrent.stderr("local: can only be used in a function\n")
            return .failure
        }
        // Always operate on the top frame; FunctionCommand pushed it.
        var frame = Shell.bashCurrent.localVarStack.removeLast()
        defer { Shell.bashCurrent.localVarStack.append(frame) }

        for spec in argv.dropFirst() {
            let name: String
            let value: String?
            if let equalsIndex = spec.firstIndex(of: "=") {
                name = String(spec[..<equalsIndex])
                value = String(spec[spec.index(after: equalsIndex)...])
            } else {
                name = spec
                value = nil
            }
            // Snapshot the prior value once per name (so multiple
            // `local x` calls stack to the *outermost* prior).
            if !frame.contains(where: { $0.name == name }) {
                frame.append((name, Shell.bashCurrent.environment[name]))
            }
            if let value {
                Shell.bashCurrent.environment[name] = value
            } else {
                // POSIX says local without a value initialises to "".
                // Bash actually leaves it unset; we follow bash so a
                // subsequent `${X:-default}` can fire.
                Shell.bashCurrent.environment[name] = nil
            }
        }
        return .success
    }
}
