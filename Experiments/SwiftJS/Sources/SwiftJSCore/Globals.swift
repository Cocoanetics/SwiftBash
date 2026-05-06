import Foundation
import JavaScriptCore

extension JSRuntime {

    func installGlobals(argv: [String], env: [String: String]) {
        installConsole()
        installProcess(argv: argv, env: env)
        installBufferAndEncodingBridges()
        installWebGlobals()
    }

    // MARK: - console

    private func installConsole() {
        let console = JSValue(newObjectIn: context)!

        let log: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            let args = JSContext.currentArguments()?.compactMap { $0 as? JSValue } ?? []
            self.stdout(self.formatArgs(args) + "\n")
        }
        let err: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            let args = JSContext.currentArguments()?.compactMap { $0 as? JSValue } ?? []
            self.stderr(self.formatArgs(args) + "\n")
        }

        for name in ["log", "info", "debug", "trace"] {
            console.setObject(block(log as AnyObject), forKeyedSubscript: name as NSString)
        }
        for name in ["error", "warn"] {
            console.setObject(block(err as AnyObject), forKeyedSubscript: name as NSString)
        }
        setGlobal("console", console)
    }

    private func formatArgs(_ args: [JSValue]) -> String {
        args.map { describe($0) }.joined(separator: " ")
    }

    private func describe(_ value: JSValue) -> String {
        if value.isString { return value.toString() ?? "" }
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        if value.isBoolean || value.isNumber { return value.toString() ?? "" }
        let json = context.objectForKeyedSubscript("JSON")
        if let s = json?.invokeMethod("stringify", withArguments: [value]),
           !s.isUndefined, !s.isNull,
           let str = s.toString(), str != "undefined" {
            return str
        }
        return value.toString() ?? "[object]"
    }

    // MARK: - process

    private func installProcess(argv: [String], env: [String: String]) {
        let process = JSValue(newObjectIn: context)!

        process.setObject(argv, forKeyedSubscript: "argv" as NSString)
        process.setObject(env, forKeyedSubscript: "env" as NSString)

        #if os(macOS)
        process.setObject("darwin", forKeyedSubscript: "platform" as NSString)
        #elseif os(iOS)
        process.setObject("ios", forKeyedSubscript: "platform" as NSString)
        #else
        process.setObject("unknown", forKeyedSubscript: "platform" as NSString)
        #endif

        #if arch(arm64)
        process.setObject("arm64", forKeyedSubscript: "arch" as NSString)
        #elseif arch(x86_64)
        process.setObject("x64", forKeyedSubscript: "arch" as NSString)
        #else
        process.setObject("unknown", forKeyedSubscript: "arch" as NSString)
        #endif

        process.setObject("v22.0.0-swiftjs", forKeyedSubscript: "version" as NSString)

        let exit: @convention(block) (Int32) -> Void = { [weak self] code in
            guard let self else { return }
            self.didExit = true
            self.exitCode = code
            // Cancel pending timers so the runloop drains immediately.
            for (_, timer) in self.pendingTimers { timer.cancel() }
            self.pendingTimers.removeAll()
            let ex = JSValue(object: ["__swiftjs_exit": true, "code": code], in: self.context)
            self.context.exception = ex
        }
        process.setObject(block(exit as AnyObject), forKeyedSubscript: "exit" as NSString)

        let cwd: @convention(block) () -> String = {
            FileManager.default.currentDirectoryPath
        }
        process.setObject(block(cwd as AnyObject), forKeyedSubscript: "cwd" as NSString)

        let chdir: @convention(block) (String) -> Void = { path in
            FileManager.default.changeCurrentDirectoryPath(path)
        }
        process.setObject(block(chdir as AnyObject), forKeyedSubscript: "chdir" as NSString)

        let hrtime: @convention(block) () -> [Int] = {
            let now = DispatchTime.now().uptimeNanoseconds
            return [Int(now / 1_000_000_000), Int(now % 1_000_000_000)]
        }
        process.setObject(block(hrtime as AnyObject), forKeyedSubscript: "hrtime" as NSString)

        setGlobal("process", process)
    }

    // MARK: - Buffer + encoding bridges
    //
    // JSC ships no TextEncoder/TextDecoder/Buffer/atob/btoa. We bridge
    // the byte-level conversions from Swift, then build Buffer, the
    // Text* classes, and atob/btoa as small JS shims on top.

    func installBufferAndEncodingBridges() {
        // Swift bridges, exposed under `__swiftjs_native` so we can hide
        // them from user code (the JS shim deletes it after building
        // its API).
        let native = JSValue(newObjectIn: context)!

        let utf8Encode: @convention(block) (String) -> [UInt8] = { s in
            Array(s.utf8)
        }
        native.setObject(block(utf8Encode as AnyObject),
                         forKeyedSubscript: "utf8Encode" as NSString)

        let utf8Decode: @convention(block) (JSValue) -> String = { value in
            // Accept either a Uint8Array or a plain Array of bytes.
            let bytes = Self.bytes(from: value)
            return String(decoding: bytes, as: UTF8.self)
        }
        native.setObject(block(utf8Decode as AnyObject),
                         forKeyedSubscript: "utf8Decode" as NSString)

        let toBase64: @convention(block) (JSValue) -> String = { value in
            Data(Self.bytes(from: value)).base64EncodedString()
        }
        native.setObject(block(toBase64 as AnyObject),
                         forKeyedSubscript: "toBase64" as NSString)

        let fromBase64: @convention(block) (String) -> [UInt8] = { s in
            Array(Data(base64Encoded: s) ?? Data())
        }
        native.setObject(block(fromBase64 as AnyObject),
                         forKeyedSubscript: "fromBase64" as NSString)

        let toHex: @convention(block) (JSValue) -> String = { value in
            Self.bytes(from: value).map { String(format: "%02x", $0) }.joined()
        }
        native.setObject(block(toHex as AnyObject),
                         forKeyedSubscript: "toHex" as NSString)

        let fromHex: @convention(block) (String) -> [UInt8] = { s in
            stride(from: 0, to: s.count, by: 2).compactMap { i -> UInt8? in
                let start = s.index(s.startIndex, offsetBy: i)
                let end = s.index(start, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                return UInt8(s[start..<end], radix: 16)
            }
        }
        native.setObject(block(fromHex as AnyObject),
                         forKeyedSubscript: "fromHex" as NSString)

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
    private static func bytes(from value: JSValue) -> [UInt8] {
        let array = value.toArray() ?? []
        return array.compactMap { ($0 as? NSNumber)?.uint8Value }
    }

    // MARK: - URL polyfill (minimal — Foundation backs it)

    private func installWebGlobals() {
        // Bridge URL parsing to URLComponents so we don't have to
        // reimplement the WHATWG URL state machine. Good enough for
        // most shell scripts; not 100% spec compliant.
        let parseURL: @convention(block) (String, JSValue?) -> Any? = { href, base in
            var resolvedHref = href
            if let base, base.isString, let baseStr = base.toString() {
                if let baseURL = URL(string: baseStr),
                   let resolved = URL(string: href, relativeTo: baseURL) {
                    resolvedHref = resolved.absoluteString
                }
            }
            guard let url = URL(string: resolvedHref),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                return nil
            }
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!
            obj.setObject(url.absoluteString, forKeyedSubscript: "href" as NSString)
            obj.setObject((comps.scheme ?? "") + ":", forKeyedSubscript: "protocol" as NSString)
            obj.setObject(comps.host ?? "", forKeyedSubscript: "hostname" as NSString)
            obj.setObject(comps.port.map(String.init) ?? "", forKeyedSubscript: "port" as NSString)
            let host = (comps.host ?? "") + (comps.port.map { ":\($0)" } ?? "")
            obj.setObject(host, forKeyedSubscript: "host" as NSString)
            obj.setObject(comps.path, forKeyedSubscript: "pathname" as NSString)
            obj.setObject(comps.query.map { "?\($0)" } ?? "", forKeyedSubscript: "search" as NSString)
            obj.setObject(comps.fragment.map { "#\($0)" } ?? "", forKeyedSubscript: "hash" as NSString)
            obj.setObject((comps.scheme ?? "") + "://" + host, forKeyedSubscript: "origin" as NSString)
            return obj
        }
        setGlobal("__swiftjs_parseURL", block(parseURL as AnyObject))

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
