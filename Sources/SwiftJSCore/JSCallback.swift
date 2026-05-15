#if !os(Windows)

// Closure-as-JS-function plumbing. Replaces the Apple-only
// `JSValue(object: someBlock, in: ctx)` pattern that depends on
// ObjC's block-bridging machinery. Works on every platform with a
// JSC C API.
//
// Design: a single shared `JSClassRef` defines a callable JS object
// with a `callAsFunction` callback (the trampoline) and a `finalize`
// callback (to release the captured Swift closure when the JS object
// is collected). The trampoline reads the closure pointer from the
// JSObject's private slot, repackages C-side arguments as
// `[JSValue]`, pushes `JSContext.current()` / `currentArguments()`
// onto thread-local stacks, runs the closure, drains any
// `ctx.exception` set during the call, converts the closure's return
// value back through `bridgeToJS`, and returns.
import Foundation
import CJavaScriptCore

extension JSValue {

    /// Build a JS-callable function wrapping a Swift closure that
    /// receives `[JSValue]` and returns `Any?` (which goes through
    /// the standard Swift-to-JS bridging on the way out).
    public convenience init(callback: @escaping ([JSValue]) -> Any?,
                            in context: JSContext) {
        let box = JSCallbackBox(callback)
        let opaque = Unmanaged.passRetained(box).toOpaque()
        guard let object = JSObjectMake(context.raw, JSCallbackBox.classRef,
                                        opaque)
        else {
            // Failed to allocate — release the retain we just did to
            // avoid leaking the box.
            Unmanaged<JSCallbackBox>.fromOpaque(opaque).release()
            preconditionFailure("JSObjectMake returned nil for callback class")
        }
        self.init(ref: object, in: context)
    }
}

/// Heap-allocated owner for a Swift callback closure. The JSObject
/// holds the unmanaged retain in its private slot; the finalize
/// callback releases on collection.
final class JSCallbackBox {
    let invoke: ([JSValue]) -> Any?

    init(_ closure: @escaping ([JSValue]) -> Any?) {
        self.invoke = closure
    }

    /// The shared `JSClassRef` for callback objects. Lazily created
    /// once per process. JSC stores `JSClassDefinition.className`
    /// by reference and reads it indefinitely, so the buffer needs
    /// to outlive the JSClass — which is forever. We deliberately
    /// leak a heap copy here (one allocation per process) rather
    /// than relying on `NSString.utf8String`, which is deprecated
    /// on platforms without Objective-C autorelease pools.
    static let classRef: JSClassRef = {
        var def = JSClassDefinition()
        def.version = 0
        def.attributes = JSClassAttributes(kJSClassAttributeNone)
        def.className = JSCallbackBox.classNamePointer
        def.callAsFunction = jsCallbackTrampoline
        def.finalize = jsCallbackFinalize

        guard let cls = JSClassCreate(&def) else {
            preconditionFailure("JSClassCreate returned nil for callback class")
        }
        return cls
    }()

    /// Heap-allocated, NUL-terminated C string used as the
    /// callback JSClass's name. Allocated once at process start
    /// and never freed — `JSClassDefinition.className` is borrowed
    /// by JSC for the lifetime of the class, which matches the
    /// process. Replaces `("..." as NSString).utf8String` (deprecated
    /// on non-Apple platforms because they lack ObjC autorelease
    /// pools to keep the autoreleased buffer alive).
    private static let classNamePointer: UnsafePointer<CChar> = {
        let chars = Array("__SwiftJSCallback".utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
        chars.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                buffer.update(from: base, count: chars.count)
            }
        }
        return UnsafePointer(buffer)
    }()
}

// `@convention(c)` trampoline matching `JSObjectCallAsFunctionCallback`.
// Invoked by JSC every time a JS-side caller calls a closure-backed
// function object.
// swiftlint:disable:next line_length
private let jsCallbackTrampoline: JSObjectCallAsFunctionCallback = { ctxRef, function, _, argumentCount, arguments, exception in
    let ctxRef = ctxRef!  // C API guarantees non-null
    let function = function!

    guard let priv = JSObjectGetPrivate(function) else {
        return JSValueMakeUndefined(ctxRef)
    }
    let box = Unmanaged<JSCallbackBox>.fromOpaque(priv)
        .takeUnretainedValue()

    // The JSContextRef passed to the callback may be a sub-context;
    // promote to the global context that owns it so JSValueProtect
    // calls below match the ref pattern the Swift JSContext uses.
    let globalCtx = JSContextGetGlobalContext(ctxRef)!
    let context = JSContext.lookupOrEphemeral(for: globalCtx)

    // Convert C-side argument array to `[JSValue]`.
    var swiftArgs: [JSValue] = []
    swiftArgs.reserveCapacity(argumentCount)
    if let arguments = arguments {
        for index in 0..<argumentCount {
            if let argRef = arguments[index] {
                swiftArgs.append(JSValue(ref: argRef, in: context))
            } else {
                swiftArgs.append(
                    JSValue(ref: JSValueMakeUndefined(ctxRef)!, in: context))
            }
        }
    }

    // Apple-API parity: `JSContext.current()` and
    // `JSContext.currentArguments()` reflect the active callback.
    JSContext.pushCurrent(context, args: swiftArgs)
    defer { JSContext.popCurrent() }

    let result = box.invoke(swiftArgs)

    // If the callback `set ctx.exception = …` to throw, drain that
    // into the C exception out-parameter so JSC propagates it.
    if let pending = context.exception {
        context.exception = nil
        exception?.pointee = pending.raw
        return JSValueMakeUndefined(ctxRef)
    }

    if let result = result {
        if let bridged = JSValue.bridgeToJS(result, in: context) {
            return bridged
        }
    }
    return JSValueMakeUndefined(ctxRef)
}

/// `@convention(c)` finalizer that releases the unmanaged retain on
/// the box. Called by JSC's GC when the function object is collected.
private let jsCallbackFinalize: JSObjectFinalizeCallback = { object in
    guard let object = object,
          let priv = JSObjectGetPrivate(object)
    else { return }
    Unmanaged<JSCallbackBox>.fromOpaque(priv).release()
}

extension JSContext {
    // MARK: - Registry for callback context resolution

    private static var contextRegistry: [JSGlobalContextRef: WeakRef<JSContext>] = [:]

    /// Register a context so the trampoline can recover the Swift
    /// wrapper from a raw `JSGlobalContextRef`. Called from
    /// `JSContext.init`.
    func registerForCallbacks() {
        JSContext.contextRegistry[raw] = WeakRef(self)
    }

    /// Drop a context's registry entry. Called from `JSContext.deinit`.
    func unregisterForCallbacks() {
        JSContext.contextRegistry.removeValue(forKey: raw)
    }

    /// Look up the Swift `JSContext` wrapping a given C context. If
    /// the wrapper has been deallocated (shouldn't happen during
    /// normal callback lifetimes), construct an ephemeral, non-
    /// owning one — the caller uses it just for argument bridging
    /// within this callback's frame and drops it on return. JSC
    /// keeps the underlying context alive across the call.
    static func lookupOrEphemeral(for global: JSGlobalContextRef) -> JSContext {
        if let registered = contextRegistry[global]?.value {
            return registered
        }
        return JSContext(rawNonOwning: global)
    }
}
#endif  // !os(Windows)
