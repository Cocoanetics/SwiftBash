import ArgumentParser
import BashInterpreter

/// `type NAME...` — for each NAME, describe how the shell would
/// resolve it. Output mirrors bash's own `type`:
///
/// - Shell functions report `<name> is a function`.
/// - Pure shell built-ins report `<name> is a shell builtin`.
/// - File-shadowed registered / external commands report
///   `<name> is /path/to/<name>`.
/// - With `-a`, every match is listed in dispatch order: function
///   first (if any), then built-in, then every `$PATH` hit.
/// - Unknown names print `type: <name>: not found` to stderr and
///   the command exits non-zero.
///
/// Real bash also distinguishes aliases; SwiftBash doesn't have an
/// alias bucket yet, so a name only ends up in one of the three
/// categories above.
public struct TypeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Describe how the shell would resolve a name."
    )

    @Flag(name: .customShort("a"),
          help: "List every match (function + built-in + every PATH hit) in dispatch order.")
    public var all: Bool = false

    @Argument(help: "Names to look up.")
    public var names: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if names.isEmpty {
            Shell.bashCurrent.stderr("type: missing operand\n")
            return .failure
        }
        let shell = Shell.bashCurrent
        var missing = false
        for name in names where !(await describe(name, in: shell)) {
            missing = true
        }
        return missing ? .failure : .success
    }

    /// Print the dispatch lines for one name; returns `true` when at
    /// least one bucket matched.
    private func describe(_ name: String, in shell: Shell) async -> Bool {
        let functionHit = shell.isFunction(named: name)
        let builtinHit = shell.shellBuiltins[name] != nil
        let pathHits = await PathResolver(shell).allMatches(forName: name)
        if !functionHit && !builtinHit && pathHits.isEmpty {
            shell.stderr("type: \(name): not found\n")
            return false
        }
        if functionHit {
            shell.stdout("\(name) is a function\n")
            if !all { return true }
        }
        if builtinHit {
            shell.stdout("\(name) is a shell builtin\n")
            if !all { return true }
        }
        for hit in pathHits {
            switch hit {
            case .registered(_, let path), .externalScript(let path):
                shell.stdout("\(name) is \(path)\n")
            case .notFound: continue
            }
            if !all { break }
        }
        return true
    }
}
