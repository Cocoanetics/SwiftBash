// Swift ⟷ JS type bridging. Used by `JSValue(object:in:)`, the
// keyed-subscript setter, the call/invoke argument lists, and the
// closure trampoline's return-value conversion.
//
// Mirrors the surface of Apple's `JSValue(object:in:)`:
// strings → JS string, numbers → JS number, bool → JS boolean,
// `NSNull` / nil → JS null, `[Any]` → JS Array, `[String: Any]` →
// JS object, `Data` / `[UInt8]` → JS Array of byte numbers
// (matching Apple's NSArray-of-NSNumber bridging). Closures / blocks
// are NOT handled here — they go through `JSValue(callback:in:)`
// in `JSCallback.swift`.
import Foundation
import CJavaScriptCore

extension JSValue {

    /// Convert a Swift native to a `JSValueRef` that can be set as a
    /// property, passed as an argument, or wrapped in a JSValue.
    /// Returns `nil` only on JSC-side allocation failure (extremely
    /// rare).
    ///
    /// Type mapping:
    /// - `nil`, `NSNull`              → `null`
    /// - `Bool` / `NSNumber` (bool)   → JS boolean
    /// - any numeric type             → JS number
    /// - `String` / `NSString`        → JS string
    /// - `[UInt8]` / `Data`           → JS Array of byte numbers
    /// - `[Any]` / `NSArray`          → JS Array (recursive)
    /// - `[String: Any]` / `NSDictionary` → JS object (recursive)
    /// - existing `JSValue`           → its underlying ref
    /// - anything else                → JS string of `String(describing:)`
    static func bridgeToJS(_ value: Any?, in context: JSContext) -> JSValueRef? {
        guard let value = value else {
            return JSValueMakeNull(context.raw)
        }
        if value is NSNull {
            return JSValueMakeNull(context.raw)
        }

        // Existing JSValue — bypass conversion. The caller's already
        // produced an engine-owned ref.
        if let v = value as? JSValue {
            return v.raw
        }

        // Bool needs to come BEFORE NSNumber — NSNumber matches `Bool`
        // through ObjC bridging and would silently convert `true` to
        // `1` (number) on Apple. Foundation bridging on Linux behaves
        // similarly enough that we explicit-check.
        if let b = value as? Bool {
            return JSValueMakeBoolean(context.raw, b)
        }
        // ObjCBool (rare but happens via NSNumber bridging on Apple)
        #if canImport(Darwin)
        if let nsn = value as? NSNumber, isNSNumberBool(nsn) {
            return JSValueMakeBoolean(context.raw, nsn.boolValue)
        }
        #endif

        // Numbers — try the common Swift types in order, then fall
        // back to NSNumber.
        if let i = value as? Int    { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? Int32  { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? Int64  { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? UInt   { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? UInt32 { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? UInt64 { return JSValueMakeNumber(context.raw, Double(i)) }
        if let i = value as? UInt8  { return JSValueMakeNumber(context.raw, Double(i)) }
        if let d = value as? Double { return JSValueMakeNumber(context.raw, d) }
        if let f = value as? Float  { return JSValueMakeNumber(context.raw, Double(f)) }
        if let n = value as? NSNumber {
            return JSValueMakeNumber(context.raw, n.doubleValue)
        }

        // Strings.
        if let s = value as? String {
            let ref = JSStringCreateWithUTF8CString(s)
            defer { JSStringRelease(ref) }
            return JSValueMakeString(context.raw, ref)
        }
        if let s = value as? NSString {
            let ref = JSStringCreateWithUTF8CString(s as String)
            defer { JSStringRelease(ref) }
            return JSValueMakeString(context.raw, ref)
        }

        // Byte arrays — bridge to JS Array of numbers, matching the
        // Apple ObjC API's NSArray-of-NSNumber semantics. Modern code
        // that wants a typed array calls `Buffer.from(...)` on the
        // result; it accepts either shape.
        if let bytes = value as? [UInt8] {
            return jsArray(bytes.map { Int($0) }, in: context)
        }
        if let data = value as? Data {
            return jsArray(data.map { Int($0) }, in: context)
        }

        // Heterogeneous arrays.
        if let arr = value as? [Any] {
            return jsArray(arr, in: context)
        }
        if let arr = value as? NSArray {
            return jsArray(arr as! [Any], in: context)
        }

        // Dictionaries.
        if let dict = value as? [String: Any] {
            return jsDictionary(dict, in: context)
        }
        if let dict = value as? NSDictionary {
            var swiftDict: [String: Any] = [:]
            for (k, v) in dict {
                swiftDict[String(describing: k)] = v
            }
            return jsDictionary(swiftDict, in: context)
        }

        // Fallback — describe and stringify. SwiftJSCore historically
        // never reaches here for legitimate values; better to render
        // something visible than silently produce `undefined`.
        let ref = JSStringCreateWithUTF8CString(String(describing: value))
        defer { JSStringRelease(ref) }
        return JSValueMakeString(context.raw, ref)
    }

    private static func jsArray(_ values: [Any],
                                in context: JSContext) -> JSValueRef? {
        let elementRefs = values.compactMap { bridgeToJS($0, in: context) }
        var buffer: [JSValueRef?] = elementRefs
        var exception: JSValueRef?
        let arr = buffer.withUnsafeMutableBufferPointer { buf in
            JSObjectMakeArray(context.raw, buf.count, buf.baseAddress,
                              &exception)
        }
        return arr
    }

    private static func jsDictionary(_ dict: [String: Any],
                                     in context: JSContext) -> JSValueRef? {
        guard let obj = JSObjectMake(context.raw, nil, nil) else { return nil }
        for (key, value) in dict {
            let keyRef = JSStringCreateWithUTF8CString(key)
            defer { JSStringRelease(keyRef) }
            guard let propRef = bridgeToJS(value, in: context) else { continue }
            var exception: JSValueRef?
            JSObjectSetProperty(context.raw, obj, keyRef, propRef,
                                JSPropertyAttributes(kJSPropertyAttributeNone),
                                &exception)
        }
        return obj
    }

    #if canImport(Darwin)
    /// `NSNumber` boxes `Bool` and `Int` indistinguishably under
    /// ObjC bridging. The CFBoolean trick is the canonical way to
    /// tell them apart at runtime.
    private static func isNSNumberBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    #endif
}
