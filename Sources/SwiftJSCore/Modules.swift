import Foundation

#if canImport(JavaScriptCore)

import JavaScriptCore

extension JSRuntime {

    /// Wires up `require()`, the builtin module table (node:fs,
    /// node:path, node:os, node:url, node:util), and a CommonJS
    /// loader for relative-path requires.
    func installModules() {
        installRequire()
        registerBuiltinModules()
    }

    private func installRequire() {
        // require() table: spec → cached JSValue. Builtin modules are
        // loaded eagerly at startup; local files lazily on first
        // require, then cached.
        let cacheKey = "__swiftjs_module_cache"
        context.evaluateScript("globalThis.\(cacheKey) = {};")

        let requireImpl: @convention(block) (String) -> Any? = { [weak self] spec in
            guard let self else { return nil }
            return self.resolveRequire(spec)
        }
        setGlobal("require", block(requireImpl as AnyObject))
    }

    /// Resolve a require spec. Returns the module's `exports` value.
    private func resolveRequire(_ spec: String) -> Any? {
        // Builtin modules (registered eagerly in
        // `registerBuiltinModules`). Both `fs` and `node:fs` work.
        if let cached = lookupCache(spec) { return cached }

        // Relative or absolute path → load file.
        if spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") {
            return loadFileModule(spec)
        }

        return throwJS("Cannot find module '\(spec)'")
    }

    /// Look up the cache directly via the JS object (don't go through
    /// `toDictionary()`, which unwraps JSValue into native types).
    private func lookupCache(_ key: String) -> JSValue? {
        guard let cache = context.objectForKeyedSubscript("__swiftjs_module_cache"),
              !cache.isUndefined else { return nil }
        let v = cache.objectForKeyedSubscript(key)
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        return v
    }

    private func cacheBuiltin(_ name: String, _ value: JSValue) {
        let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
        cache.setObject(value, forKeyedSubscript: name as NSString)
    }

    private func loadFileModule(_ spec: String) -> Any? {
        let basePath = (currentScriptPath as NSString?)?.deletingLastPathComponent
            ?? FileManager.default.currentDirectoryPath
        var resolved = (spec as NSString).hasPrefix("/")
            ? spec
            : (basePath as NSString).appendingPathComponent(spec)

        // Try `.js`, `.mjs`, `.cjs`, `.json` if the bare path doesn't
        // exist (Node's resolution order). `.json` parsed below.
        let fm = FileManager.default
        if !fm.fileExists(atPath: resolved) {
            for ext in [".js", ".mjs", ".cjs", ".json"] {
                if fm.fileExists(atPath: resolved + ext) {
                    resolved += ext
                    break
                }
            }
        }

        // Cache check (use the resolved absolute path as the key).
        if let cached = (context.objectForKeyedSubscript("__swiftjs_module_cache")?
            .objectForKeyedSubscript(resolved)),
           !cached.isUndefined, !cached.isNull {
            return cached
        }

        guard let source = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return throwJS("Cannot find module '\(spec)'")
        }

        // .json files load as parsed JSON (Node behaviour).
        if resolved.hasSuffix(".json") {
            let parser = context.objectForKeyedSubscript("JSON")!
            let value = parser.invokeMethod("parse", withArguments: [source])
            let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
            cache.setObject(value as Any, forKeyedSubscript: resolved as NSString)
            return value
        }

        // Rewrite ESM-isms before wrapping so that `.mjs` files (or
        // `.js` files written in module syntax) work the same as
        // CommonJS `require`d modules.
        let rewritten = ESMRewriter.rewrite(source)

        // CommonJS wrapper. Note: returns module.exports.
        let wrapped = """
        (function(exports, require, module, __filename, __dirname) {
        \(rewritten)
        })
        """
        let url = URL(fileURLWithPath: resolved)
        guard let factory = context.evaluateScript(wrapped, withSourceURL: url),
              !factory.isUndefined else {
            return nil
        }

        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setObject(exports, forKeyedSubscript: "exports" as NSString)

        // Cache before invoking the factory so circular requires
        // don't loop forever — Node does the same.
        let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
        cache.setObject(exports, forKeyedSubscript: resolved as NSString)

        let prev = currentScriptPath
        currentScriptPath = resolved
        defer { currentScriptPath = prev }

        let dirname = (resolved as NSString).deletingLastPathComponent
        let requireGlobal = context.objectForKeyedSubscript("require")!
        factory.call(withArguments: [exports, requireGlobal, module, resolved, dirname])

        let finalExports = module.objectForKeyedSubscript("exports")!
        cache.setObject(finalExports, forKeyedSubscript: resolved as NSString)
        return finalExports
    }

    // MARK: - Builtin modules

    private func registerBuiltinModules() {
        let fs = makeFsModule()
        cacheBuiltin("fs", fs)
        cacheBuiltin("node:fs", fs)

        let path = makePathModule()
        cacheBuiltin("path", path)
        cacheBuiltin("node:path", path)

        let os = makeOsModule()
        cacheBuiltin("os", os)
        cacheBuiltin("node:os", os)

        let util = makeUtilModule()
        cacheBuiltin("util", util)
        cacheBuiltin("node:util", util)

        let urlMod = makeUrlModule()
        cacheBuiltin("url", urlMod)
        cacheBuiltin("node:url", urlMod)

        let cryptoMod = makeCryptoModule()
        cacheBuiltin("crypto", cryptoMod)
        cacheBuiltin("node:crypto", cryptoMod)

        let cpMod = makeChildProcessModule()
        cacheBuiltin("child_process", cpMod)
        cacheBuiltin("node:child_process", cpMod)

        let fsPromises = makeFsPromisesModule(syncFs: fs)
        cacheBuiltin("node:fs/promises", fsPromises)
        cacheBuiltin("fs/promises", fsPromises)

        let zlibMod = makeZlibModule()
        cacheBuiltin("zlib", zlibMod)
        cacheBuiltin("node:zlib", zlibMod)

        let assertMod = makeAssertModule()
        cacheBuiltin("assert", assertMod)
        cacheBuiltin("node:assert", assertMod)
        cacheBuiltin("assert/strict", assertMod)
        cacheBuiltin("node:assert/strict", assertMod)

        let eventsMod = makeEventsModule()
        cacheBuiltin("events", eventsMod)
        cacheBuiltin("node:events", eventsMod)

        let qsMod = makeQuerystringModule()
        cacheBuiltin("querystring", qsMod)
        cacheBuiltin("node:querystring", qsMod)

        let perfMod = makePerfHooksModule()
        cacheBuiltin("perf_hooks", perfMod)
        cacheBuiltin("node:perf_hooks", perfMod)
    }

    // MARK: - node:assert (pure JS)

    private func makeAssertModule() -> JSValue {
        // Just enough of node:assert to write tests against.
        let source = #"""
        (() => {
          class AssertionError extends Error {
            constructor(opts = {}) {
              super(opts.message ?? `Expected: ${JSON.stringify(opts.expected)}, got: ${JSON.stringify(opts.actual)}`);
              this.name = "AssertionError";
              this.code = "ERR_ASSERTION";
              this.actual = opts.actual;
              this.expected = opts.expected;
              this.operator = opts.operator;
            }
          }
          const fail = (opts) => { throw new AssertionError(opts); };
          const ok = (cond, message) => {
            if (!cond) fail({ actual: cond, expected: true, message: message ?? "Expected truthy", operator: "==" });
          };
          const eq  = (a, b, message) => {
            if (a != b)  fail({ actual: a, expected: b, message, operator: "==" });
          };
          const strictEq = (a, b, message) => {
            if (a !== b) fail({ actual: a, expected: b, message, operator: "===" });
          };
          const deepEq = (a, b, message) => {
            if (JSON.stringify(a) !== JSON.stringify(b)) {
              fail({ actual: a, expected: b, message, operator: "deepEqual" });
            }
          };
          const throws = (fn, expected) => {
            let threw = false; let err;
            try { fn(); } catch (e) { threw = true; err = e; }
            if (!threw) fail({ message: "Missing expected exception" });
            if (expected instanceof RegExp && !expected.test(err && err.message)) {
              fail({ actual: err.message, expected: expected.source, message: "Error did not match" });
            }
          };
          const fn = ok;
          fn.AssertionError = AssertionError;
          fn.ok = ok;
          fn.fail = (msg) => fail({ message: msg ?? "Failed" });
          fn.equal = eq;
          fn.notEqual = (a, b, m) => { if (a == b) fail({ actual: a, expected: b, message: m, operator: "!=" }); };
          fn.strictEqual = strictEq;
          fn.notStrictEqual = (a, b, m) => { if (a === b) fail({ actual: a, expected: b, message: m, operator: "!==" }); };
          fn.deepEqual = deepEq;
          fn.deepStrictEqual = deepEq;
          fn.throws = throws;
          fn.doesNotThrow = (f) => { try { f(); } catch { fail({ message: "Got unwanted exception" }); } };
          fn.match = (str, re, m) => { if (!re.test(str)) fail({ actual: str, expected: re.source, message: m, operator: "match" }); };
          fn.strict = fn;
          return fn;
        })()
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - node:events (EventEmitter, pure JS)

    private func makeEventsModule() -> JSValue {
        let source = #"""
        (() => {
          class EventEmitter {
            constructor() { this._events = new Map(); this._maxListeners = 10; }
            on(event, fn) { return this.addListener(event, fn); }
            addListener(event, fn) {
              const list = this._events.get(event) ?? [];
              list.push(fn);
              this._events.set(event, list);
              return this;
            }
            once(event, fn) {
              const wrap = (...a) => { this.off(event, wrap); fn(...a); };
              return this.on(event, wrap);
            }
            off(event, fn) { return this.removeListener(event, fn); }
            removeListener(event, fn) {
              const list = this._events.get(event);
              if (!list) return this;
              const next = list.filter(x => x !== fn);
              if (next.length) this._events.set(event, next);
              else this._events.delete(event);
              return this;
            }
            removeAllListeners(event) {
              if (event === undefined) this._events.clear();
              else this._events.delete(event);
              return this;
            }
            emit(event, ...args) {
              const list = this._events.get(event);
              if (!list || list.length === 0) {
                if (event === "error") throw args[0] ?? new Error("Unhandled error");
                return false;
              }
              // Copy in case a handler mutates the list.
              for (const fn of list.slice()) {
                try { fn(...args); } catch (e) { /* swallow per Node */ }
              }
              return true;
            }
            listenerCount(event) {
              return (this._events.get(event) ?? []).length;
            }
            listeners(event) {
              return (this._events.get(event) ?? []).slice();
            }
            eventNames() { return Array.from(this._events.keys()); }
            setMaxListeners(n) { this._maxListeners = n; return this; }
            getMaxListeners() { return this._maxListeners; }
          }
          const out = EventEmitter;
          out.EventEmitter = EventEmitter;
          out.default = EventEmitter;
          return out;
        })()
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - node:querystring (pure JS)

    private func makeQuerystringModule() -> JSValue {
        let source = #"""
        ({
          parse(str, sep = "&", eq = "=") {
            const out = {};
            if (!str) return out;
            for (const pair of str.split(sep)) {
              if (!pair) continue;
              const i = pair.indexOf(eq);
              const k = decodeURIComponent((i < 0 ? pair : pair.slice(0, i)).replace(/\+/g, " "));
              const v = i < 0 ? "" : decodeURIComponent(pair.slice(i + 1).replace(/\+/g, " "));
              if (k in out) {
                if (Array.isArray(out[k])) out[k].push(v);
                else out[k] = [out[k], v];
              } else out[k] = v;
            }
            return out;
          },
          stringify(obj, sep = "&", eq = "=") {
            if (!obj) return "";
            const enc = (s) => encodeURIComponent(String(s)).replace(/%20/g, "+");
            const pairs = [];
            for (const k of Object.keys(obj)) {
              const v = obj[k];
              if (Array.isArray(v)) {
                for (const x of v) pairs.push(enc(k) + eq + enc(x));
              } else if (v == null) {
                pairs.push(enc(k) + eq);
              } else {
                pairs.push(enc(k) + eq + enc(v));
              }
            }
            return pairs.join(sep);
          },
          escape: encodeURIComponent,
          unescape: decodeURIComponent,
        })
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - node:perf_hooks (re-export performance)

    private func makePerfHooksModule() -> JSValue {
        let source = #"""
        ({
          performance: globalThis.performance,
          monotonicTimeOrigin: globalThis.performance?.timeOrigin,
        })
        """#
        return context.evaluateScript(source)!
    }

    /// `node:fs/promises` — async wrappers over the sync fs ops.
    /// Built in JS so each function returns a real Promise without
    /// needing a Swift round-trip.
    private func makeFsPromisesModule(syncFs: JSValue) -> JSValue {
        // Stash the sync module under a unique global key so the JS
        // factory can grab it, then build the async surface.
        let key = "__swiftjs_sync_fs"
        setGlobal(key, syncFs)
        let source = #"""
        (() => {
          const fs = globalThis.__swiftjs_sync_fs;
          const wrap = (name) => (...args) => {
            try { return Promise.resolve(fs[name](...args)); }
            catch (e) { return Promise.reject(e); }
          };
          const out = {};
          for (const n of [
            "readFileSync","writeFileSync","appendFileSync",
            "readdirSync","mkdirSync","rmSync","unlinkSync","statSync",
          ]) {
            // Drop the Sync suffix.
            out[n.replace(/Sync$/, "")] = wrap(n);
          }
          delete globalThis.__swiftjs_sync_fs;
          return out;
        })()
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - fs

    private func makeFsModule() -> JSValue {
        let fs = JSValue(newObjectIn: context)!

        // readFileSync: returns Buffer if no encoding, String otherwise.
        // No optional trailing arg in the block — read it via
        // JSContext.currentArguments() instead.
        let readFileSync: @convention(block) (String) -> Any? = { [weak self] path in
            guard let self else { return nil }
            let opts = (JSContext.currentArguments()?.dropFirst().first as? JSValue)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let encoding = Self.encodingArg(from: opts)
                if let encoding {
                    return Self.decode(data, encoding: encoding)
                }
                let bufferCtor = self.context.objectForKeyedSubscript("Buffer")!
                let bytes = Array(data) as [UInt8]
                return bufferCtor.invokeMethod("from", withArguments: [bytes])!
            } catch {
                return self.throwJS(error.localizedDescription)
            }
        }
        fs.setObject(block(readFileSync as AnyObject),
                     forKeyedSubscript: "readFileSync" as NSString)

        // Side-effect-only ops return Void. Returning a JSValue from
        // an `Any?`-typed block confuses JSC's argument binder when
        // the JS caller omits trailing optional args.
        let writeFileSync: @convention(block) (String, JSValue) -> Bool = { [weak self] path, value in
            guard let self else { return false }
            do {
                let data = Self.dataForWrite(value)
                try data.write(to: URL(fileURLWithPath: path))
                return true
            } catch {
                _ = self.throwJS(error.localizedDescription)
                return false
            }
        }
        fs.setObject(block(writeFileSync as AnyObject),
                     forKeyedSubscript: "writeFileSync" as NSString)

        let appendFileSync: @convention(block) (String, JSValue) -> Bool = { path, value in
            let data = Self.dataForWrite(value)
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
            return true
        }
        fs.setObject(block(appendFileSync as AnyObject),
                     forKeyedSubscript: "appendFileSync" as NSString)

        let existsSync: @convention(block) (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
        fs.setObject(block(existsSync as AnyObject),
                     forKeyedSubscript: "existsSync" as NSString)

        let readdirSync: @convention(block) (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
        fs.setObject(block(readdirSync as AnyObject),
                     forKeyedSubscript: "readdirSync" as NSString)

        // Avoid optional trailing-arg blocks: JSC's bridge raises a
        // spurious "undefined is not an object" on the call
        // expression when the JS caller omits the optional. Use
        // `JSContext.currentArguments()` to read variadic args.
        let mkdirSync: @convention(block) (String) -> Bool = { [weak self] path in
            guard let self else { return false }
            let opts = (JSContext.currentArguments()?.dropFirst().first as? JSValue)
            let recursive = opts?.objectForKeyedSubscript("recursive")?.toBool() ?? false
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: recursive
                )
                return true
            } catch {
                _ = self.throwJS(error.localizedDescription)
                return false
            }
        }
        fs.setObject(block(mkdirSync as AnyObject),
                     forKeyedSubscript: "mkdirSync" as NSString)

        let rmSync: @convention(block) (String) -> Bool = { [weak self] path in
            guard let self else { return false }
            let opts = (JSContext.currentArguments()?.dropFirst().first as? JSValue)
            let force = opts?.objectForKeyedSubscript("force")?.toBool() ?? false
            do {
                try FileManager.default.removeItem(atPath: path)
                return true
            } catch {
                if !force { _ = self.throwJS(error.localizedDescription) }
                return false
            }
        }
        fs.setObject(block(rmSync as AnyObject),
                     forKeyedSubscript: "rmSync" as NSString)
        fs.setObject(block(rmSync as AnyObject),
                     forKeyedSubscript: "unlinkSync" as NSString)

        let statSync: @convention(block) (String) -> Any? = { [weak self] path in
            guard let self else { return nil }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                return self.throwJS("ENOENT: no such file or directory, stat '\(path)'")
            }
            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let isDirectory = isDir.boolValue
            let obj = JSValue(newObjectIn: self.context)!
            obj.setObject(size, forKeyedSubscript: "size" as NSString)
            obj.setObject(mtime * 1000, forKeyedSubscript: "mtimeMs" as NSString)
            let isDirImpl: @convention(block) () -> Bool = { isDirectory }
            let isFileImpl: @convention(block) () -> Bool = { !isDirectory }
            obj.setObject(self.block(isDirImpl as AnyObject),
                          forKeyedSubscript: "isDirectory" as NSString)
            obj.setObject(self.block(isFileImpl as AnyObject),
                          forKeyedSubscript: "isFile" as NSString)
            return obj
        }
        fs.setObject(block(statSync as AnyObject),
                     forKeyedSubscript: "statSync" as NSString)

        return fs
    }

    private static func encodingArg(from opts: JSValue?) -> String? {
        guard let opts else { return nil }
        if opts.isString { return opts.toString() }
        if opts.isObject,
           let enc = opts.objectForKeyedSubscript("encoding"),
           enc.isString {
            return enc.toString()
        }
        return nil
    }

    private static func decode(_ data: Data, encoding: String) -> String {
        switch encoding.lowercased() {
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8) ?? ""
        case "ascii":
            return String(data: data, encoding: .ascii) ?? ""
        case "base64":
            return data.base64EncodedString()
        case "hex":
            return data.map { String(format: "%02x", $0) }.joined()
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Convert a string|Buffer|Uint8Array JSValue to Data for writing.
    private static func dataForWrite(_ value: JSValue) -> Data {
        if value.isString {
            return Data((value.toString() ?? "").utf8)
        }
        if let bytes = value.toArray() as? [NSNumber] {
            return Data(bytes.map { $0.uint8Value })
        }
        return Data((value.toString() ?? "").utf8)
    }

    // MARK: - path

    private func makePathModule() -> JSValue {
        // Implemented in JS for pure-string ops (matches Node).
        let source = #"""
        ({
          sep: "/",
          delimiter: ":",
          join(...parts) {
            const filtered = parts.filter(p => p && p.length > 0);
            if (filtered.length === 0) return ".";
            return filtered.join("/").replace(/\/+/g, "/");
          },
          basename(p, ext) {
            const i = p.lastIndexOf("/");
            let base = i < 0 ? p : p.slice(i + 1);
            if (ext && base.endsWith(ext)) base = base.slice(0, -ext.length);
            return base;
          },
          dirname(p) {
            const i = p.lastIndexOf("/");
            if (i < 0) return ".";
            if (i === 0) return "/";
            return p.slice(0, i);
          },
          extname(p) {
            const i = p.lastIndexOf("/");
            const base = i < 0 ? p : p.slice(i + 1);
            const j = base.lastIndexOf(".");
            return j <= 0 ? "" : base.slice(j);
          },
          isAbsolute(p) { return p.startsWith("/"); },
          resolve(...parts) {
            let resolved = process.cwd();
            for (const p of parts) {
              if (!p) continue;
              if (p.startsWith("/")) resolved = p;
              else resolved = resolved + "/" + p;
            }
            return resolved.replace(/\/+/g, "/");
          },
          parse(p) {
            const i = p.lastIndexOf("/");
            const dir = i <= 0 ? (i === 0 ? "/" : "") : p.slice(0, i);
            const base = i < 0 ? p : p.slice(i + 1);
            const j = base.lastIndexOf(".");
            const ext = j <= 0 ? "" : base.slice(j);
            const name = ext ? base.slice(0, -ext.length) : base;
            return { root: p.startsWith("/") ? "/" : "", dir, base, ext, name };
          },
        })
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - os

    private func makeOsModule() -> JSValue {
        let os = JSValue(newObjectIn: context)!

        let homedir: @convention(block) () -> String = { NSHomeDirectory() }
        os.setObject(block(homedir as AnyObject),
                     forKeyedSubscript: "homedir" as NSString)

        let tmpdir: @convention(block) () -> String = { NSTemporaryDirectory() }
        os.setObject(block(tmpdir as AnyObject),
                     forKeyedSubscript: "tmpdir" as NSString)

        let hostname: @convention(block) () -> String = {
            ProcessInfo.processInfo.hostName
        }
        os.setObject(block(hostname as AnyObject),
                     forKeyedSubscript: "hostname" as NSString)

        let platform: @convention(block) () -> String = {
            #if os(macOS)
            return "darwin"
            #elseif os(iOS)
            return "ios"
            #else
            return "unknown"
            #endif
        }
        os.setObject(block(platform as AnyObject),
                     forKeyedSubscript: "platform" as NSString)

        let arch: @convention(block) () -> String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x64"
            #else
            return "unknown"
            #endif
        }
        os.setObject(block(arch as AnyObject),
                     forKeyedSubscript: "arch" as NSString)

        os.setObject("\n", forKeyedSubscript: "EOL" as NSString)
        return os
    }

    // MARK: - util (very small subset)

    private func makeUtilModule() -> JSValue {
        // Just `util.format` / `util.inspect` lite. Real `util` is enormous.
        let source = #"""
        ({
          format(fmt, ...args) {
            if (typeof fmt !== "string") {
              return [fmt, ...args].map(a =>
                typeof a === "object" ? JSON.stringify(a) : String(a)
              ).join(" ");
            }
            let i = 0;
            const out = fmt.replace(/%[sdjifoOc%]/g, (m) => {
              if (m === "%%") return "%";
              if (i >= args.length) return m;
              const a = args[i++];
              switch (m) {
                case "%s": return String(a);
                case "%d": case "%i": return String(parseInt(a, 10));
                case "%f": return String(parseFloat(a));
                case "%j": return JSON.stringify(a);
                case "%o": case "%O": return JSON.stringify(a);
                default:   return String(a);
              }
            });
            const rest = args.slice(i).map(a =>
              typeof a === "object" ? JSON.stringify(a) : String(a)
            );
            return rest.length ? out + " " + rest.join(" ") : out;
          },
          inspect(value) {
            try { return JSON.stringify(value, null, 2); }
            catch { return String(value); }
          },
        })
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - url

    private func makeUrlModule() -> JSValue {
        let source = #"""
        ({
          URL: globalThis.URL,
          fileURLToPath(u) {
            const url = typeof u === "string" ? new URL(u) : u;
            return url.pathname;
          },
          pathToFileURL(p) {
            return new URL("file://" + (p.startsWith("/") ? p : "/" + p));
          },
        })
        """#
        return context.evaluateScript(source)!
    }
}
#endif
