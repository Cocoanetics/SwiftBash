#if !os(Windows)

import Foundation

// Pure-JS module shims (`node:assert`, `node:events`,
// `node:querystring`, `node:perf_hooks`, `node:util`, `node:url`).
// Each factory is a single evaluateScript of a large inline JS source —
// they live here so `Modules.swift` stays focused on orchestration.

extension JSRuntime {

    // MARK: - node:assert (pure JS)

    // Body is a single large inline JS source literal implementing
    // node:assert (AssertionError, ok, equal, throws, …) — can't be
    // meaningfully extracted.
    // swiftlint:disable:next function_body_length
    func makeAssertModule() -> JSValue {
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
          fn.notEqual = (a, b, m) => {
            if (a == b) {
              fail({ actual: a, expected: b, message: m, operator: "!=" });
            }
          };
          fn.strictEqual = strictEq;
          fn.notStrictEqual = (a, b, m) => {
            if (a === b) {
              fail({ actual: a, expected: b, message: m, operator: "!==" });
            }
          };
          fn.deepEqual = deepEq;
          fn.deepStrictEqual = deepEq;
          fn.throws = throws;
          fn.doesNotThrow = (f) => {
            try { f(); }
            catch { fail({ message: "Got unwanted exception" }); }
          };
          fn.match = (str, re, m) => {
            if (!re.test(str)) {
              fail({
                actual: str,
                expected: re.source,
                message: m,
                operator: "match"
              });
            }
          };
          fn.strict = fn;
          return fn;
        })()
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - node:events (EventEmitter, pure JS)

    // Body is a single large inline JS source literal implementing the
    // EventEmitter class — can't be meaningfully extracted.
    // swiftlint:disable:next function_body_length
    func makeEventsModule() -> JSValue {
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

    func makeQuerystringModule() -> JSValue {
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

    func makePerfHooksModule() -> JSValue {
        let source = #"""
        ({
          performance: globalThis.performance,
          monotonicTimeOrigin: globalThis.performance?.timeOrigin,
        })
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - util (very small subset)

    func makeUtilModule() -> JSValue {
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

    func makeUrlModule() -> JSValue {
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
