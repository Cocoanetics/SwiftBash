import Foundation
import JavaScriptCore

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
public final class JSRuntime {

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

    public convenience init(
        argv: [String] = [],
        env: [String: String],
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        // Convenience: pre-frozen dict → DictionaryEnvProvider.
        self.init(
            argvProvider: StaticArgvProvider(argv),
            envProvider: DictionaryEnvProvider(env),
            stdout: stdout,
            stderr: stderr
        )
    }

    public convenience init(
        argv: [String] = [],
        envProvider: EnvProvider = OSEnvProvider(),
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.init(
            argvProvider: StaticArgvProvider(argv),
            envProvider: envProvider,
            stdout: stdout,
            stderr: stderr
        )
    }

    public init(
        argvProvider: ArgvProvider,
        envProvider: EnvProvider = OSEnvProvider(),
        stdout: @escaping (String) -> Void = { Swift.print($0, terminator: "") },
        stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        guard let ctx = JSContext() else {
            preconditionFailure("Failed to create JSContext")
        }
        self.context = ctx
        self.argvProvider = argvProvider
        self.envProvider = envProvider
        self.stdout = stdout
        self.stderr = stderr

        ctx.exceptionHandler = { [weak self] _, exception in
            guard let self, let exception else { return }
            // Internal marker used by `process.exit` to unwind the run
            // loop — not a real exception, so don't print.
            if exception.objectForKeyedSubscript("__swiftjs_exit").toBool() {
                return
            }
            let message = exception.toString() ?? "<unknown>"
            let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
            self.stderr("\(message)\n\(stack)\n")
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
        for fn in exitListeners {
            _ = fn.call(withArguments: [codeArg])
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
        return run(source, name: url.lastPathComponent)
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
        for (k, v) in entries {
            obj.setObject(v, forKeyedSubscript: k as NSString)
        }
        return obj
    }

    /// Convert a Swift function-block reference into a JS-callable
    /// value the way `setObject` wants it. Centralised so the
    /// unsafeBitCast happens in one place.
    func block(_ closure: AnyObject) -> AnyObject {
        unsafeBitCast(closure, to: AnyObject.self)
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
}
