import ArgumentParser
import BashInterpreter

/// `type NAME...` — for each NAME, describe how the shell would
/// resolve it. Output mirrors bash's own `type`:
///
/// - Pure shell built-ins report `<name> is a shell builtin`.
/// - File-shadowed registered / external commands report
///   `<name> is /path/to/<name>`.
/// - With `-a`, every match is listed in dispatch order: built-in
///   first (if any), then every `$PATH` hit.
/// - Unknown names print `type: <name>: not found` to stderr and
///   the command exits non-zero.
///
/// Real bash also distinguishes functions and aliases; this
/// implementation surfaces functions as built-ins (they live in the
/// same registry slot for now).
public struct TypeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Describe how the shell would resolve a name."
    )

    @Flag(name: .customShort("a"),
          help: "List every match (built-in + every PATH hit) in dispatch order.")
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
        let resolver = PathResolver(shell)
        var missing = false
        for name in names {
            let builtinHit = shell.shellBuiltins[name] != nil
            let pathHits = await resolver.allMatches(forName: name)
            if !builtinHit && pathHits.isEmpty {
                shell.stderr("type: \(name): not found\n")
                missing = true
                continue
            }
            if builtinHit {
                shell.stdout("\(name) is a shell builtin\n")
                if !all { continue }
            }
            for hit in pathHits {
                switch hit {
                case .registered(_, let path), .externalScript(let path):
                    shell.stdout("\(name) is \(path)\n")
                case .notFound: break
                }
                if !all { break }
            }
        }
        return missing ? .failure : .success
    }
}
