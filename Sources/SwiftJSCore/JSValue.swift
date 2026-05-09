// SwiftJSCore's `JSValue` — Swift class wrapping `JSValueRef` /
// `JSObjectRef` from JSC's C API. Replaces the platform `JSValue`
// ObjC class so SwiftJSCore source compiles unchanged on every
// platform with a working JSC backend (Apple framework, Bun's
// vendored static archive). See `JSContext.swift` for the wider
// design rationale.
//
// Memory: every `JSValue` instance protects its `JSValueRef` against
// collection by JSC's GC for as long as the wrapper lives. The
// protect count is incremented in `init` and decremented in `deinit`,
// so JSValues survive across run-loop turns and async boundaries the
// way Apple's ObjC class does.
import Foundation
import CJavaScriptCore

public final class JSValue {

    // MARK: - Storage

    /// The underlying value. For object-flavoured values (objects,
    /// functions, arrays) this is also a valid `JSObjectRef`; the
    /// `asObject` accessor returns it under that type.
    let raw: JSValueRef

    /// Owning context. **Strong** to match Apple's
    /// `JSValue.context` semantics — JSValues sometimes outlive the
    /// caller's last reference to JSContext (caches, closure
    /// captures, deferred Promise handlers), and an `unowned` ref
    /// would dangle into a destroyed object the moment a deinit
    /// chain unwound through the JSContext first. The trade-off is
    /// a small retain cycle when JSContext caches a JSValue (e.g.
    /// `ctx.exception`); that's the same trade-off Apple's API
    /// makes, and JSContext's lifetime is bounded to the runtime
    /// in practice anyway.
    public let context: JSContext

    // MARK: - Lifecycle

    /// Adopt a raw `JSValueRef` already produced by JSC. Increments
    /// the protect count so the value survives until this wrapper's
    /// deinit drops it.
    init(ref: JSValueRef, in context: JSContext) {
        self.raw = ref
        self.context = context
        JSValueProtect(context.raw, ref)
    }

    deinit {
        JSValueUnprotect(context.raw, raw)
    }

    // MARK: - Convenience initializers (Apple-API-shape)

    public convenience init?(int32 value: Int32, in context: JSContext) {
        guard let ref = JSValueMakeNumber(context.raw, Double(value))
        else { return nil }
        self.init(ref: ref, in: context)
    }

    public convenience init?(double value: Double, in context: JSContext) {
        guard let ref = JSValueMakeNumber(context.raw, value) else { return nil }
        self.init(ref: ref, in: context)
    }

    public convenience init?(bool value: Bool, in context: JSContext) {
        guard let ref = JSValueMakeBoolean(context.raw, value) else { return nil }
        self.init(ref: ref, in: context)
    }

    public convenience init?(newObjectIn context: JSContext) {
        guard let obj = JSObjectMake(context.raw, nil, nil) else { return nil }
        self.init(ref: obj, in: context)
    }

    public convenience init?(newArrayIn context: JSContext) {
        var exception: JSValueRef?
        guard let arr = JSObjectMakeArray(context.raw, 0, nil, &exception)
        else { return nil }
        self.init(ref: arr, in: context)
    }

    public convenience init?(newErrorFromMessage message: String,
                             in context: JSContext) {
        let messageRef = JSStringCreateWithUTF8CString(message)
        defer { JSStringRelease(messageRef) }

        var args: [JSValueRef?] = [JSValueMakeString(context.raw, messageRef)]
        var exception: JSValueRef?
        let err = args.withUnsafeMutableBufferPointer { buf in
            JSObjectMakeError(context.raw, 1, buf.baseAddress, &exception)
        }
        guard let errRef = err else { return nil }
        self.init(ref: errRef, in: context)
    }

    /// Build a JSValue from a Swift native by recursively bridging
    /// strings, numbers, booleans, arrays, dictionaries, byte
    /// arrays, and `NSNull`. Mirrors the surface of Apple's
    /// `JSValue(object:in:)` for the types SwiftJSCore actually
    /// passes through.
    public convenience init?(object value: Any?, in context: JSContext) {
        guard let bridged = JSValue.bridgeToJS(value, in: context)
        else { return nil }
        self.init(ref: bridged, in: context)
    }

    // MARK: - Type predicates

    public var isUndefined: Bool { JSValueIsUndefined(context.raw, raw) }
    public var isNull: Bool      { JSValueIsNull(context.raw, raw) }
    public var isBoolean: Bool   { JSValueIsBoolean(context.raw, raw) }
    public var isNumber: Bool    { JSValueIsNumber(context.raw, raw) }
    public var isString: Bool    { JSValueIsString(context.raw, raw) }
    public var isObject: Bool    { JSValueIsObject(context.raw, raw) }
    public var isArray: Bool     { JSValueIsArray(context.raw, raw) }

    // MARK: - Conversions to Swift natives

    /// Convert to `String`. JS coercion semantics: `null` → "null",
    /// numbers stringify, etc. Returns `nil` only on JSC-side
    /// failure (rare).
    public func toString() -> String? {
        var exception: JSValueRef?
        guard let strRef = JSValueToStringCopy(context.raw, raw, &exception),
              exception == nil
        else { return nil }
        defer { JSStringRelease(strRef) }
        return JSValue.string(from: strRef)
    }

    public func toNumber() -> Double {
        var exception: JSValueRef?
        let n = JSValueToNumber(context.raw, raw, &exception)
        return exception == nil ? n : .nan
    }

    /// Implements the JS `ToInt32` abstract operation
    /// (https://tc39.es/ecma262/#sec-toint32):
    ///
    /// 1. NaN, +∞, −∞ → 0
    /// 2. otherwise, take the integer value (truncated towards 0),
    ///    reduce modulo 2^32, and reinterpret as a two's-complement
    ///    `Int32`.
    ///
    /// Doing this directly is important: `Int64(d)` traps on
    /// finite values outside `Int64`'s range, so the previous
    /// `Int32(truncatingIfNeeded: Int64(n))` shape would crash the
    /// host process whenever a script handed us a huge Number
    /// (e.g. through `process.exit(2 ** 53)` or a timer ID).
    public func toInt32() -> Int32 {
        let n = toNumber()
        guard n.isFinite else { return 0 }
        let truncated = n.rounded(.towardZero)
        let mod: Double = 4_294_967_296            // 2^32
        var u = truncated.truncatingRemainder(dividingBy: mod)
        if u < 0 { u += mod }                       // wrap to [0, 2^32)
        if u >= 2_147_483_648 { u -= mod }          // 2^31 → negative
        return Int32(u)
    }

    public func toBool() -> Bool {
        JSValueToBoolean(context.raw, raw)
    }

    /// Recursively unwrap to a Swift `[Any]?` for arrays. Matches
    /// Apple's `JSValue.toArray()`: regular JS Arrays, typed arrays
    /// (Uint8Array etc.), and any other array-like object with a
    /// numeric `length` property all walk by index.
    public func toArray() -> [Any]? {
        guard isObject, let obj = JSValueToObject(context.raw, raw, nil),
              let length = arrayLikeLength(obj: obj)
        else { return nil }

        var out: [Any] = []
        out.reserveCapacity(length)
        for i in 0..<length {
            guard let elt = JSObjectGetPropertyAtIndex(context.raw, obj,
                                                       UInt32(i), nil)
            else { out.append(NSNull()); continue }
            out.append(JSValue(ref: elt, in: context).toSwiftAny() ?? NSNull())
        }
        return out
    }

    /// True if this is a real JS Array, a typed array, or has a
    /// numeric `length` property — and return that length. Matches
    /// what Apple's `toArray()` walks.
    private func arrayLikeLength(obj: JSObjectRef) -> Int? {
        if isArray
            || JSValueGetTypedArrayType(context.raw, raw, nil) != kJSTypedArrayTypeNone {
            // Both have a `.length`; fall through to read it.
        }
        let lengthName = JSStringCreateWithUTF8CString("length")
        defer { JSStringRelease(lengthName) }
        var exception: JSValueRef?
        guard let lengthRef = JSObjectGetProperty(context.raw, obj,
                                                  lengthName, &exception),
              exception == nil,
              JSValueIsNumber(context.raw, lengthRef)
        else {
            // For non-array, non-typed-array, non-array-like objects
            // we keep Apple's semantics: `toArray()` returns nil.
            return (isArray
                || JSValueGetTypedArrayType(context.raw, raw, nil)
                    != kJSTypedArrayTypeNone) ? 0 : nil
        }
        return Int(JSValueToNumber(context.raw, lengthRef, nil))
    }

    /// Recursively unwrap to `[String: Any]?` for plain objects.
    public func toDictionary() -> [String: Any]? {
        guard isObject, !isArray,
              let obj = JSValueToObject(context.raw, raw, nil)
        else { return nil }
        guard let names = JSObjectCopyPropertyNames(context.raw, obj) else {
            return [:]
        }
        defer { JSPropertyNameArrayRelease(names) }
        let count = JSPropertyNameArrayGetCount(names)

        var out: [String: Any] = [:]
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let nameRef = JSPropertyNameArrayGetNameAtIndex(names, i)
            else { continue }
            let key = JSValue.string(from: nameRef)
            var exception: JSValueRef?
            guard let valRef = JSObjectGetProperty(context.raw, obj, nameRef,
                                                   &exception),
                  exception == nil
            else { continue }
            out[key] = JSValue(ref: valRef, in: context).toSwiftAny()
                ?? NSNull()
        }
        return out
    }

    /// Recursive native unwrap. Used by `toArray`/`toDictionary`
    /// and by the trampoline when bridging native return values.
    public func toSwiftAny() -> Any? {
        if isUndefined { return nil }
        if isNull      { return NSNull() }
        if isBoolean   { return toBool() }
        if isNumber    { return toNumber() }
        if isString    { return toString() ?? "" }
        if isArray     { return toArray() ?? [] }
        if isObject    { return toDictionary() ?? [:] }
        return nil
    }

    // MARK: - Property access

    /// Return type is `JSValue!` (implicitly unwrapped optional) to
    /// match Apple's ObjC-bridged shape — the runtime does
    /// `obj.objectForKeyedSubscript("k").toBool()` without `?`
    /// chaining in many places. The result is `nil` only when the
    /// receiver isn't an object; for plain "missing property"
    /// lookups JSC returns a `JSValueRef` for `undefined`.
    public func objectForKeyedSubscript(_ key: Any) -> JSValue! {
        guard let obj = JSValueToObject(context.raw, raw, nil) else { return nil }
        let keyString = JSValue.stringKey(from: key)
        let keyRef = JSStringCreateWithUTF8CString(keyString)
        defer { JSStringRelease(keyRef) }

        var exception: JSValueRef?
        guard let propRef = JSObjectGetProperty(context.raw, obj, keyRef,
                                                &exception),
              exception == nil
        else { return nil }
        return JSValue(ref: propRef, in: context)
    }

    public func setObject(_ value: Any?, forKeyedSubscript key: Any) {
        guard let obj = JSValueToObject(context.raw, raw, nil) else { return }
        let keyString = JSValue.stringKey(from: key)
        let keyRef = JSStringCreateWithUTF8CString(keyString)
        defer { JSStringRelease(keyRef) }

        guard let bridged = JSValue.bridgeToJS(value, in: context)
        else { return }
        var exception: JSValueRef?
        JSObjectSetProperty(context.raw, obj, keyRef, bridged,
                            JSPropertyAttributes(kJSPropertyAttributeNone),
                            &exception)
    }

    public subscript(key: String) -> JSValue? {
        get { objectForKeyedSubscript(key) }
        set { setObject(newValue, forKeyedSubscript: key) }
    }

    // MARK: - Invocation

    /// Call this value as a function, passing the given arguments.
    /// Returns `nil` (and stores a context exception) if the call
    /// raises.
    @discardableResult
    public func call(withArguments arguments: [Any]) -> JSValue? {
        guard let fn = JSValueToObject(context.raw, raw, nil) else { return nil }
        let argRefs = arguments.compactMap {
            JSValue.bridgeToJS($0, in: context)
        }
        var argRefsBuffer: [JSValueRef?] = argRefs
        var exception: JSValueRef?
        let result = argRefsBuffer.withUnsafeMutableBufferPointer { buf in
            JSObjectCallAsFunction(context.raw, fn, nil,
                                   buf.count, buf.baseAddress, &exception)
        }
        if let ex = exception {
            context.exception = JSValue(ref: ex, in: context)
            return nil
        }
        return result.map { JSValue(ref: $0, in: context) }
    }

    /// Look up a method on this value and call it. Returns `nil` if
    /// the property isn't callable or the call raises.
    @discardableResult
    public func invokeMethod(_ method: String,
                             withArguments arguments: [Any]) -> JSValue? {
        guard let receiver = JSValueToObject(context.raw, raw, nil)
        else { return nil }
        let methodNameRef = JSStringCreateWithUTF8CString(method)
        defer { JSStringRelease(methodNameRef) }

        var exception: JSValueRef?
        guard let propRef = JSObjectGetProperty(context.raw, receiver,
                                                methodNameRef, &exception),
              exception == nil,
              let fn = JSValueToObject(context.raw, propRef, nil)
        else { return nil }

        let argRefs = arguments.compactMap {
            JSValue.bridgeToJS($0, in: context)
        }
        var argRefsBuffer: [JSValueRef?] = argRefs
        let result = argRefsBuffer.withUnsafeMutableBufferPointer { buf in
            JSObjectCallAsFunction(context.raw, fn, receiver,
                                   buf.count, buf.baseAddress, &exception)
        }
        if let ex = exception {
            context.exception = JSValue(ref: ex, in: context)
            return nil
        }
        return result.map { JSValue(ref: $0, in: context) }
    }

    /// Use this value as a constructor (`new ...`).
    @discardableResult
    public func construct(withArguments arguments: [Any]) -> JSValue? {
        guard let ctor = JSValueToObject(context.raw, raw, nil)
        else { return nil }
        let argRefs = arguments.compactMap {
            JSValue.bridgeToJS($0, in: context)
        }
        var argRefsBuffer: [JSValueRef?] = argRefs
        var exception: JSValueRef?
        let result = argRefsBuffer.withUnsafeMutableBufferPointer { buf in
            JSObjectCallAsConstructor(context.raw, ctor,
                                      buf.count, buf.baseAddress, &exception)
        }
        if let ex = exception {
            context.exception = JSValue(ref: ex, in: context)
            return nil
        }
        return result.map { JSValue(ref: $0, in: context) }
    }

    // MARK: - Internal helpers

    /// Pull a Swift `String` out of a `JSStringRef`.
    /// Pull a Swift `String` out of a `JSStringRef`, preserving any
    /// embedded NUL bytes the JavaScript value contains.
    /// `JSStringGetUTF8CString` writes UTF-8 bytes followed by a
    /// trailing NUL and returns the total byte count *including* that
    /// terminator. Decoding from `[byte 0, written - 1)` keeps the
    /// JS string's own NULs in the result, where `String(cString:)`
    /// would silently truncate at the first one.
    static func string(from ref: JSStringRef) -> String {
        let maxLen = JSStringGetMaximumUTF8CStringSize(ref)
        guard maxLen > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: maxLen)
        let written = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return base.withMemoryRebound(to: CChar.self, capacity: maxLen) { cBase in
                JSStringGetUTF8CString(ref, cBase, maxLen)
            }
        }
        let byteCount = max(0, written - 1)
        return String(decoding: buffer.prefix(byteCount), as: UTF8.self)
    }

    /// Stringify any reasonable key shape — `String`, `NSString`,
    /// `Substring`, `JSValue` (whose `toString()` we call). Used by
    /// the keyed subscript accessors.
    static func stringKey(from key: Any) -> String {
        if let s = key as? String { return s }
        if let s = key as? NSString { return s as String }
        if let s = key as? Substring { return String(s) }
        if let v = key as? JSValue { return v.toString() ?? "" }
        return String(describing: key)
    }
}
