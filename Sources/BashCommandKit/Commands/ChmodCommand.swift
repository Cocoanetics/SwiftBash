import ArgumentParser
import BashInterpreter
import Foundation

/// `chmod MODE FILE...` — change file permission bits.
///
/// Accepts both numeric octal modes (`755`, `0644`) and POSIX symbolic
/// modes (`u+x`, `+x`, `go-w`, `u=rwx,go=rx`). Symbolic clauses are
/// applied left-to-right onto the file's current mode; numeric modes
/// replace the mode wholesale.
public struct ChmodCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "chmod",
        abstract: "Change file permission bits."
    )

    @Flag(name: [.customShort("R"), .customLong("recursive")],
          help: "Operate on directories recursively.")
    public var recursive: Bool = false

    @Argument(help: "MODE FILE...")
    public var operands: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard operands.count >= 2 else {
            Shell.bashCurrent.stderr("chmod: missing operand\n")
            return ExitStatus(2)
        }
        let modeSpec = operands[0]
        let symbolic = parseSymbolic(modeSpec)
        let octalMode = UInt16(modeSpec, radix: 8)

        guard symbolic != nil || octalMode != nil else {
            Shell.bashCurrent.stderr("chmod: invalid mode: \(modeSpec)\n")
            return ExitStatus(2)
        }
        var hadError = false
        for f in operands.dropFirst() {
            let resolved = Shell.bashCurrent.resolvePath(f)
            do {
                try await applyMode(to: resolved,
                                    symbolic: symbolic,
                                    octalMode: octalMode)
            } catch {
                Shell.bashCurrent.stderr("chmod: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Apply the parsed mode to `path`, recursing if `--recursive`.
    private func applyMode(to path: String,
                           symbolic: [SymbolicClause]?,
                           octalMode: UInt16?) async throws {
        let resolvedMode: UInt16
        if let octalMode {
            resolvedMode = octalMode
        } else if let symbolic {
            let current = (try? await Shell.bashCurrent.fileSystem
                .metadata(path)?.mode) ?? 0
            resolvedMode = symbolic.reduce(current) { $1.apply(to: $0) }
        } else {
            return
        }
        try await Shell.bashCurrent.fileSystem.chmod(path, mode: resolvedMode)
        if recursive {
            try await applyRecursive(path,
                                     symbolic: symbolic,
                                     octalMode: octalMode)
        }
    }

    private func applyRecursive(_ path: String,
                                symbolic: [SymbolicClause]?,
                                octalMode: UInt16?) async throws {
        guard let meta = try? await Shell.bashCurrent.fileSystem.metadata(path),
              meta.kind == .directory else { return }
        let entries = (try? await Shell.bashCurrent.fileSystem.list(path)) ?? []
        for entry in entries {
            let child = (path as NSString).appendingPathComponent(entry.name)
            try? await applyMode(to: child,
                                 symbolic: symbolic,
                                 octalMode: octalMode)
        }
    }

    // MARK: - Symbolic-mode parser

    /// One `who op perms` clause, e.g. `u+x` or `go=r`. Multiple clauses
    /// can be comma-separated in a single mode argument.
    fileprivate struct SymbolicClause {
        enum Op { case add, remove, set }
        let whoMask: UInt16   // permission bits this clause writes into
        let op: Op
        let permBits: UInt16  // r/w/x bits as an "all-positions" mask

        func apply(to current: UInt16) -> UInt16 {
            // The actual bits-to-touch is permBits projected onto whoMask.
            // permBits is in lowest-three-bits form; replicate it across
            // user/group/other depending on whoMask, then mask to whoMask.
            let replicated = (permBits << 6) | (permBits << 3) | permBits
            let target = replicated & whoMask
            switch op {
            case .add:    return current | target
            case .remove: return current & ~target
            case .set:    return (current & ~whoMask) | target
            }
        }
    }

    /// Parse a symbolic chmod expression like `u+x`, `+x`, `go-w`,
    /// `u=rwx,go=rx`. Returns `nil` if the string isn't a valid symbolic
    /// expression — caller falls through to the numeric path.
    fileprivate func parseSymbolic(_ spec: String) -> [SymbolicClause]? {
        var clauses: [SymbolicClause] = []
        for raw in spec.split(separator: ",") {
            guard let clause = parseClause(String(raw)) else { return nil }
            clauses.append(clause)
        }
        return clauses.isEmpty ? nil : clauses
    }

    private func parseClause(_ raw: String) -> SymbolicClause? {
        var i = raw.startIndex
        // `who` — optional run of `[ugoa]`. Default to "a" (all) when
        // missing, matching bash and POSIX.
        var who: UInt16 = 0
        let whoChars: Set<Character> = ["u", "g", "o", "a"]
        while i < raw.endIndex, whoChars.contains(raw[i]) {
            switch raw[i] {
            case "u": who |= 0o700
            case "g": who |= 0o070
            case "o": who |= 0o007
            case "a": who |= 0o777
            default:  break
            }
            i = raw.index(after: i)
        }
        if who == 0 { who = 0o777 }

        // `op` — exactly one of `+`, `-`, `=`.
        guard i < raw.endIndex else { return nil }
        let opChar = raw[i]
        let op: SymbolicClause.Op
        switch opChar {
        case "+": op = .add
        case "-": op = .remove
        case "=": op = .set
        default: return nil
        }
        i = raw.index(after: i)

        // `perms` — run of `[rwxX]`. We treat capital `X` as `x`.
        // Extensions like `s` (setuid) and `t` (sticky) aren't supported
        // by the underlying FileSystem.chmod surface, so we leave them
        // for a future PR rather than silently swallow them.
        var perm: UInt16 = 0
        while i < raw.endIndex {
            switch raw[i] {
            case "r": perm |= 0o4
            case "w": perm |= 0o2
            case "x", "X": perm |= 0o1
            default: return nil
            }
            i = raw.index(after: i)
        }
        return SymbolicClause(whoMask: who, op: op, permBits: perm)
    }
}
