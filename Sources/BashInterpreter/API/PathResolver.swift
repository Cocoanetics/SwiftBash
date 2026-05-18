import Foundation
import ShellKit

/// Resolves a command word (`argv[0]`) against this shell's registry
/// and `$PATH`. Single source of truth for "how does the shell find
/// `foo`" — used by the dispatcher, by `which` / `type` / `command
/// -v`, and by ``BashProcessLauncher`` so SwiftScript /
/// SwiftJSCore subprocess bridges resolve the same way as bare bash
/// dispatch.
///
/// Resolution rules match POSIX bash:
///
/// - Tokens containing `/` (`./foo`, `/abs/foo`, `dir/foo`) are
///   treated as literal paths — no PATH search, no built-in
///   shadowing. The token resolves against the shell's working
///   directory and either points at a registered file-backed
///   ``Command`` (matching ``commandsByPath``), at an FS executable
///   (covered by ``Shell+ExternalScript``), or to nothing.
///
/// - Bare names (no `/`) walk `$PATH` left-to-right. Each entry is a
///   directory (empty entries count as `"."`); the resolver tries
///   `dir + "/" + name` against ``commandsByPath`` first, then asks
///   the filesystem whether that path is an executable file. The
///   first hit wins.
///
/// - With `$PATH` unset, the compiled-in default
///   (`/usr/local/bin:/usr/bin:/bin`) applies. With `$PATH` empty,
///   only built-ins / functions resolve (this layer reports
///   ``Resolution/notFound``).
///
/// Shell built-ins (``Shell/shellBuiltins``) and functions
/// (FunctionCommand stored in ``Shell/commands``) are handled by the
/// dispatcher *before* it consults the resolver — the resolver's job
/// is strictly the file-backed half.
public struct PathResolver {

    /// What a resolution attempt found.
    public enum Resolution: Sendable {
        /// A registered ``Command`` matched at `path`.
        case registered(Command, path: String)
        /// An executable file is at `path` but no registered command
        /// is keyed there — the dispatcher hands this off to the
        /// external-script flow (``Shell+ExternalScript``).
        case externalScript(path: String)
        /// Nothing matched in any PATH entry.
        case notFound
    }

    private unowned let shell: Shell

    public init(_ shell: Shell) {
        self.shell = shell
    }

    // MARK: - Resolution

    /// Resolve `argv[0]` to a ``Resolution``.
    public func resolve(_ token: String) async -> Resolution {
        if token.isEmpty { return .notFound }
        if looksLikePath(token) {
            return await resolveAsPath(token)
        }
        for path in candidatePaths(forName: token) {
            if let cmd = shell.commandsByPath[path] {
                return .registered(cmd, path: path)
            }
            if await isExecutableFile(at: path) {
                return .externalScript(path: path)
            }
        }
        return .notFound
    }

    /// All paths in `$PATH` that would match `name` if hit, in
    /// resolution order. Each candidate is paired with the
    /// ``Command`` registered there if any. Drives `which -a`, the
    /// `type -a` listing, and `compgen -c`.
    public func allMatches(forName name: String) async -> [Resolution] {
        guard !looksLikePath(name) else {
            switch await resolveAsPath(name) {
            case .notFound: return []
            case let other: return [other]
            }
        }
        var out: [Resolution] = []
        for path in candidatePaths(forName: name) {
            if let cmd = shell.commandsByPath[path] {
                out.append(.registered(cmd, path: path))
            } else if await isExecutableFile(at: path) {
                out.append(.externalScript(path: path))
            }
        }
        return out
    }

    // MARK: - PATH walking

    /// The ordered list of absolute paths the resolver would try for a
    /// bare `name`. Empty `$PATH` entries are treated as `"."`
    /// (current working directory), matching POSIX. An entirely empty
    /// `$PATH` returns no candidates (bare names can't resolve).
    public func candidatePaths(forName name: String) -> [String] {
        let raw = shell.environment["PATH"] ?? ""
        if raw.isEmpty { return [] }
        var out: [String] = []
        for entry in raw.split(separator: ":", omittingEmptySubsequences: false) {
            let dir = entry.isEmpty ? "." : String(entry)
            let candidate: String
            if Shell.isAbsolutePath(dir) {
                candidate = (dir as NSString).appendingPathComponent(name)
            } else {
                // Relative PATH entry — resolve against the shell's
                // CWD so `PATH=.` and `PATH=./bin` walk through the
                // working directory rather than the host process's.
                let absolute = shell.resolvePath(dir)
                candidate = (absolute as NSString).appendingPathComponent(name)
            }
            out.append(candidate)
        }
        return out
    }

    // MARK: - Path-shaped resolution

    private func resolveAsPath(_ token: String) async -> Resolution {
        // Absolute or relative — resolve against CWD lexically. Don't
        // canonicalize: a registered command keyed at the canonical
        // catalog path matches the user's literal invocation by exact
        // string, the same way the prior dispatcher did.
        let resolved = shell.resolvePath(token)
        if let cmd = shell.commandsByPath[resolved] {
            return .registered(cmd, path: resolved)
        }
        // Also match the literal token (un-resolved) against
        // `commandsByPath` so a bare absolute path like `/bin/echo`
        // resolves even when `resolvePath` collapses it differently.
        if let cmd = shell.commandsByPath[token] {
            return .registered(cmd, path: token)
        }
        if await isExecutableFile(at: resolved) {
            return .externalScript(path: resolved)
        }
        return .notFound
    }

    /// `true` when `token` contains a `/` (or `\` on Windows). Same
    /// definition the external-script dispatcher uses — bare names
    /// like `swift-script` are PATH-searched, anything path-shaped
    /// is taken literally.
    private func looksLikePath(_ token: String) -> Bool {
        #if os(Windows)
        return token.contains("/") || token.contains("\\")
        #else
        return token.contains("/")
        #endif
    }

    /// Probe the shell's filesystem for an executable regular file.
    /// Returns `false` on any error (missing, unreadable, sandboxed)
    /// — those are not resolver failures, just "not here". Real
    /// permission diagnostics surface later when the dispatcher tries
    /// to execute.
    private func isExecutableFile(at path: String) async -> Bool {
        do {
            guard let meta = try await shell.fileSystem.metadata(path) else {
                return false
            }
            guard meta.kind == .file else { return false }
            #if os(Windows)
            // Windows has no POSIX execute bit; treat every regular
            // file as executable so virtualised mounts work.
            return true
            #else
            // Virtualised filesystems sometimes report mode `0` —
            // treat those as executable so synthetic catalog entries
            // (which carry a real `0o755`) and in-memory test fixtures
            // both surface here. Real files with permissions set are
            // gated on the execute bit.
            if meta.mode == 0 { return true }
            return (meta.mode & 0o111) != 0
            #endif
        } catch {
            return false
        }
    }
}
