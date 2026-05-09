import Foundation



extension JSRuntime {

    /// Build the `node:stream` module — `Readable`, `Writable`, plus
    /// the helpers that `child_process.spawn` and `process.stdin`
    /// build on. The classes are pure JS on top of `EventEmitter`,
    /// fed from Swift via `_push(chunk)` / `_end()` for `Readable`
    /// and an `_onWrite` hook for `Writable`.
    ///
    /// Limits, by design (see issue #6):
    ///   - No real backpressure — `write()` always returns `true`,
    ///     no `'drain'` is emitted, and `pipe` is a naïve forward.
    ///   - No `Duplex` / `Transform` / `pipeline`.
    ///   - No `objectMode` — chunks are always Buffers (or strings).
    func makeStreamModule() -> JSValue {
        installStreamClasses()
        let mod = context.objectForKeyedSubscript("__swiftjs_stream")!
        // The classes are stashed under a private global by the
        // installer so we can hand back the same constructors here.
        return mod
    }

    /// Idempotent. Defines `__swiftjs_stream = { Readable, Writable }`
    /// on `globalThis` and a small `__swiftjs_makeStreamPair()` helper
    /// that the spawn glue uses to mint a Readable backed by Swift.
    func installStreamClasses() {
        if let existing = context.objectForKeyedSubscript("__swiftjs_stream"),
           !existing.isUndefined {
            return
        }
        let source = #"""
        (() => {
          const events = (() => {
            // Reuse the same EventEmitter the user-facing `node:events`
            // module exports — keeps one set of semantics.
            const cache = globalThis.__swiftjs_module_cache;
            return cache && cache["events"] ? cache["events"] : require("node:events");
          })();
          const EventEmitter = events.EventEmitter ?? events;

          // Mode is the most subtle bit. A Readable starts in 'paused'.
          // The first `on('data', …)` flips it to 'flowing' and we
          // drain the buffer; the first `for await` flips it to 'iter'
          // and chunks are routed to the iterator's pending resolvers.
          // Mixing the two on the same stream is undefined behaviour
          // (Node's docs say the same).
          class Readable extends EventEmitter {
            constructor() {
              super();
              this._buf = [];
              this._ended = false;
              this._destroyed = false;
              this._mode = "paused";
              this._waiters = [];
              // _onDestroy(): native-side cleanup hook fired by
              // destroy(). process.stdin uses it to detach the
              // FileHandle.readabilityHandler and cancel its sentinel
              // timer; without it, a `for await … of process.stdin`
              // loop that breaks early would leave the runloop
              // pinned waiting for stdin EOF.
              this._onDestroy = null;
              this.readable = true;
            }

            // Called from native code (or from JS in tests). `null`
            // chunks mean EOF.
            _push(chunk) {
              if (this._ended || this._destroyed) return;
              if (chunk == null) { this._end(); return; }
              if (this._mode === "iter") {
                if (this._waiters.length > 0) {
                  const r = this._waiters.shift();
                  r({ value: chunk, done: false });
                } else {
                  this._buf.push(chunk);
                }
                return;
              }
              if (this._mode === "flowing") {
                this.emit("data", chunk);
                return;
              }
              this._buf.push(chunk);
            }

            _end() {
              if (this._ended) return;
              this._ended = true;
              this.readable = false;
              if (this._mode === "flowing") {
                while (this._buf.length > 0) this.emit("data", this._buf.shift());
              } else if (this._mode === "iter") {
                while (this._waiters.length > 0) {
                  const r = this._waiters.shift();
                  r({ value: undefined, done: true });
                }
              }
              this.emit("end");
              this.emit("close");
            }

            // Tear down the stream: drop buffered data, resolve any
            // pending iterator waiters, fire `_onDestroy` so native
            // producers can detach. If the stream hadn't already
            // ended, emit `'close'` (no synthetic `'end'` — node only
            // emits `'end'` on normal completion). Idempotent.
            destroy() {
              if (this._destroyed) return;
              this._destroyed = true;
              this._buf = [];
              while (this._waiters.length > 0) {
                const r = this._waiters.shift();
                r({ value: undefined, done: true });
              }
              if (this._onDestroy) {
                try { this._onDestroy(); } catch (_) {}
              }
              if (!this._ended) {
                this._ended = true;
                this.readable = false;
                this.emit("close");
              }
            }

            on(event, fn) {
              super.on(event, fn);
              if (event === "data" && this._mode === "paused") {
                this._mode = "flowing";
                while (this._buf.length > 0) this.emit("data", this._buf.shift());
                // If the stream had already ended in 'paused' mode,
                // _end() already emitted end/close — re-emitting here
                // would double-fire cleanup logic for any listener
                // that was attached before _end ran.
              }
              return this;
            }

            // Naïve pipe: forward every chunk, end when source ends.
            // No backpressure — `write()` returns true regardless.
            pipe(dest) {
              this.on("data", (chunk) => {
                if (dest && typeof dest.write === "function") dest.write(chunk);
              });
              this.on("end", () => {
                if (dest && typeof dest.end === "function") dest.end();
              });
              return dest;
            }

            [Symbol.asyncIterator]() {
              if (this._mode === "paused") this._mode = "iter";
              const self = this;
              return {
                next() {
                  if (self._destroyed) {
                    return Promise.resolve({ value: undefined, done: true });
                  }
                  if (self._buf.length > 0) {
                    return Promise.resolve({ value: self._buf.shift(), done: false });
                  }
                  if (self._ended) {
                    return Promise.resolve({ value: undefined, done: true });
                  }
                  return new Promise((resolve) => self._waiters.push(resolve));
                },
                // for-await early exit (`break` / `return` / `throw`)
                // funnels through here. Destroy the stream so native
                // producers can detach and any sentinel timers get
                // cancelled — otherwise a stdin loop that breaks
                // early would hang the runtime.
                return() {
                  self.destroy();
                  return Promise.resolve({ value: undefined, done: true });
                },
              };
            }
          }

          class Writable extends EventEmitter {
            constructor(opts = {}) {
              super();
              // _onWrite(chunk) — called on every write. _onEnd() —
              // called on end(). The ChildProcess stdin glue plugs
              // these in to forward bytes to the native side.
              this._onWrite = opts.write ?? null;
              this._onEnd = opts.final ?? null;
              this._ended = false;
              this.writable = true;
            }

            write(chunk) {
              if (this._ended) return false;
              if (this._onWrite) {
                try { this._onWrite(chunk); } catch (_) {}
              }
              return true;
            }

            end(chunk) {
              if (chunk != null) this.write(chunk);
              if (this._ended) return this;
              this._ended = true;
              this.writable = false;
              if (this._onEnd) {
                try { this._onEnd(); } catch (_) {}
              }
              this.emit("finish");
              this.emit("close");
              return this;
            }
          }

          globalThis.__swiftjs_stream = { Readable, Writable };
        })();
        """#
        context.evaluateScript(source)
    }
}

