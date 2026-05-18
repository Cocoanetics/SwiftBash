import Foundation
import ShellKit

extension Shell {

    /// Public completion-source surface — the same data the `compgen`
    /// builtin needs, exposed so embedders (an IDE, a REPL, an iOS
    /// terminal app) can drive Tab completion against this shell
    /// without reaching into private state.
    ///
    /// The struct holds an unowned reference to its shell; only call
    /// it while that shell is alive. Each call snapshots the data it
    /// returns — mutations on the shell after the call don't affect
    /// the returned array.
    public var completionSources: CompletionSources {
        CompletionSources(shell: self)
    }
}

/// Snapshot view of the runtime state Tab completion cares about.
///
/// Built on demand from a ``Shell`` reference. Three kinds of methods:
///
/// - Catalog enumeration: ``listCommands(kind:)``, ``listFunctions()``,
///   ``listAliases()``.
/// - Variable enumeration: ``listVariables(scope:)``.
/// - Filesystem enumeration: ``listDirectory(_:)``.
///
/// The shape mirrors what `compgen` needs but is intentionally
/// usable on its own — embedders that want Tab completion in their
/// own UI call these directly rather than spawning `compgen` and
/// parsing its stdout.
public struct CompletionSources {

    /// Sub-kind filter for ``listCommands(kind:)``.
    public enum CommandKind: Sendable {
        /// Every command in the registry — builtins, registered
        /// SwiftPorts CLIs, user-defined functions. Today this is the
        /// same answer a sandboxed bash gives, since there is no PATH
        /// to walk.
        case all
        /// Only commands that aren't user-defined shell functions.
        /// Once builtin vs. external tagging exists, this will narrow
        /// further to true builtins.
        case builtin
        /// Only user-defined shell functions.
        case function
    }

    /// Sub-kind filter for ``listVariables(scope:)``.
    public enum VariableScope: Sendable {
        /// Scalar variables only (`name=value`).
        case scalar
        /// Indexed arrays only (`name=(a b c)`).
        case array
        /// Associative arrays only (`declare -A name`).
        case associative
        /// Every name across all three buckets, deduplicated.
        case all
    }

    private unowned let shell: Shell

    init(shell: Shell) {
        self.shell = shell
    }

    /// Names of commands currently registered on the shell. Sorted
    /// alphabetically. For `.all`, file-backed commands surface only
    /// when their install directory is currently in `$PATH` — that
    /// matches what a real bash session shows via `compgen -c` and
    /// keeps PATH semantics honest (an install at `/opt/skill/bin`
    /// disappears from listing when `/opt/skill/bin` is removed from
    /// `$PATH`).
    public func listCommands(kind: CommandKind = .all) -> [String] {
        switch kind {
        case .all:
            var names = Set(shell.shellBuiltins.keys)
            names.formUnion(functionNames())
            names.formUnion(pathReachableBasenames())
            return names.sorted()
        case .builtin:
            var names = Set(shell.shellBuiltins.keys)
            names.formUnion(pathReachableBasenames())
            names.subtract(functionNames())
            return names.sorted()
        case .function:
            return functionNames().sorted()
        }
    }

    /// Basenames of installed commands whose install directory is in
    /// the current `$PATH`. Drives `compgen -c` honest about PATH —
    /// an install at `/opt/skill/bin` disappears from listings once
    /// `/opt/skill/bin` leaves `$PATH`. Relative entries (`.`,
    /// `./bin`) are resolved against the shell's working directory
    /// before comparison, matching the same lookup rule ``PathResolver``
    /// uses so completion never reports a name dispatch can't reach
    /// (or vice versa).
    private func pathReachableBasenames() -> Set<String> {
        let pathDirs = Set(currentPathDirectories())
        guard !pathDirs.isEmpty else { return [] }
        var names: Set<String> = []
        for (basename, paths) in shell.pathsByBasename
            where paths.contains(where: {
                pathDirs.contains((($0 as NSString).deletingLastPathComponent))
            }) {
            names.insert(basename)
        }
        return names
    }

    private func functionNames() -> Set<String> {
        Set(shell.commands.compactMap {
            $0.value is FunctionCommand ? $0.key : nil
        })
    }

    private func currentPathDirectories() -> [String] {
        let raw = shell.environment["PATH"] ?? ""
        if raw.isEmpty { return [] }
        return raw.split(separator: ":", omittingEmptySubsequences: false)
            .map { entry -> String in
                let dir = entry.isEmpty ? "." : String(entry)
                // Resolve relative PATH entries against the shell's
                // working directory so `PATH=.` / `PATH=./bin` match
                // the absolute paths recorded by `install(_:at:)`.
                return Shell.isAbsolutePath(dir)
                    ? dir
                    : shell.resolvePath(dir)
            }
    }

    /// Convenience for ``listCommands(kind:)`` with `.function`. Kept
    /// as a dedicated entry point because real bash's `compgen -A
    /// function` is the most common consumer.
    public func listFunctions() -> [String] {
        listCommands(kind: .function)
    }

    /// Names of registered aliases. Empty until SwiftBash grows an
    /// alias system — returning an empty list lets `compgen -a` and
    /// `compgen -A alias` work without erroring.
    public func listAliases() -> [String] {
        []
    }

    /// Names of variables on this shell. Sorted alphabetically.
    public func listVariables(scope: VariableScope = .all) -> [String] {
        let env = shell.environment
        switch scope {
        case .scalar:
            return env.variables.keys.sorted()
        case .array:
            return env.arrays.keys.sorted()
        case .associative:
            return env.associativeArrays.keys.sorted()
        case .all:
            var names = Set(env.variables.keys)
            names.formUnion(env.arrays.keys)
            names.formUnion(env.associativeArrays.keys)
            return names.sorted()
        }
    }

    /// Directory entries under `path` (resolved against the shell's
    /// working directory via ``Shell/resolvePath(_:)``). Returns an
    /// empty array if the path doesn't exist, isn't a directory, or
    /// the filesystem otherwise refuses to list it — completion is a
    /// best-effort surface and shouldn't throw at the caller.
    public func listDirectory(_ path: String) async -> [FileEntry] {
        let resolved = shell.resolvePath(path.isEmpty ? "." : path)
        do {
            return try await shell.fileSystem.list(resolved)
        } catch {
            return []
        }
    }
}
