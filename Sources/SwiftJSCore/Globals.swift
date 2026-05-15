#if !os(Windows)

import Foundation
import BashInterpreter

// Foundation pulls libc through transitively on Apple and Linux,
// but the Android Swift toolchain doesn't re-export Bionic's
// `getpid` / `getppid` / etc. via Foundation. Pick up the libc
// module explicitly. The Android module name varies between Swift
// toolchains (`Android` in skiptools/swift-android-action,
// `Bionic` in some upstream snapshots), so we try both.
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
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
            if let stream = args.first { self?.beginStdinRead(into: stream) }
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

        let fileHandle = FileHandle.standardInput
        // Idempotent teardown shared by the EOF path and the JS-side
        // `destroy()` hook. Without this, a `for await` loop that
        // breaks early on `process.stdin` would leave the sentinel
        // alive and `drainPendingWorkIfNeeded()` would hang waiting
        // for stdin EOF that never comes.
        let teardown: @Sendable () -> Void = { [weak self] in
            fileHandle.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let timer = self.pendingTimers.removeValue(forKey: sentinelID)
                else { return }
                timer.cancel()
            }
        }

        fileHandle.readabilityHandler = { handle in
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

    // swiftlint:disable:next function_body_length - body is mostly an inline JS source string
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

    // swiftlint:disable:next function_body_length - mostly verbose closure plumbing for console.* members
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
          const wrap = (level, fn) => (...args) => fn(
            indent()
            + (typeof args[0] === "string" ? args[0] : JSON.stringify(args[0])),
            ...args.slice(1));
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
        if let result = json?.invokeMethod("stringify", withArguments: [value]),
           !result.isUndefined, !result.isNull,
           let str = result.toString(), str != "undefined" {
            return str
        }
        return value.toString() ?? "[object]"
    }

    // `installProcess` lives in `Globals+Process.swift`.
    // `installBufferAndEncodingBridges`, `installWebGlobals`,
    // `stringFromWritable`, and `bytes(from:)` live in
    // `Globals+BufferEncoding.swift`.
}

#endif  // !os(Windows)
