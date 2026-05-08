import Foundation

/// A pluggable interpreter the shell can hand a script's source to when
/// it dispatches an executable file (e.g. `./hello.swift`) whose
/// `#!`-shebang names this interpreter.
///
/// SwiftBash itself runs in-process — there is no `exec(2)` — so a
/// shebang like `#!/usr/bin/env swift-script` cannot be honored by the
/// kernel. Instead, embedders register a `ScriptInterpreter` for each
/// shebang they want to support; when a path-like simple command turns
/// out to be an executable file, the dispatcher looks up its
/// interpreter and invokes ``run(scriptPath:source:argv:)``.
///
/// ```swift
/// shell.registerScriptInterpreter(name: "swift-script") { ctx in
///     // ctx.source has the leading "#!…" line replaced with "//…"
///     // already, so SwiftSyntax-style parsers never see the shebang.
///     try await SwiftScriptInterpreter().eval(ctx.source,
///                                             fileName: ctx.scriptPath)
///     return .success
/// }
/// ```
///
/// Every registered interpreter inherits the calling shell via
/// `Shell.current` (TaskLocal), so the body can read environment,
/// sandbox state, sinks, etc. without any explicit threading.
public protocol ScriptInterpreter: Sendable {
    /// Identifier matched against the basename of the shebang's
    /// interpreter — `"swift"`, `"swift-script"`, `"python3"`. Multiple
    /// interpreters can share a name; later registrations replace
    /// earlier ones.
    var name: String { get }

    /// Execute `context.source` as a script. Implementations write to
    /// `Shell.current.stdout` / `.stderr` and read positional
    /// parameters from `Shell.current.positionalParameters` (set by the
    /// dispatcher to `argv[1...]`).
    func run(_ context: ScriptInterpreterContext) async throws -> ExitStatus
}

/// Inputs handed to a ``ScriptInterpreter``.
///
/// The shell reads the file off ``Shell/fileSystem``, strips the
/// `#!`-line (rewritten as a `//`-comment so byte offsets and line
/// numbers stay stable for diagnostics), and passes the result here.
/// Most interpreters only need ``source``; ``scriptPath`` is exposed
/// for diagnostic rendering, and ``shebang`` for interpreters that
/// need to inspect their own argv (e.g. flag-bearing shebangs like
/// `#!/usr/bin/env -S swift-script --strict`).
public struct ScriptInterpreterContext: Sendable {
    /// Absolute path the script was loaded from, as resolved by
    /// ``Shell/resolvePath(_:)``. Forwarded to interpreters as a
    /// `fileName:` for diagnostics.
    public let scriptPath: String

    /// Script source with the shebang line rewritten to `//…` so
    /// downstream parsers never see `#!`. Byte offsets and line
    /// numbers are preserved (only the leading two characters are
    /// replaced).
    public let source: String

    /// Raw shebang line including the leading `#!`, minus the trailing
    /// newline. `nil` when the file had no shebang.
    public let shebang: String?

    /// argv as the script would observe it: index 0 is the script
    /// path, indices 1+ are the user-supplied arguments. Mirrors
    /// Swift's `CommandLine.arguments`.
    public let argv: [String]
}

/// A ``ScriptInterpreter`` backed by a closure — the short form for
/// host-side registrations.
public struct ClosureScriptInterpreter: ScriptInterpreter {
    public let name: String
    private let body: @Sendable (ScriptInterpreterContext) async throws -> ExitStatus

    public init(name: String,
                body: @Sendable @escaping (ScriptInterpreterContext) async throws -> ExitStatus)
    {
        self.name = name
        self.body = body
    }

    public func run(_ context: ScriptInterpreterContext) async throws -> ExitStatus {
        try await body(context)
    }
}
