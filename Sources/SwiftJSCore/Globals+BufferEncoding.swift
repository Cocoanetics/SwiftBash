#if !os(Windows)

import Foundation

// MARK: - Buffer + encoding bridges
//
// JSC ships no TextEncoder/TextDecoder/Buffer/atob/btoa. We bridge
// the byte-level conversions from Swift, then build Buffer, the
// Text* classes, and atob/btoa as small JS shims on top. Split out
// of `Globals.swift` to keep that file under the file_length limit.

extension JSRuntime {

    // swiftlint:disable:next function_body_length - body is mostly an inline JS shim string
    func installBufferAndEncodingBridges() {
        // Swift bridges, exposed under `__swiftjs_native` so we can hide
        // them from user code (the JS shim deletes it after building
        // its API).
        let native = JSValue(newObjectIn: context)!

        let utf8Encode = block { args in
            guard let str = args.first?.toString() else { return [UInt8]() }
            return Array(str.utf8)
        }
        native.setObject(utf8Encode, forKeyedSubscript: "utf8Encode")

        let utf8Decode = block { args in
            guard let value = args.first else { return "" }
            // Accept either a Uint8Array or a plain Array of bytes.
            let bytes = Self.bytes(from: value)
            // swiftlint:disable:next optional_data_string_conversion - JS Buffer may hold partial UTF-8
            return String(decoding: bytes, as: UTF8.self)
        }
        native.setObject(utf8Decode, forKeyedSubscript: "utf8Decode")

        let toBase64 = block { args in
            guard let value = args.first else { return "" }
            return Data(Self.bytes(from: value)).base64EncodedString()
        }
        native.setObject(toBase64, forKeyedSubscript: "toBase64")

        let fromBase64 = block { args in
            guard let str = args.first?.toString() else { return [UInt8]() }
            return Array(Data(base64Encoded: str) ?? Data())
        }
        native.setObject(fromBase64, forKeyedSubscript: "fromBase64")

        let toHex = block { args in
            guard let value = args.first else { return "" }
            return Self.bytes(from: value).map { String(format: "%02x", $0) }.joined()
        }
        native.setObject(toHex, forKeyedSubscript: "toHex")

        let fromHex = block { args in
            guard let str = args.first?.toString() else { return [UInt8]() }
            return stride(from: 0, to: str.count, by: 2).compactMap { idx -> UInt8? in
                let start = str.index(str.startIndex, offsetBy: idx)
                let end = str.index(start, offsetBy: 2, limitedBy: str.endIndex) ?? str.endIndex
                return UInt8(str[start..<end], radix: 16)
            }
        }
        native.setObject(fromHex, forKeyedSubscript: "fromHex")

        setGlobal("__swiftjs_native", native)

        // The shim. Builds Buffer (extends Uint8Array), TextEncoder,
        // TextDecoder, atob, btoa, queueMicrotask. Then deletes the
        // bridge namespace.
        let shim = #"""
        (() => {
          const N = globalThis.__swiftjs_native;

          class Buffer extends Uint8Array {
            static from(value, encoding) {
              if (typeof value === "string") {
                if (encoding === "base64") return new Buffer(N.fromBase64(value));
                if (encoding === "hex") return new Buffer(N.fromHex(value));
                return new Buffer(N.utf8Encode(value));
              }
              if (value instanceof Uint8Array) return new Buffer(value);
              if (Array.isArray(value)) return new Buffer(value);
              if (value && typeof value === "object" && value.type === "Buffer" && Array.isArray(value.data)) {
                return new Buffer(value.data);
              }
              throw new TypeError("Buffer.from: unsupported argument");
            }
            static alloc(size, fill = 0) {
              const b = new Buffer(size);
              if (fill !== 0) b.fill(fill);
              return b;
            }
            static byteLength(s, encoding = "utf-8") {
              if (typeof s !== "string") return s.byteLength ?? s.length;
              if (encoding === "ascii" || encoding === "latin1") return s.length;
              return N.utf8Encode(s).length;
            }
            static isBuffer(b) { return b instanceof Buffer; }
            static concat(list, totalLength) {
              if (totalLength == null) {
                totalLength = list.reduce((n, b) => n + b.length, 0);
              }
              const out = new Buffer(totalLength);
              let off = 0;
              for (const b of list) {
                out.set(b.subarray(0, Math.min(b.length, totalLength - off)), off);
                off += b.length;
                if (off >= totalLength) break;
              }
              return out;
            }
            toString(encoding = "utf-8", start = 0, end = this.length) {
              const slice = this.subarray(start, end);
              const e = encoding.toLowerCase();
              if (e === "base64") return N.toBase64(slice);
              if (e === "hex") return N.toHex(slice);
              if (e === "utf-8" || e === "utf8") return N.utf8Decode(slice);
              if (e === "ascii" || e === "latin1") {
                let s = "";
                for (let i = 0; i < slice.length; i++) s += String.fromCharCode(slice[i] & 0x7f);
                return s;
              }
              return N.utf8Decode(slice);
            }
          }
          globalThis.Buffer = Buffer;

          class TextEncoder {
            get encoding() { return "utf-8"; }
            encode(str = "") { return new Uint8Array(N.utf8Encode(str)); }
          }
          class TextDecoder {
            constructor(label = "utf-8") { this.encoding = label; }
            decode(bytes) {
              if (!bytes) return "";
              if (bytes instanceof ArrayBuffer) bytes = new Uint8Array(bytes);
              return N.utf8Decode(bytes);
            }
          }
          globalThis.TextEncoder = TextEncoder;
          globalThis.TextDecoder = TextDecoder;

          globalThis.atob = (s) => N.utf8Decode(N.fromBase64(s));
          globalThis.btoa = (s) => N.toBase64(N.utf8Encode(s));

          // JSC drains microtasks at the end of evaluateScript, so a
          // resolved-promise chain works fine for queueMicrotask.
          globalThis.queueMicrotask = (fn) => Promise.resolve().then(fn);

          delete globalThis.__swiftjs_native;
        })();
        """#
        context.evaluateScript(shim)
    }

    /// Pull bytes out of a JSValue. Accepts Uint8Array, plain Array
    /// of numbers, or anything else with a `length` and indexable
    /// elements. We can't `as` a JSValue to `[UInt8]` directly.
    /// Convert a `string|Buffer|Uint8Array` argument to a string for
    /// `process.stdout.write` / `stderr.write`.
    static func stringFromWritable(_ value: JSValue) -> String {
        if value.isString { return value.toString() ?? "" }
        if let arr = value.toArray() as? [NSNumber] {
            // swiftlint:disable:next optional_data_string_conversion - JS-provided bytes may be lossy
            return String(decoding: arr.map { $0.uint8Value }, as: UTF8.self)
        }
        return value.toString() ?? ""
    }

    static func bytes(from value: JSValue) -> [UInt8] {
        let array = value.toArray() ?? []
        return array.compactMap { ($0 as? NSNumber)?.uint8Value }
    }

    // MARK: - URL polyfill (minimal — Foundation backs it)

    func installWebGlobals() {
        // Bridge URL parsing to URLComponents so we don't have to
        // reimplement the WHATWG URL state machine. Good enough for
        // most shell scripts; not 100% spec compliant.
        let parseURL = block { args in
            guard let href = args.first?.toString() else { return nil }
            var resolvedHref = href
            if args.count >= 2 {
                let base = args[1]
                if base.isString, let baseStr = base.toString() {
                    if let baseURL = URL(string: baseStr),
                       let resolved = URL(string: href, relativeTo: baseURL) {
                        resolvedHref = resolved.absoluteString
                    }
                }
            }
            guard let url = URL(string: resolvedHref),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
            else {
                return nil
            }
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!
            obj.setObject(url.absoluteString, forKeyedSubscript: "href")
            obj.setObject((comps.scheme ?? "") + ":", forKeyedSubscript: "protocol")
            obj.setObject(comps.host ?? "", forKeyedSubscript: "hostname")
            obj.setObject(comps.port.map(String.init) ?? "", forKeyedSubscript: "port")
            let host = (comps.host ?? "") + (comps.port.map { ":\($0)" } ?? "")
            obj.setObject(host, forKeyedSubscript: "host")
            obj.setObject(comps.path, forKeyedSubscript: "pathname")
            obj.setObject(comps.query.map { "?\($0)" } ?? "", forKeyedSubscript: "search")
            obj.setObject(comps.fragment.map { "#\($0)" } ?? "", forKeyedSubscript: "hash")
            obj.setObject((comps.scheme ?? "") + "://" + host, forKeyedSubscript: "origin")
            return obj
        }
        setGlobal("__swiftjs_parseURL", parseURL)

        let urlShim = #"""
        (() => {
          const parse = globalThis.__swiftjs_parseURL;
          class URL {
            constructor(href, base) {
              const fields = parse(String(href), base != null ? String(base) : undefined);
              if (!fields) throw new TypeError("Invalid URL: " + href);
              Object.assign(this, fields);
            }
            toString() { return this.href; }
          }
          globalThis.URL = URL;
          delete globalThis.__swiftjs_parseURL;
        })();
        """#
        context.evaluateScript(urlShim)
    }
}

#endif  // !os(Windows)
