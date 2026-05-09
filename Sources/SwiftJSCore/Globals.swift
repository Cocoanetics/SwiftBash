import Foundation
import BashInterpreter

// Foundation pulls libc through transitively on Apple and Linux,
// but the Android Swift toolchain doesn't re-export Bionic's
// `getpid` / `getppid` / etc. via Foundation. Pick up the libc
// module explicitly so this file compiles on every platform.
#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension JSRuntime {

    func installGlobals() {
        installConsole()
        installProcess()
        installBufferAndEncodingBridges()
        installWebGlobals()
        installPerformance()
        installAbortController()
        installEntryModuleScope()
    }

    // MARK: - performance

    /// `process.stdin` — a ``Readable`` over `FileHandle.standardInput`,
    /// lazily wired. The reader doesn't start (and the runloop doesn't
    /// stay up) until JS attaches a `'data'` listener or starts a
    /// `for await` iteration. Once started, a sentinel timer keeps
    /// the runloop alive until stdin EOFs.
    ///
    /// Installed as a property accessor rather than a plain object so
    /// that the Stream classes (which need EventEmitter from
    /// `node:events`) are only constructed *after* `installModules`
    /// has registered the events cache entry — `installGlobals`
    /// itself runs before `installModules` and can't materialise the
    /// stream eagerly.
    func installProcessStdin(on process: JSValue) {
        let stdinGet = block { [weak self] _ in
            self?.lazyProcessStdin()
        }
        setGlobal("__swiftjs_stdinGet", stdinGet)
        context.evaluateScript(#"""
        (() => {
          Object.defineProperty(process, "stdin", {
            get() { return globalThis.__swiftjs_stdinGet(); },
            enumerable: true,
            configurable: true,
          });
        })();
        """#)
    }

    /// First-touch construction of the JS-side `process.stdin`.
    /// Materialises a Readable subclass whose first listener attach
    /// (or first iterator pull) hooks `FileHandle.standardInput`.
    private func lazyProcessStdin() -> JSValue? {
        if let cached = cachedStdin, !cached.isUndefined { return cached }
        installStreamClasses()
        let factory = #"""
        (() => {
          const S = globalThis.__swiftjs_stream;
          class Stdin extends S.Readable {
            constructor() {
              super();
              this._started = false;
              this.isTTY = false;
            }
            _start() {
              if (this._started) return;
              this._started = true;
              globalThis.__swiftjs_startStdin(this);
            }
            on(event, fn) {
              const r = super.on(event, fn);
              if (event === "data") this._start();
              return r;
            }
            [Symbol.asyncIterator]() {
              this._start();
              return super[Symbol.asyncIterator]();
            }
          }
          return new Stdin();
        })();
        """#
        guard let stdin = context.evaluateScript(factory) else { return nil }
        cachedStdin = stdin

        let startStdin = block { [weak self] args in
            if let s = args.first { self?.beginStdinRead(into: s) }
            return nil
        }
        setGlobal("__swiftjs_startStdin", startStdin)
        return stdin
    }

    /// Hook `FileHandle.standardInput.readabilityHandler` to forward
    /// bytes into the supplied JS-side Readable. Idempotent at the
    /// JS level — the Stdin class only calls in once.
    private func beginStdinRead(into streamJS: JSValue) {
        // Sentinel keeps the runloop alive while we read.
        let sentinelID = nextTimerID
        nextTimerID += 1
        let sentinel = DispatchSource.makeTimerSource(queue: .main)
        sentinel.schedule(deadline: .distantFuture)
        sentinel.setEventHandler {}
        pendingTimers[sentinelID] = sentinel
        sentinel.resume()

        let fh = FileHandle.standardInput
        // Idempotent teardown shared by the EOF path and the JS-side
        // `destroy()` hook. Without this, a `for await` loop that
        // breaks early on `process.stdin` would leave the sentinel
        // alive and `drainPendingWorkIfNeeded()` would hang waiting
        // for stdin EOF that never comes.
        let teardown: @Sendable () -> Void = { [weak self] in
            fh.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let timer = self.pendingTimers.removeValue(forKey: sentinelID)
                else { return }
                timer.cancel()
            }
        }

        fh.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                teardown()
                DispatchQueue.main.async {
                    _ = streamJS.invokeMethod("_end", withArguments: [])
                }
                return
            }
            let bytes = Array(data)
            DispatchQueue.main.async {
                let ctx = streamJS.context
                guard let bufCtor = ctx.objectForKeyedSubscript("Buffer"),
                      let buf = bufCtor.invokeMethod("from", withArguments: [bytes])
                else { return }
                _ = streamJS.invokeMethod("_push", withArguments: [buf])
            }
        }

        // Wire the destroy hook so iterator early-exit (or an
        // explicit `process.stdin.destroy()`) tears the reader down.
        let destroy = block { _ in
            teardown()
            return nil
        }
        streamJS.setObject(destroy, forKeyedSubscript: "_onDestroy")
    }

    private func installPerformance() {
        // performance.now() — high-resolution monotonic clock in ms
        // (per the WHATWG spec). Backed by mach_absolute_time via
        // DispatchTime.uptimeNanoseconds.
        let start = DispatchTime.now().uptimeNanoseconds
        let now = block { _ in
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            return Double(elapsedNs) / 1_000_000.0
        }
        let timeOrigin: Double = Double(start) / 1_000_000.0
        let perf = JSValue(newObjectIn: context)!
        perf.setObject(now, forKeyedSubscript: "now")
        perf.setObject(timeOrigin, forKeyedSubscript: "timeOrigin")
        setGlobal("performance", perf)
    }

    // MARK: - AbortController / AbortSignal

    private func installAbortController() {
        // Pure-JS implementation. fetch() picks up the signal via
        // init.signal — the Swift bridge inspects it after the
        // request has been built but before resume(). Aborting from
        // JS calls signal.dispatchEvent which we intercept by setting
        // a flag the URLSession completion checks.
        let source = #"""
        (() => {
          class AbortError extends Error {
            constructor(message) {
              super(message ?? "The operation was aborted.");
              this.name = "AbortError";
              this.code = "ABORT_ERR";
            }
          }
          class AbortSignal {
            constructor() { this.aborted = false; this.reason = undefined; this._listeners = []; }
            addEventListener(type, fn) {
              if (type === "abort") this._listeners.push(fn);
            }
            removeEventListener(type, fn) {
              if (type === "abort") this._listeners = this._listeners.filter(x => x !== fn);
            }
            throwIfAborted() { if (this.aborted) throw this.reason ?? new AbortError(); }
            dispatchEvent(event) {
              for (const fn of this._listeners) {
                try { fn(event); } catch (_) {}
              }
            }
            static abort(reason) {
              const s = new AbortSignal();
              s.aborted = true;
              s.reason = reason ?? new AbortError();
              return s;
            }
            static timeout(ms) {
              const s = new AbortSignal();
              setTimeout(() => {
                if (!s.aborted) {
                  s.aborted = true;
                  s.reason = new AbortError("The operation timed out.");
                  s.dispatchEvent({ type: "abort" });
                }
              }, ms);
              return s;
            }
          }
          class AbortController {
            constructor() { this.signal = new AbortSignal(); }
            abort(reason) {
              if (this.signal.aborted) return;
              this.signal.aborted = true;
              this.signal.reason = reason ?? new AbortError();
              this.signal.dispatchEvent({ type: "abort" });
            }
          }
          globalThis.AbortController = AbortController;
          globalThis.AbortSignal = AbortSignal;
          globalThis.AbortError = AbortError;

          // structuredClone — JSON-roundtrip subset. Good enough for
          // plain data; throws on functions/cycles like the real
          // structuredClone.
          globalThis.structuredClone = (value, _opts) => {
            // Fast path for primitives.
            if (value === null) return null;
            const t = typeof value;
            if (t !== "object" && t !== "function") return value;
            if (t === "function") throw new Error("structuredClone: functions not supported");
            return JSON.parse(JSON.stringify(value));
          };
        })();
        """#
        context.evaluateScript(source)
    }

    /// Expose `module` and `exports` at the top level so an entry
    /// script can use ESM-ish `export const` etc. (rewritten to
    /// `exports.x = ...`) without being run via `require()`. Node
    /// does the same for entry-point CommonJS scripts.
    private func installEntryModuleScope() {
        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setObject(exports, forKeyedSubscript: "exports")
        setGlobal("module", module)
        setGlobal("exports", exports)
    }

    // MARK: - console

    private func installConsole() {
        let console = JSValue(newObjectIn: context)!

        let log = block { [weak self] args in
            guard let self else { return nil }
            self.stdout(self.formatArgs(args) + "\n")
            return nil
        }
        let err = block { [weak self] args in
            guard let self else { return nil }
            self.stderr(self.formatArgs(args) + "\n")
            return nil
        }

        for name in ["log", "info", "debug", "trace"] {
            console.setObject(log, forKeyedSubscript: name)
        }
        for name in ["error", "warn"] {
            console.setObject(err, forKeyedSubscript: name)
        }
        setGlobal("console", console)

        // Layer extras (time/count/group/assert) on top in pure JS so
        // they pick up our `log`/`error` that already write to the
        // injected sinks.
        let extras = #"""
        (() => {
          const c = globalThis.console;
          const timers = new Map();
          const counters = new Map();
          let groupDepth = 0;
          const indent = () => "  ".repeat(groupDepth);
          const wrap = (level, fn) => (...args) => fn(indent() + (typeof args[0] === "string" ? args[0] : JSON.stringify(args[0])), ...args.slice(1));
          // Override log/info/error/warn to honour group indent.
          const baseLog = c.log;
          const baseErr = c.error;
          c.log = (...a) => baseLog(indent() + (a.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ")));
          c.info = c.log; c.debug = c.log; c.trace = c.log;
          c.error = (...a) => baseErr(indent() + (a.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ")));
          c.warn = c.error;

          c.time = (label = "default") => { timers.set(label, performance.now()); };
          c.timeEnd = (label = "default") => {
            const start = timers.get(label);
            if (start === undefined) { c.warn("Timer '" + label + "' does not exist"); return; }
            timers.delete(label);
            c.log(label + ": " + (performance.now() - start).toFixed(3) + "ms");
          };
          c.timeLog = (label = "default", ...rest) => {
            const start = timers.get(label);
            if (start === undefined) return;
            c.log(label + ": " + (performance.now() - start).toFixed(3) + "ms", ...rest);
          };
          c.count = (label = "default") => {
            const n = (counters.get(label) ?? 0) + 1;
            counters.set(label, n);
            c.log(label + ": " + n);
          };
          c.countReset = (label = "default") => counters.delete(label);
          c.group = (...args) => { if (args.length) c.log(...args); groupDepth++; };
          c.groupCollapsed = c.group;
          c.groupEnd = () => { groupDepth = Math.max(0, groupDepth - 1); };
          c.assert = (cond, ...args) => {
            if (!cond) c.error("Assertion failed:", ...args);
          };
          c.dir = (obj, _opts) => c.log(JSON.stringify(obj, null, 2));
          c.table = (data) => c.log(JSON.stringify(data, null, 2));
        })();
        """#
        context.evaluateScript(extras)
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

    private func installProcess() {
        let process = JSValue(newObjectIn: context)!

        // process.argv: a regular JS Array snapshotted from the
        // provider. Matches Node — it's a real array, supports
        // for-of/spread/slice, and mutations are local to the
        // reference (don't propagate back to the provider).
        // Embedders that need to update it mid-run can call
        // ``JSRuntime.refreshArgv()`` to re-sync from the provider.
        process.setObject(argvProvider.argv(), forKeyedSubscript: "argv")

        // process.env is a JS Proxy that routes every read/write
        // through the EnvProvider. Setting `process.env.X = "y"`
        // calls envProvider.set(...), which for OSEnvProvider also
        // propagates to setenv() so child processes see the change.
        //
        // Identity redirect: when an embedder has bound a non-default
        // Shell (i.e. there's confinement in play), reads and writes
        // route through `Shell.current.environment.variables` instead
        // — so a sandboxed JS script sees the bound shell's env, not
        // the host's. Under `Shell.processDefault` (standalone CLI)
        // we keep the legacy `OSEnvProvider`-via-`setenv` behaviour
        // so child processes spawned by the host still see writes.
        let envGet = block { [weak self] args in
            guard let key = args.first?.toString() else { return nil }
            if Shell.current !== Shell.processDefault {
                return Shell.current.environment.variables[key]
            }
            return self?.envProvider.get(key)
        }
        let envSet = block { [weak self] args in
            guard args.count >= 2,
                  let key = args[0].toString()
            else { return false }
            let value = args[1]
            if Shell.current !== Shell.processDefault {
                if value.isNull || value.isUndefined {
                    Shell.current.environment.variables.removeValue(forKey: key)
                } else {
                    Shell.current.environment.variables[key] = value.toString() ?? ""
                }
                return true
            }
            if value.isNull || value.isUndefined {
                self?.envProvider.set(key, nil)
            } else {
                self?.envProvider.set(key, value.toString())
            }
            return true
        }
        let envHas = block { [weak self] args in
            guard let key = args.first?.toString() else { return false }
            if Shell.current !== Shell.processDefault {
                return Shell.current.environment.variables[key] != nil
            }
            return self?.envProvider.get(key) != nil
        }
        let envKeys = block { [weak self] _ in
            if Shell.current !== Shell.processDefault {
                return Array(Shell.current.environment.variables.keys)
            }
            return self?.envProvider.allKeys ?? []
        }
        let envDel = block { [weak self] args in
            guard let key = args.first?.toString() else { return false }
            if Shell.current !== Shell.processDefault {
                Shell.current.environment.variables.removeValue(forKey: key)
                return true
            }
            self?.envProvider.set(key, nil)
            return true
        }
        setGlobal("__swiftjs_envGet", envGet)
        setGlobal("__swiftjs_envSet", envSet)
        setGlobal("__swiftjs_envHas", envHas)
        setGlobal("__swiftjs_envKeys", envKeys)
        setGlobal("__swiftjs_envDel", envDel)

        let envProxy = context.evaluateScript(#"""
        new Proxy({}, {
          get(_, key)            { return globalThis.__swiftjs_envGet(String(key)); },
          set(_, key, value)     { return globalThis.__swiftjs_envSet(String(key), value); },
          has(_, key)            { return globalThis.__swiftjs_envHas(String(key)); },
          deleteProperty(_, key) { return globalThis.__swiftjs_envDel(String(key)); },
          ownKeys()              { return globalThis.__swiftjs_envKeys(); },
          getOwnPropertyDescriptor(t, key) {
            const v = globalThis.__swiftjs_envGet(String(key));
            return v === undefined ? undefined
              : { enumerable: true, configurable: true, writable: true, value: v };
          },
        });
        """#)!
        process.setObject(envProxy, forKeyedSubscript: "env")

        #if os(macOS)
        process.setObject("darwin", forKeyedSubscript: "platform")
        #elseif os(iOS)
        process.setObject("ios", forKeyedSubscript: "platform")
        #elseif os(Linux)
        process.setObject("linux", forKeyedSubscript: "platform")
        #elseif os(Android)
        process.setObject("android", forKeyedSubscript: "platform")
        #else
        process.setObject("unknown", forKeyedSubscript: "platform")
        #endif

        #if arch(arm64)
        process.setObject("arm64", forKeyedSubscript: "arch")
        #elseif arch(x86_64)
        process.setObject("x64", forKeyedSubscript: "arch")
        #else
        process.setObject("unknown", forKeyedSubscript: "arch")
        #endif

        process.setObject("v22.0.0-swiftjs", forKeyedSubscript: "version")

        // process.pid / process.ppid: under a bound Shell, return
        // ``Shell.virtualPID`` (synthetic — defaults to 1) so a
        // sandboxed script never sees the embedder's real PID. Under
        // ``Shell.processDefault`` we keep `getpid()` / `getppid()`
        // so the standalone `swift-js` CLI behaves unchanged.
        // Defined as Proxy-backed accessors via JS Object.defineProperty
        // because the value has to be re-read at access time — pid is a
        // task-local quantity, baking it in at init would freeze the
        // standalone-mode value into a Shell-bound run.
        let pidGetter = block { _ in
            if Shell.current === Shell.processDefault {
                return Int(getpid())
            }
            return Int(Shell.current.virtualPID)
        }
        let ppidGetter = block { _ in
            if Shell.current === Shell.processDefault {
                return Int(getppid())
            }
            // No virtualPPID concept in ShellKit yet; mirror SwiftScript
            // and return the same virtualPID (parent of `1` is `1`
            // under embedded init-style semantics).
            return Int(Shell.current.virtualPID)
        }
        // Bind getters on the local `process` JSValue directly —
        // `globalThis.process` isn't set until the bottom of this
        // method, so a getter that reads from globalThis would fire
        // too early.
        let installPidProps = context.evaluateScript(#"""
        (function (process, getPid, getPpid) {
          Object.defineProperty(process, "pid",  { get: getPid,  enumerable: true, configurable: true });
          Object.defineProperty(process, "ppid", { get: getPpid, enumerable: true, configurable: true });
        })
        """#)!
        installPidProps.call(withArguments: [process, pidGetter, ppidGetter])

        let exit = block { [weak self] args in
            guard let self else { return nil }
            let code = args.first?.toInt32() ?? 0
            self.didExit = true
            self.exitCode = code
            // Cancel pending timers so the runloop drains immediately.
            for (_, timer) in self.pendingTimers { timer.cancel() }
            self.pendingTimers.removeAll()
            let ex = JSValue(object: ["__swiftjs_exit": true, "code": code],
                             in: self.context)
            self.context.exception = ex
            return nil
        }
        process.setObject(exit, forKeyedSubscript: "exit")

        let cwd = block { _ in
            if Shell.current === Shell.processDefault {
                return FileManager.default.currentDirectoryPath
            }
            return Shell.current.environment.workingDirectory
        }
        process.setObject(cwd, forKeyedSubscript: "cwd")

        let chdir = block { [weak self] args in
            guard let path = args.first?.toString() else { return nil }
            // Resolve relative `path` against the current shell-CWD
            // first — Node accepts `process.chdir("./sub")` and
            // expects it to compose with the prior cwd. Storing the
            // raw relative string here would leave the bound CWD
            // unusable for subsequent `fs.*` ops.
            let resolved = resolveAgainstShellCWD(path)
            // Sandbox gate: chdir into a denied region is a write —
            // it would let a script position subsequent relative-path
            // ops anywhere. Surface as a Node-style EACCES.
            do {
                try self?.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self?.throwSandboxDenial(error, syscall: "chdir", path: path)
                return nil
            }
            if Shell.current === Shell.processDefault {
                FileManager.default.changeCurrentDirectoryPath(resolved)
            }
            Shell.current.environment.workingDirectory = resolved
            return nil
        }
        process.setObject(chdir, forKeyedSubscript: "chdir")

        let hrtime = block { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            return [Int(now / 1_000_000_000), Int(now % 1_000_000_000)]
        }
        process.setObject(hrtime, forKeyedSubscript: "hrtime")

        // process.stdout.write(string) / .stderr.write(string)
        // — print without an automatic trailing newline.
        let stdoutWrite = block { [weak self] args in
            guard let v = args.first else { return false }
            self?.stdout(JSRuntime.stringFromWritable(v))
            return true
        }
        let stderrWrite = block { [weak self] args in
            guard let v = args.first else { return false }
            self?.stderr(JSRuntime.stringFromWritable(v))
            return true
        }
        let stdoutObj = JSValue(newObjectIn: context)!
        stdoutObj.setObject(stdoutWrite, forKeyedSubscript: "write")
        stdoutObj.setObject(true, forKeyedSubscript: "isTTY")
        process.setObject(stdoutObj, forKeyedSubscript: "stdout")
        let stderrObj = JSValue(newObjectIn: context)!
        stderrObj.setObject(stderrWrite, forKeyedSubscript: "write")
        stderrObj.setObject(true, forKeyedSubscript: "isTTY")
        process.setObject(stderrObj, forKeyedSubscript: "stderr")

        // process.on('event', fn) — only `exit` is honoured.
        let on = block { [weak self] args in
            guard let self, args.count >= 2,
                  let event = args[0].toString()
            else { return nil }
            let fn = args[1]
            if event == "exit" { self.exitListeners.append(fn) }
            // Return process for chaining (Node convention).
            return self.context.objectForKeyedSubscript("process")
        }
        process.setObject(on, forKeyedSubscript: "on")

        // process.exitCode — getter/setter via Object.defineProperty.
        // Stored on a hidden field; the CLI reads `runtime.exitCode`
        // directly.
        let exitCodeGet = block { [weak self] _ in
            self?.exitCode ?? 0
        }
        let exitCodeSet = block { [weak self] args in
            self?.exitCode = args.first?.toInt32() ?? 0
            return nil
        }
        setGlobal("__swiftjs_exitCodeGet", exitCodeGet)
        setGlobal("__swiftjs_exitCodeSet", exitCodeSet)

        setGlobal("process", process)

        // Define exitCode as an accessor on process so reads/writes
        // round-trip through the runtime's `exitCode` field.
        // Capture the bridges by closure (not name lookup) so we can
        // safely scrub the globals afterwards.
        context.evaluateScript(#"""
        (() => {
          const G = globalThis.__swiftjs_exitCodeGet;
          const S = globalThis.__swiftjs_exitCodeSet;
          Object.defineProperty(process, "exitCode", {
            get() { return G(); },
            set(v) { S(v); },
            enumerable: true,
          });
          delete globalThis.__swiftjs_exitCodeGet;
          delete globalThis.__swiftjs_exitCodeSet;
        })();
        """#)

        // Stdin is wired last so the `Object.defineProperty(process,
        // …)` call inside it has `process` already bound on
        // `globalThis`. (The stream classes it depends on are
        // installed lazily on first read.)
        installProcessStdin(on: process)
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

        let utf8Encode = block { args in
            guard let s = args.first?.toString() else { return [UInt8]() }
            return Array(s.utf8)
        }
        native.setObject(utf8Encode, forKeyedSubscript: "utf8Encode")

        let utf8Decode = block { args in
            guard let value = args.first else { return "" }
            // Accept either a Uint8Array or a plain Array of bytes.
            let bytes = Self.bytes(from: value)
            return String(decoding: bytes, as: UTF8.self)
        }
        native.setObject(utf8Decode, forKeyedSubscript: "utf8Decode")

        let toBase64 = block { args in
            guard let value = args.first else { return "" }
            return Data(Self.bytes(from: value)).base64EncodedString()
        }
        native.setObject(toBase64, forKeyedSubscript: "toBase64")

        let fromBase64 = block { args in
            guard let s = args.first?.toString() else { return [UInt8]() }
            return Array(Data(base64Encoded: s) ?? Data())
        }
        native.setObject(fromBase64, forKeyedSubscript: "fromBase64")

        let toHex = block { args in
            guard let value = args.first else { return "" }
            return Self.bytes(from: value).map { String(format: "%02x", $0) }.joined()
        }
        native.setObject(toHex, forKeyedSubscript: "toHex")

        let fromHex = block { args in
            guard let s = args.first?.toString() else { return [UInt8]() }
            return stride(from: 0, to: s.count, by: 2).compactMap { i -> UInt8? in
                let start = s.index(s.startIndex, offsetBy: i)
                let end = s.index(start, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                return UInt8(s[start..<end], radix: 16)
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
    static func stringFromWritable(_ v: JSValue) -> String {
        if v.isString { return v.toString() ?? "" }
        if let arr = v.toArray() as? [NSNumber] {
            return String(decoding: arr.map { $0.uint8Value }, as: UTF8.self)
        }
        return v.toString() ?? ""
    }

    private static func bytes(from value: JSValue) -> [UInt8] {
        let array = value.toArray() ?? []
        return array.compactMap { ($0 as? NSNumber)?.uint8Value }
    }

    // MARK: - URL polyfill (minimal — Foundation backs it)

    private func installWebGlobals() {
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
