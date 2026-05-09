#if !os(Windows)

import Foundation
import BashInterpreter



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

        let requireImpl = block { [weak self] args in
            guard let self, let spec = args.first?.toString() else { return nil }
            return self.resolveRequire(spec)
        }
        setGlobal("require", requireImpl)
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

        return throwJSError("Cannot find module '\(spec)'", code: "MODULE_NOT_FOUND")
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
        // `require("./x")` with no calling-module context (entry-point
        // script reading via `vm.runInThisContext` etc.) falls back to
        // CWD. Use the bound shell's logical CWD, not the host process
        // CWD, so this stays consistent with `process.cwd()` and with
        // the `fs.*` resolver that follows.
        let basePath = (currentScriptPath as NSString?)?.deletingLastPathComponent
            ?? (Shell.current === Shell.processDefault
                ? FileManager.default.currentDirectoryPath
                : Shell.current.environment.workingDirectory)
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

        // Sandbox gate: a `require('./secret')` is a read; route the
        // resolved path through the bound shell's sandbox before we
        // touch disk.
        let gatedPath = resolved
        do {
            try awaitSync { try await authorizePath(gatedPath, for: .read) }
        } catch {
            return throwSandboxDenial(error, syscall: "open", path: gatedPath)
        }

        guard let source = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return throwJSError("Cannot find module '\(spec)'", code: "MODULE_NOT_FOUND")
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

        // CommonJS wrapper. The prefix lives on the same line as the
        // user's first line of source so JSC's stack-frame line
        // numbers map directly back to the original file (Node does
        // the same trick for the same reason). Column numbers on line
        // 1 are still off by `prefix.count`, but that's the standard
        // Node offset and tools that consume stack traces handle it.
        let prefix = "(function(exports, require, module, __filename, __dirname) { "
        let wrapped = prefix + rewritten + "\n})"
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

        // node:stream depends on EventEmitter being cached, so register
        // it after `events`. The module is the `Readable`/`Writable`
        // pair plus a `default`/named-export shape for ESM ergonomics.
        let streamMod = makeStreamModule()
        let streamWrapper = JSValue(newObjectIn: context)!
        streamWrapper.setObject(streamMod.objectForKeyedSubscript("Readable")!,
                                forKeyedSubscript: "Readable" as NSString)
        streamWrapper.setObject(streamMod.objectForKeyedSubscript("Writable")!,
                                forKeyedSubscript: "Writable" as NSString)
        streamWrapper.setObject(streamWrapper,
                                forKeyedSubscript: "default" as NSString)
        cacheBuiltin("stream", streamWrapper)
        cacheBuiltin("node:stream", streamWrapper)
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
        let readFileSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "open", path: path)
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                let encoding = Self.encodingArg(from: opts)
                if let encoding {
                    return Self.decode(data, encoding: encoding)
                }
                let bufferCtor = self.context.objectForKeyedSubscript("Buffer")!
                let bytes = Array(data) as [UInt8]
                return bufferCtor.invokeMethod("from", withArguments: [bytes])!
            } catch {
                return self.throwSystemError(error, syscall: "open", path: path)
            }
        }
        fs.setObject(readFileSync, forKeyedSubscript: "readFileSync")

        let writeFileSync = block { [weak self] args in
            guard let self, args.count >= 2,
                  let path = args[0].toString()
            else { return false }
            let value = args[1]
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "open", path: path)
                return false
            }
            do {
                let data = Self.dataForWrite(value)
                try data.write(to: URL(fileURLWithPath: resolved))
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "open", path: path)
                return false
            }
        }
        fs.setObject(writeFileSync, forKeyedSubscript: "writeFileSync")

        let appendFileSync = block { [weak self] args in
            guard let self, args.count >= 2,
                  let path = args[0].toString()
            else { return false }
            let value = args[1]
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "open", path: path)
                return false
            }
            let data = Self.dataForWrite(value)
            let url = URL(fileURLWithPath: resolved)
            do {
                if FileManager.default.fileExists(atPath: resolved) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try data.write(to: url)
                }
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "open", path: path)
                return false
            }
        }
        fs.setObject(appendFileSync, forKeyedSubscript: "appendFileSync")

        let existsSync = block { [weak self] args in
            // existsSync swallows errors by spec — Node returns `false`
            // for a path it can't stat. Mirror that behaviour for a
            // sandbox denial: the script learns nothing about whether
            // the path exists, only that it can't see it.
            guard let path = args.first?.toString() else { return false }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self?.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return false
            }
            return FileManager.default.fileExists(atPath: resolved)
        }
        fs.setObject(existsSync, forKeyedSubscript: "existsSync")

        let readdirSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "scandir", path: path)
            }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: resolved)
            } catch {
                _ = self.throwSystemError(error, syscall: "scandir", path: path)
                return nil
            }
        }
        fs.setObject(readdirSync, forKeyedSubscript: "readdirSync")

        let mkdirSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return false }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let recursive = opts?.objectForKeyedSubscript("recursive")?.toBool() ?? false
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "mkdir", path: path)
                return false
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: resolved,
                    withIntermediateDirectories: recursive
                )
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "mkdir", path: path)
                return false
            }
        }
        fs.setObject(mkdirSync, forKeyedSubscript: "mkdirSync")

        let rmSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return false }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let force = opts?.objectForKeyedSubscript("force")?.toBool() ?? false
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .delete) }
            } catch {
                // `force: true` would normally swallow ENOENT — but a
                // sandbox denial is policy, not a missing file, so
                // surface it regardless.
                _ = self.throwSandboxDenial(error, syscall: "unlink", path: path)
                return false
            }
            do {
                try FileManager.default.removeItem(atPath: resolved)
                return true
            } catch {
                if !force {
                    _ = self.throwSystemError(error, syscall: "unlink", path: path)
                }
                return false
            }
        }
        fs.setObject(rmSync, forKeyedSubscript: "rmSync")
        fs.setObject(rmSync, forKeyedSubscript: "unlinkSync")

        let statSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "stat", path: path)
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
                return self.throwJSError(
                    "ENOENT: no such file or directory, stat '\(path)'",
                    code: "ENOENT",
                    extras: [
                        "errno": Int(-ENOENT),
                        "syscall": "stat",
                        "path": path,
                    ]
                )
            }
            let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let isDirectory = isDir.boolValue
            let obj = JSValue(newObjectIn: self.context)!
            obj.setObject(size, forKeyedSubscript: "size")
            obj.setObject(mtime * 1000, forKeyedSubscript: "mtimeMs")
            let isDirImpl = self.block { _ in isDirectory }
            let isFileImpl = self.block { _ in !isDirectory }
            obj.setObject(isDirImpl, forKeyedSubscript: "isDirectory")
            obj.setObject(isFileImpl, forKeyedSubscript: "isFile")
            return obj
        }
        fs.setObject(statSync, forKeyedSubscript: "statSync")

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

        // Identity redirects: when an embedder has bound a non-default
        // Shell, route through `Shell.current` so a sandboxed script
        // sees the synthetic identity rather than the host's. Under
        // `Shell.processDefault` (standalone `swift-js` CLI) we keep
        // the legacy host-API answers.
        let homedir = block { _ in
            if Shell.current === Shell.processDefault {
                return NSHomeDirectory()
            }
            if let sandboxHome = Shell.current.sandbox?.homeDirectory.path {
                return sandboxHome
            }
            return Shell.current.environment.variables["HOME"] ?? NSHomeDirectory()
        }
        os.setObject(homedir, forKeyedSubscript: "homedir")

        let tmpdir = block { _ in
            if Shell.current === Shell.processDefault {
                return NSTemporaryDirectory()
            }
            if let sandboxTmp = Shell.current.sandbox?.temporaryDirectory.path {
                return sandboxTmp
            }
            return NSTemporaryDirectory()
        }
        os.setObject(tmpdir, forKeyedSubscript: "tmpdir")

        let hostname = block { _ in
            if Shell.current === Shell.processDefault {
                return ProcessInfo.processInfo.hostName
            }
            return Shell.current.hostInfo.hostName
        }
        os.setObject(hostname, forKeyedSubscript: "hostname")

        let platform = block { _ in
            #if os(macOS)
            return "darwin"
            #elseif os(iOS)
            return "ios"
            #elseif os(Linux)
            return "linux"
            #elseif os(Android)
            return "android"
            #else
            return "unknown"
            #endif
        }
        os.setObject(platform, forKeyedSubscript: "platform")

        let arch = block { _ in
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x64"
            #else
            return "unknown"
            #endif
        }
        os.setObject(arch, forKeyedSubscript: "arch")

        os.setObject("\n", forKeyedSubscript: "EOL")
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
#endif  // !os(Windows)
