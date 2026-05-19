#if !os(Windows)

// SwiftJSCore's `JSContext` — a Swift class wrapping the JSC C API's
// `JSGlobalContextRef`. Replaces the platform `JSContext` ObjC class
// from Apple's `JavaScriptCore.framework` so the same source compiles
// against Apple's framework JSC and Bun's vendored static archive
// (oven-sh/WebKit autobuild). Both ship the same C API headers; this
// class talks to that C API and nothing else.
//
// Single-threaded by design — the JSC C API has thread-affinity
// rules and SwiftJSCore consumers do all engine work on one queue.
// `JSContext.current()` and `JSContext.currentArguments()` are
// implemented with thread-local storage so callbacks running inside
// `JSEvaluateScript` see the right context, matching the Apple ObjC
// class's semantics.
import Foundation
import CJavaScriptCore

public final class JSContext {

    // MARK: - Storage

    /// The owned `JSGlobalContextRef`. Released in `deinit` unless
    /// `ownsContext == false` (the non-owning init used by the
    /// callback trampoline's fallback path).
    let raw: JSGlobalContextRef

    /// `true` when this wrapper owns its underlying context — the
    /// normal case via the public `init()`. `false` for ephemeral
    /// wrappers built by the callback trampoline when a registered
    /// Swift `JSContext` can't be found for the C ref.
    private let ownsContext: Bool

    /// Most recent uncaught exception. Set by `evaluateScript` when
    /// the engine raises; settable from a native callback to throw
    /// out of it (the trampoline reads this slot when the closure
    /// returns and writes to the C `exception` out-parameter).
    public var exception: JSValue?

    /// Fired when JS raises an exception that no JSC callback
    /// trampoline frame is on the call stack to drain — i.e. the
    /// throw escaped into the host (top-level `evaluateScript`, a
    /// timer's fire callback, an exit listener). Mirrors
    /// `JSContext.exceptionHandler` from Apple's ObjC API. Throws
    /// raised inside a native callback are left in `self.exception`
    /// instead so the trampoline can route them back to a JS
    /// `try/catch`.
    public var exceptionHandler: ((JSContext?, JSValue?) -> Void)?

    // MARK: - Lifecycle

    public init() {
        guard let ctx = JSGlobalContextCreate(nil) else {
            preconditionFailure(
                "JSGlobalContextCreate returned nil — the engine " +
                "is in an unrecoverable state.")
        }
        self.raw = ctx
        self.ownsContext = true
        registerForCallbacks()
    }

    /// Non-owning wrapper used by the callback trampoline's fallback
    /// path when a registered Swift `JSContext` can't be located.
    /// Doesn't retain or release the underlying context.
    init(rawNonOwning ctx: JSGlobalContextRef) {
        self.raw = ctx
        self.ownsContext = false
    }

    deinit {
        if ownsContext {
            unregisterForCallbacks()
            // `exception` and any user-held JSValues hold protect
            // counts against this context's GC; `JSGlobalContextRelease`
            // only tears the engine state down once those have
            // dropped.
            //
            // Skip the release on non-Apple to dodge a known
            // shutdown stall in Bun's prebuilt JSC archive — the
            // bmalloc heap shutdown asserts ~62s after teardown
            // begins (see `swift-jsc-smoke` for the same workaround
            // and Docs/SwiftJS.md § Cross-platform for context).
            // Memory leaks per-context are bounded; fix lands when
            // upstream resolves the assert.
            #if canImport(Darwin)
            JSGlobalContextRelease(raw)
            #endif
        }
    }

    // MARK: - Script evaluation

    /// Evaluate a JS source string. Returns the script's completion
    /// value, or `nil` if the script raised an unhandled exception
    /// (in which case `exception` is set and `exceptionHandler` was
    /// called).
    @discardableResult
    public func evaluateScript(_ source: String,
                               withSourceURL sourceURL: URL? = nil) -> JSValue? {
        let scriptRef = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(scriptRef) }

        var sourceURLRef: JSStringRef?
        if let sourceURL = sourceURL {
            sourceURLRef = JSStringCreateWithUTF8CString(sourceURL.absoluteString)
        }
        defer { if let ref = sourceURLRef { JSStringRelease(ref) } }

        var exceptionOut: JSValueRef?
        let resultRef = JSEvaluateScript(raw, scriptRef, nil,
                                         sourceURLRef, 0, &exceptionOut)

        if let exRef = exceptionOut {
            reportUncaught(exRef)
            return nil
        }
        return resultRef.map { JSValue(ref: $0, in: self) }
    }

    /// Capture an exception raised by a C-API call (`JSEvaluateScript`,
    /// `JSObjectCallAsFunction`, `JSObjectCallAsConstructor`). Always
    /// stores it on `self.exception`, and additionally fires
    /// `exceptionHandler` when there is no active JSC callback
    /// trampoline frame — i.e. when the host (a timer's
    /// `setEventHandler`, the CLI's top-level `run`, or an exit
    /// listener) is the direct caller, so no JS-side `catch` will
    /// see the throw. Inside a trampoline we just store, because the
    /// trampoline drains `self.exception` back into JSC's `exception`
    /// out-parameter and any surrounding `try/catch` handles the rest.
    func reportUncaught(_ ref: JSValueRef) {
        let exVal = JSValue(ref: ref, in: self)
        self.exception = exVal
        if JSContext.current() == nil {
            exceptionHandler?(self, exVal)
        }
    }

    // MARK: - Global-object access

    /// The global object as a `JSValue`. JSC's API guarantees this is
    /// always present.
    public var globalObject: JSValue {
        // Force-unwrap is safe — JSContextGetGlobalObject can't
        // return nil for a live context.
        JSValue(ref: JSContextGetGlobalObject(raw)!, in: self)
    }

    /// Get a property of the global object. Mirrors Apple's
    /// `JSContext.objectForKeyedSubscript(_:)` — IUO return so
    /// callers can chain `.toBool()` etc. without `?` unwrapping.
    public func objectForKeyedSubscript(_ key: Any) -> JSValue! {
        globalObject.objectForKeyedSubscript(key)
    }

    /// Set a property of the global object. Mirrors Apple's
    /// `JSContext.setObject(_:forKeyedSubscript:)`.
    public func setObject(_ value: Any?, forKeyedSubscript key: Any) {
        globalObject.setObject(value, forKeyedSubscript: key)
    }

    public subscript(key: String) -> JSValue? {
        get { objectForKeyedSubscript(key) }
        set { setObject(newValue, forKeyedSubscript: key) }
    }

    // MARK: - Thread-local current / currentArguments

    // Apple's ObjC API exposes these as static methods on JSContext —
    // they reflect the context and arguments of the currently-
    // executing native callback. JSC's C API has no equivalent, so we
    // maintain a thread-local stack pushed/popped by the callback
    // trampoline. SwiftJSCore is single-threaded per context, so a
    // simple stack-per-thread is sufficient and safe.

    private static let currentKey = "swift.jsc.currentContextStack"
    private static let argsKey = "swift.jsc.currentArgsStack"

    /// The `JSContext` of the currently-executing native callback,
    /// or `nil` if called outside a callback.
    public static func current() -> JSContext? {
        let stack = Thread.current.threadDictionary[currentKey]
            as? [WeakRef<JSContext>] ?? []
        return stack.last?.value
    }

    /// The arguments passed to the currently-executing native
    /// callback, or `nil` outside one. Returns `[Any]` to match the
    /// Apple ObjC API's signature; values are `JSValue` instances.
    public static func currentArguments() -> [Any]? {
        let stack = Thread.current.threadDictionary[argsKey]
            as? [[JSValue]] ?? []
        return stack.last
    }

    static func pushCurrent(_ ctx: JSContext, args: [JSValue]) {
        var ctxs = Thread.current.threadDictionary[currentKey]
            as? [WeakRef<JSContext>] ?? []
        ctxs.append(WeakRef(ctx))
        Thread.current.threadDictionary[currentKey] = ctxs

        var argStack = Thread.current.threadDictionary[argsKey]
            as? [[JSValue]] ?? []
        argStack.append(args)
        Thread.current.threadDictionary[argsKey] = argStack
    }

    static func popCurrent() {
        if var ctxs = Thread.current.threadDictionary[currentKey]
            as? [WeakRef<JSContext>], !ctxs.isEmpty {
            ctxs.removeLast()
            Thread.current.threadDictionary[currentKey] = ctxs
        }
        if var argStack = Thread.current.threadDictionary[argsKey]
            as? [[JSValue]], !argStack.isEmpty {
            argStack.removeLast()
            Thread.current.threadDictionary[argsKey] = argStack
        }
    }
}

/// Thread-local stack entries hold the context weakly so a context
/// release inside a nested callback doesn't accidentally outlive the
/// runtime's own ownership chain.
final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
#endif  // !os(Windows)
