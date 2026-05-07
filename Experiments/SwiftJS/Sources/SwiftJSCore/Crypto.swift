import Foundation
import JavaScriptCore
import CryptoKit

#if canImport(JavaScriptCore)

extension JSRuntime {

    /// Builds the `node:crypto` module:
    ///   - createHash('sha256'|'sha1'|'sha512'|'md5')
    ///         .update(value).digest('hex'|'base64'|'utf-8')
    ///   - createHmac(algo, key).update(value).digest(encoding)
    ///   - randomBytes(n) → Buffer
    ///   - randomUUID() → string
    ///   - timingSafeEqual(a, b) → boolean
    ///
    /// CryptoKit is built into the Apple SDK so no extra dependency.
    func makeCryptoModule() -> JSValue {
        let crypto = JSValue(newObjectIn: context)!

        // createHash returns a "hasher" object that mutates internal
        // state on each `.update()` and yields a Buffer/string on
        // `.digest()`. We don't need to bridge a streaming Hasher
        // across the JS↔Swift boundary because the data lifetime of a
        // single hash op is short — accumulate bytes in a JS-owned
        // Buffer and finalize on digest.
        let createHash: @convention(block) (String) -> JSValue? = { [weak self] algorithm in
            guard let self else { return nil }
            return self.makeHasher(algorithm: algorithm.lowercased(), key: nil)
        }
        crypto.setObject(block(createHash as AnyObject),
                         forKeyedSubscript: "createHash" as NSString)

        let createHmac: @convention(block) (String, JSValue) -> JSValue? = { [weak self] algorithm, key in
            guard let self else { return nil }
            let keyBytes = Self.bytesFor(key)
            return self.makeHasher(algorithm: algorithm.lowercased(), key: keyBytes)
        }
        crypto.setObject(block(createHmac as AnyObject),
                         forKeyedSubscript: "createHmac" as NSString)

        let randomBytes: @convention(block) (Int) -> JSValue? = { [weak self] count in
            guard let self else { return nil }
            var bytes = [UInt8](repeating: 0, count: max(0, count))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let bufCtor = self.context.objectForKeyedSubscript("Buffer")!
            return bufCtor.invokeMethod("from", withArguments: [bytes])
        }
        crypto.setObject(block(randomBytes as AnyObject),
                         forKeyedSubscript: "randomBytes" as NSString)

        let randomUUID: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        crypto.setObject(block(randomUUID as AnyObject),
                         forKeyedSubscript: "randomUUID" as NSString)

        let timingSafeEqual: @convention(block) (JSValue, JSValue) -> Bool = { a, b in
            let aBytes = Self.bytesFor(a)
            let bBytes = Self.bytesFor(b)
            guard aBytes.count == bBytes.count else { return false }
            var diff: UInt8 = 0
            for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
            return diff == 0
        }
        crypto.setObject(block(timingSafeEqual as AnyObject),
                         forKeyedSubscript: "timingSafeEqual" as NSString)

        return crypto
    }

    /// Build a JS object that accumulates input via `.update(value)`
    /// and produces a digest via `.digest(encoding?)`. Mirrors
    /// node:crypto's chainable Hash/Hmac shape.
    private func makeHasher(algorithm: String, key: [UInt8]?) -> JSValue? {
        let ctx = context
        // Mutable storage lives in a Swift class boxed into the JS
        // object — easier than serialising state through JS.
        let state = HashState(algorithm: algorithm, key: key)

        let obj = JSValue(newObjectIn: ctx)!

        let update: @convention(block) (JSValue) -> JSValue? = { [obj] value in
            state.append(Self.bytesFor(value))
            return obj // chainable
        }
        obj.setObject(block(update as AnyObject),
                      forKeyedSubscript: "update" as NSString)

        let digest: @convention(block) (JSValue?) -> Any? = { [weak self] encoding in
            guard let self else { return nil }
            guard let bytes = state.finalize() else {
                return self.throwJS("Unsupported hash algorithm: \(algorithm)")
            }
            if let encoding, encoding.isString {
                let enc = encoding.toString()?.lowercased() ?? "hex"
                switch enc {
                case "hex":     return bytes.map { String(format: "%02x", $0) }.joined()
                case "base64":  return Data(bytes).base64EncodedString()
                case "utf-8", "utf8":
                                return String(decoding: bytes, as: UTF8.self)
                default:        return bytes.map { String(format: "%02x", $0) }.joined()
                }
            }
            // No encoding → Buffer.
            let bufCtor = self.context.objectForKeyedSubscript("Buffer")!
            return bufCtor.invokeMethod("from", withArguments: [bytes])
        }
        obj.setObject(block(digest as AnyObject),
                      forKeyedSubscript: "digest" as NSString)

        return obj
    }

    /// Pull a `[UInt8]` from a JSValue that's a string, Uint8Array,
    /// Buffer, or array of numbers.
    static func bytesFor(_ value: JSValue) -> [UInt8] {
        if value.isString {
            return Array((value.toString() ?? "").utf8)
        }
        if let arr = value.toArray() as? [NSNumber] {
            return arr.map { $0.uint8Value }
        }
        if let arr = value.toArray() {
            return arr.compactMap { ($0 as? NSNumber)?.uint8Value }
        }
        return []
    }
}

/// Hash/HMAC accumulator. Held by reference inside the JSValue so
/// `update().update().digest()` chains work without copying the
/// running buffer through JS.
private final class HashState {
    let algorithm: String
    let key: [UInt8]?
    private var buffer: [UInt8] = []

    init(algorithm: String, key: [UInt8]?) {
        self.algorithm = algorithm
        self.key = key
    }

    func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    func finalize() -> [UInt8]? {
        let data = Data(buffer)
        if let key {
            let symmetric = SymmetricKey(data: Data(key))
            switch algorithm {
            case "sha256":
                return Array(HMAC<SHA256>.authenticationCode(for: data, using: symmetric))
            case "sha1":
                return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetric))
            case "sha512":
                return Array(HMAC<SHA512>.authenticationCode(for: data, using: symmetric))
            case "md5":
                return Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetric))
            default:
                return nil
            }
        }
        switch algorithm {
        case "sha256": return Array(SHA256.hash(data: data))
        case "sha384": return Array(SHA384.hash(data: data))
        case "sha512": return Array(SHA512.hash(data: data))
        case "sha1":   return Array(Insecure.SHA1.hash(data: data))
        case "md5":    return Array(Insecure.MD5.hash(data: data))
        default:       return nil
        }
    }
}
#endif
