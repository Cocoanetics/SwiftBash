#if !os(Windows)

import Foundation

/// A configured JavaScriptCore context with a Node-ish runtime
/// bolted on top. Layers:
///
///   - Globals.swift  — console, process, Buffer, TextEncoder/Decoder,
///                      atob/btoa, queueMicrotask, timers
///   - Modules.swift  — require() with builtin map + local files
///                      (node:fs, node:path, node:os, node:url, node:util)
///
/// The point is to make scripts written for Node/Bun on macOS run
/// under JSC by providing custom Swift implementations of the
/// platform APIs they touch.
/// `@unchecked Sendable` because the runtime is single-threaded
/// by design — every `JSValue` touch happens on the main queue,
/// and the few helpers that hop off-main (URLSession callbacks,
/// `Task.detached` spawn drains) bounce back to main before
/// touching JSC state. Without the annotation, every closure that
/// crosses an `@Sendable` boundary (DispatchQueue.main.async,
/// MainActor.run) would warn under Swift 6 strict concurrency.
public final class JSRuntime: @unchecked Sendable {

    public let context: JSContext

    public var stdout: (String) -> Void
    public var stderr: (String) -> Void

    public internal(set) var exitCode: Int32 = 0
    var didExit: Bool = false

    /// Callbacks registered via `process.on('exit', fn)`. Fired
    /// when the runtime is about to terminate.
    var exitListeners: [JSValue] = []

    /// Path of the currently-running script (used for `__filename`,
    /// `__dirname`, and resolving `require('./relative')`).
    var currentScriptPath: String?

    // MARK: timers (driven from Timers.swift)

    /// Outstanding timers. The runloop drains until this is zero.
    var pendingTimers: [Int: DispatchSourceTimer] = [:]
    var nextTimerID: Int = 1

    /// Cached lazily-constructed `process.stdin` Readable, so the
    /// getter returns the same instance on every property access.
    var cachedStdin: JSValue?

    /// Set to true while the run loop is draining. Used by tests
    /// that want to inspect state mid-flight.
    public internal(set) var isDraining: Bool = false

    /// The env-provider backing `process.env`. Reads and writes from
    /// JS go through this. Defaults to ``OSEnvProvider`` (real host
    /// environment, with mutations propagating to `setenv`).
    public let envProvider: EnvProvider

    /// The argv-provider backing `process.argv`. Defaults to a
    /// frozen ``StaticArgvProvider`` from the init argument.
    public let argvProvider: ArgvProvider

    /// Which shell backend `child_process.execSync` / `spawnSync` /
    /// `exec` route through. Set once at init; the runtime never
    /// flips between modes.
    ///
    ///   - ``.inProcess`` (default) — every call goes through
    ///     SwiftBash's `BashInterpreter`. Unknown commands fail
    ///     with exit 127, the way bash itself does. No fork, no
    ///     exec; works in iOS App Sandbox, Swift Playgrounds,
    ///     anywhere fork is unavailable.
    ///
    ///   - ``.hostShell`` — every call forks `/bin/sh`. Supports
    ///     any binary on `PATH`, matches node's `child_process`
    ///     semantics exactly. The right choice when the runtime
    ///     is itself running as a normal Unix CLI process — which
    ///     is what the `swift-js` binary uses.
    public enum ChildShell: Sendable {
        case inProcess
        case hostShell
    }
    public let childShell: ChildShell

    public convenience init(
        argv: [String] = [],
        env: [String: String],
        childShell: ChildShell = .inProcess,
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        // Convenience: pre-frozen dict → DictionaryEnvProvider.
        self.init(
            argvProvider: StaticArgvProvider(argv),
            envProvider: DictionaryEnvProvider(env),
            childShell: childShell,
            stdout: stdout,
            stderr: stderr
        )
    }

    public convenience init(
        argv: [String] = [],
        envProvider: EnvProvider = OSEnvProvider(),
        childShell: ChildShell = .inProcess,
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.init(
            argvProvider: StaticArgvProvider(argv),
            envProvider: envProvider,
            childShell: childShell,
            stdout: stdout,
            stderr: stderr
        )
    }

    public init(
        argvProvider: ArgvProvider,
        envProvider: EnvProvider = OSEnvProvider(),
        childShell: ChildShell = .inProcess,
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        // Wrapper init is non-failable — it preconditionFailure's
        // internally if JSGlobalContextCreate returns nil.
        let ctx = JSContext()
        self.context = ctx
        self.argvProvider = argvProvider
        self.envProvider = envProvider
        self.childShell = childShell
        self.stdout = stdout
        self.stderr = stderr

        ctx.exceptionHandler = { [weak self] _, exception in
            guard let self, let exception else { return }
            // Internal marker used by `process.exit` to unwind the run
            // loop — not a real exception, so don't print.
            if exception.objectForKeyedSubscript("__swiftjs_exit").toBool() {
                return
            }
            self.stderr(self.formatException(exception))
            if !self.didExit { self.exitCode = 1 }
        }

        installGlobals()
        installModules()
        installTimers()
        installFetch()
    }

    /// Run a JS source string. `name` is used in stack traces.
    /// ESM `import`/`export` is rewritten to CommonJS before
    /// evaluation — see `ESMRewriter`.
    @discardableResult
    public func run(_ source: String, name: String = "<anonymous>") -> JSValue? {
        let stripped = stripShebang(source)
        let rewritten = ESMRewriter.rewrite(stripped)
        let url = URL(fileURLWithPath: name)
        let result = context.evaluateScript(rewritten, withSourceURL: url)
        drainPendingWorkIfNeeded()
        return result
    }

    /// Fire any `process.on('exit', fn)` callbacks. Called by the
    /// CLI just before `exit(code)`, and by tests that want to
    /// observe the same lifecycle.
    public func fireExitListeners() {
        let codeArg = JSValue(int32: exitCode, in: context)!
        for listener in exitListeners {
            _ = listener.call(withArguments: [codeArg])
        }
        exitListeners.removeAll()
    }

    /// Run a `.js` file from disk. Honours shebang on the first line
    /// and sets `__filename`/`__dirname` as globals for the entry
    /// script (Node's CommonJS contract).
    @discardableResult
    public func runFile(_ path: String) throws -> JSValue? {
        let url = URL(fileURLWithPath: path)
        let source = try String(contentsOf: url, encoding: .utf8)
        let prev = currentScriptPath
        currentScriptPath = url.path
        defer { currentScriptPath = prev }

        // Set __filename/__dirname for the top-level script. Inside
        // require()-loaded modules these are scoped via the CommonJS
        // wrapper, but the entry script is evaluated at the global
        // scope so we expose them as globals.
        setGlobal("__filename", url.path)
        setGlobal("__dirname", (url.path as NSString).deletingLastPathComponent)
        // Pass the absolute path as the sourceURL so stack traces and
        // the code-frame on uncaught exceptions resolve back to the
        // real on-disk file (rather than a basename relative to cwd).
        return run(source, name: url.path)
    }

    /// Re-sync `process.argv` from the current `argvProvider` value.
    /// Useful when a ``ShellArgvProvider``'s positional parameters
    /// change between `run` calls and a long-lived runtime needs
    /// the new view.
    public func refreshArgv() {
        let process = context.objectForKeyedSubscript("process")!
        process.setObject(argvProvider.argv(),
                          forKeyedSubscript: "argv" as NSString)
    }

    /// Block until pending timers drain (or `process.exit` is called).
    /// Mirrors Node's "exit when the event loop is empty" behaviour.
    func drainPendingWorkIfNeeded() {
        guard !didExit, !pendingTimers.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }
        while !didExit && !pendingTimers.isEmpty {
            // Run one short slice of the runloop so timer callbacks
            // (which are dispatched onto the main queue from
            // installTimers) get a chance to fire.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func stripShebang(_ source: String) -> String {
        guard source.hasPrefix("#!") else { return source }
        if let newline = source.firstIndex(of: "\n") {
            return "//" + source[source.index(after: source.startIndex)..<newline] + source[newline...]
        }
        return ""
    }
}

// MARK: - Helpers shared across the layer files.

extension JSRuntime {
    /// Convenience for setting a global on the context.
    func setGlobal(_ name: String, _ value: Any) {
        context.setObject(value, forKeyedSubscript: name as NSString)
    }

    /// Build a JS object from a `[String: Any]` description, treating
    /// closure values as native functions. Used to register builtin
    /// modules (fs, path, etc).
    func makeJSObject(_ entries: [String: Any]) -> JSValue {
        let obj = JSValue(newObjectIn: context)!
        for (key, value) in entries {
            obj.setObject(value, forKeyedSubscript: key as NSString)
        }
        return obj
    }

    /// Wrap a Swift closure as a JS-callable function value. Replaces
    /// the Apple-only `@convention(block)` + `unsafeBitCast` pattern
    /// the runtime used to use — the new wrapper layer goes through
    /// JSC's C API (`JSObjectMakeFunctionWithCallback`-style class
    /// machinery in `JSCallback.swift`) so the same code works on
    /// every platform with a JSC backend.
    ///
    /// Per-callsite migration: a typed
    /// `let f: @convention(block) (T1, T2) -> R = { a, b in ... }`
    /// becomes `let f = block { args in /* unpack args[0]/args[1] */ }`,
    /// and the consumer's `setObject(block(f as AnyObject), …)`
    /// becomes `setObject(f, …)` since `block` already returns a
    /// JSValue ready to assign.
    func block(_ closure: @escaping ([JSValue]) -> Any?) -> JSValue {
        JSValue(callback: closure, in: context)
    }

    /// Throw a JS Error in the current context, returning the
    /// exception so callers can `return` it.
    @discardableResult
    func throwJS(_ message: String) -> JSValue? {
        guard let ctx = JSContext.current() else { return nil }
        let err = JSValue(newErrorFromMessage: message, in: ctx)
        ctx.exception = err
        return err
    }

    /// Throw a JS Error decorated with the Node-style fields the
    /// ecosystem expects (`code`, plus any extras the caller wants to
    /// attach). Returns the exception so callers can `return` it from
    /// `Any?`-typed bridge blocks.
    @discardableResult
    func throwJSError(
        _ message: String,
        code: String? = nil,
        extras: [String: Any] = [:]
    ) -> JSValue? {
        guard let ctx = JSContext.current() ?? Optional(context) else { return nil }
        guard let err = JSValue(newErrorFromMessage: message, in: ctx) else { return nil }
        if let code { err.setObject(code, forKeyedSubscript: "code" as NSString) }
        for (key, value) in extras { err.setObject(value, forKeyedSubscript: key as NSString) }
        ctx.exception = err
        return err
    }

    /// Build (but do not throw) a JS Error with `code` and extras.
    /// Used by async paths that need to reject a Promise rather than
    /// set `ctx.exception`.
    func makeJSError(
        _ message: String,
        in ctx: JSContext,
        code: String? = nil,
        extras: [String: Any] = [:]
    ) -> JSValue {
        let err = JSValue(newErrorFromMessage: message, in: ctx)!
        if let code { err.setObject(code, forKeyedSubscript: "code" as NSString) }
        for (key, value) in extras { err.setObject(value, forKeyedSubscript: key as NSString) }
        return err
    }

    /// Throw a Node-shaped fs/system error. Pulls the POSIX errno out
    /// of the underlying Foundation error so we can emit the same
    /// `ENOENT: no such file or directory, open '/x'` shape Node does,
    /// with `.code`, `.errno`, `.syscall`, `.path` set on the Error.
    @discardableResult
    func throwSystemError(
        _ error: Error,
        syscall: String,
        path: String? = nil
    ) -> JSValue? {
        let errno = Self.posixErrno(from: error)
        let code = Self.posixCodeName(errno)
        let desc = Self.posixDescription(errno, fallback: error.localizedDescription)
        var msg = "\(code): \(desc), \(syscall)"
        if let path { msg += " '\(path)'" }
        var extras: [String: Any] = [
            "errno": Int(-errno),
            "syscall": syscall
        ]
        if let path { extras["path"] = path }
        return throwJSError(msg, code: code, extras: extras)
    }

    // POSIX errno helpers (`posixErrno`, `posixCodeName`,
    // `posixDescription`) live in `JSRuntime+POSIX.swift`.

    // Exception formatting (`formatException`, `nonEmpty`, `codeFrame`)
    // lives in `JSRuntime+Exception.swift`.
}
#endif  // !os(Windows)
