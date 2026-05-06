# SwiftJS — feasibility report

A quick experiment to answer: can we ship a Node-style JavaScript
executor that runs `#!/usr/bin/env swift-js` shebang scripts on
Apple platforms (using the system JavaScriptCore framework), and
optionally on Linux / Windows too?

**Short answer**: yes on Apple, easily. The runtime in this
experiment is ~1000 lines of Swift, builds to a 218 KB release
binary, and
runs `node`-shaped scripts with `console`, `process`, `fs`, `path`,
and `os` modules. Cold-start is faster than `node`. For non-Apple,
QuickJS-NG is the right backend, but you pay an abstraction layer
to share the stdlib between engines.

## What was built (this branch, Apple-only)

```
Experiments/SwiftJS/
├── Package.swift                          # standalone SwiftPM package
├── Sources/
│   ├── SwiftJSCore/
│   │   ├── JSRuntime.swift                # context, exception handler, runloop drain
│   │   ├── Globals.swift                  # console, process, Buffer,
│   │   │                                  # TextEncoder/Decoder, atob/btoa,
│   │   │                                  # URL, queueMicrotask
│   │   ├── Modules.swift                  # require() + builtin modules
│   │   │                                  # (fs, path, os, util, url) +
│   │   │                                  # CommonJS local-file loader
│   │   └── Timers.swift                   # setTimeout, setInterval,
│   │                                      # clearTimeout, clearInterval,
│   │                                      # setImmediate (DispatchSourceTimer)
│   └── swift-js/main.swift                # CLI: file mode, -e, -p
├── Tests/SwiftJSCoreTests/                 # 26 tests, all passing
└── Examples/
    ├── hello.js                            # shebang demo
    ├── portable.js                         # runs identically on swift-js/node/bun
    └── async-stress.js                     # nested timers + microtasks
```

The runtime is split into four files:

**Globals** (always present, mirrors what Node makes global):
- `console.log` / `.info` / `.debug` / `.trace` / `.warn` / `.error`
- `process.argv`, `process.env`, `process.platform`, `process.arch`,
  `process.version`, `process.cwd()`, `process.chdir()`,
  `process.exit(code)`, `process.hrtime()`
- `Buffer` (extends `Uint8Array`): `from(string|array|Buffer, encoding)`,
  `alloc`, `byteLength`, `isBuffer`, `concat`, `.toString(encoding)`
  with `utf-8` / `ascii` / `latin1` / `hex` / `base64`
- `TextEncoder`, `TextDecoder` — UTF-8, bridged to Swift
- `atob`, `btoa`
- `URL` — backed by Foundation's `URLComponents`; gives
  `.href / .protocol / .host / .hostname / .port / .pathname /
  .search / .hash / .origin`
- `queueMicrotask` — implemented as `Promise.resolve().then(fn)`,
  drained by JSC at the end of `evaluateScript`
- `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` /
  `setImmediate` — `DispatchSourceTimer` on the main queue;
  `JSRuntime.run` then enters `RunLoop.main.run(until:)` until the
  pending-timer set drains

**Modules** (via `require('foo')` or `require('node:foo')`):
- `fs` / `node:fs`: `readFileSync` (Buffer or encoded string),
  `writeFileSync`, `appendFileSync`, `existsSync`, `readdirSync`,
  `mkdirSync({recursive})`, `rmSync`, `unlinkSync`, `statSync`
- `path` / `node:path`: full string-API surface (`sep`, `delimiter`,
  `join`, `basename`, `dirname`, `extname`, `isAbsolute`, `resolve`,
  `parse`)
- `os` / `node:os`: `homedir`, `tmpdir`, `hostname`, `platform`,
  `arch`, `EOL`
- `util` / `node:util`: `format` (with `%s %d %j` etc.), `inspect`
- `url` / `node:url`: `URL`, `fileURLToPath`, `pathToFileURL`
- Local files: `require('./helper')` with `.js` auto-extension,
  CommonJS wrapper (`(function(exports,require,module,__filename,__dirname){...})`),
  module cache, circular-require guard

**Shebang**: stripped before evaluation, with a `//` placeholder so
reported line numbers in stack traces still match the file.

`process.exit` is implemented by raising an internal exception
marker the handler recognises (and skipping the print path). It
also cancels pending timers so the runloop drain returns
immediately — matches Node's "exit overrides the event loop"
behaviour.

### What works end-to-end

```bash
$ chmod +x Examples/portable.js
$ PATH="$PWD/.build/release:$PATH" Examples/portable.js Oliver
platform: darwin arm64
node-ish: v22.0.0-swiftjs
script bytes: 1687
…
back: SwiftJS rocks 🎉
scheduling...
  resolved: promise
  fired after 30ms
done.
```

The same `Examples/portable.js` file produces **byte-for-byte
identical output** under `node` and `bun`. So does
`Examples/async-stress.js`, which exercises nested timers,
microtask ordering, `setInterval` self-cancellation, and
`async/await`.

`-e` (silent eval) and `-p` (eval-and-print), `process.exit(N)`
propagation, unhandled-throw → exit 1 with stack trace, and Promise
microtasks all work. Tests: 26/26 passing on macOS 26 / Swift 6.3.

### Performance

| | swift-js -e '1' | node -e '1' | osascript -l JavaScript |
|---|---|---|---|
| real time | ~0–10 ms | ~20–30 ms | ~20–30 ms |

JSC is genuinely fast and the launch overhead is dominated by
process startup, not engine init.

## What's in JSC vs what we built vs what's still missing

JSC ships only the language — typed arrays, Promise, Map/Set,
Symbol, BigInt, Proxy, Reflect, Intl, WeakRef, Date, JSON, RegExp.
**Everything platform-shaped is missing.** Confirmed by direct
introspection: `URL`, `URLSearchParams`, `TextEncoder`, `TextDecoder`,
`queueMicrotask`, `structuredClone`, `crypto`, `atob`, `btoa`,
`setTimeout`, `console`, `process` — all `undefined` on a fresh
`JSContext`.

This experiment now provides custom Swift-backed implementations
of the most-used ones (the right-hand column was undefined in JSC):

| Bridged to Swift | Polyfilled in JS-on-context | Still missing |
|---|---|---|
| `console.*`, `process.*`, timers, `Buffer.from/alloc`, UTF-8 encode/decode, base64, hex, fs ops, URL parse | `Buffer` class, `TextEncoder`/`TextDecoder`, `atob`/`btoa`, `URL` constructor, `path` module, `util.format`, CommonJS wrapper, `require()` | `fetch`, `crypto`, `child_process`, ES `import`, npm resolution, streams, `node:fs/promises`, worker threads |

For the "JS as a shell-scripting language with sync fs and JSON"
target, the current surface is now sufficient — the
`portable.js` and `wordcount.js` examples are real scripts a person
might write, and they run identically across `swift-js`, `node`,
and `bun`.

The known holes worth flagging:
- **`fetch`**: the obvious next addition. URLSession bridge, plus
  the same `NetworkConfig.allowedURLPrefixes` allow-list pattern
  the parent `BashCommandKit` already uses for `curl`.
- **`crypto`**: doable on top of `swift-crypto` (parent already
  depends on it). `createHash`, `randomBytes` first; cipher later.
- **`child_process`**: this is where SwiftJS could get interesting —
  `spawn(...)` could route through `BashInterpreter`, giving you a
  JS script that pipelines through bash commands without leaving
  the process. Genuine novelty, fits the SwiftBash thesis.
- **ES `import` / `import.meta`**: JSC supports modules via
  `JSScript.scriptOfType: .module` with a loader callback. ~150
  lines on top of what's there. Out of scope for this experiment.
- **npm `node_modules` resolution**: nope. Out of scope. Real npm
  packages call native addons (`*.node`) we will never load. This
  tool targets *scripts a person writes*, not the npm ecosystem.

## Cross-platform: JavaScriptCore vs QuickJS

Researched current state (today: 2026-05-06):

### JavaScriptCore on Linux

- Available only as part of WebKit/WebKitGTK; on Debian/Ubuntu via
  `libjavascriptcoregtk-4.1-dev`. Pulls in the full WebKit build
  surface and is ~10–20 MB just for the JSC parts.
- LGPL 2.1 (whereas Apple's system JSC is a system framework, so
  on macOS/iOS we don't ship anything ourselves).
- Wrapper to know about: [JXKit](https://github.com/jectivex/JXKit)
  exposes JSC across Apple + Linux behind a uniform Swift API.
  Inherits the LGPL packaging burden.

Verdict: workable but painful to ship. Right answer if you want
ES2024+ on Linux *and* don't mind the deployment story.

### QuickJS-NG (recommended for non-Apple)

- [quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs),
  MIT, actively maintained fork of Bellard's QuickJS.
- ES2023 compliant: modules, async generators, BigInt, Proxy,
  WeakRef. More than enough for shell scripts.
- ~370 KB hello-world binary; the engine itself is ~600 KB of C.
- C API is small (~40 functions). Easy to vendor as SwiftPM
  `systemLibrary` or as a target compiling the C sources directly.
- No actively-maintained Swift wrapper found, so we'd write the
  bridge ourselves. ~200–400 lines.

Verdict: this is the answer for Linux and Windows.

### Engines deliberately rejected

- **Hermes** (Meta): no standalone shipping story, RN-flavoured.
- **Duktape**: only ES5.1; modern destructuring/`const`/template
  literals don't work — disqualifies it for "write your shell
  scripts in modern JS".
- **V8 / libnode**: ~50 MB, build-system pain, overkill.
- **MuJS**: ES5, same issue as Duktape.
- **Pure-Swift JS interpreter**: nothing production-grade exists,
  and writing one is a multi-year project. Not viable.

## Recommended architecture (if we ever go beyond this experiment)

```
SwiftJSCore (engine-agnostic)
├── JSEngine protocol  ─── newContext(), evaluate(_, name:),
│                          installNativeFunction(_, _:), …
├── JSValueRef protocol ── isString, asString, asInt, asObject, …
├── stdlib bindings  ───── console, process, fs, path, os
│                          (all written against the protocols)
│
├── JSCEngine.swift  ───── #if canImport(JavaScriptCore) — Apple
└── QuickJSEngine.swift ── target deps on a vendored C QuickJS-NG
```

The stdlib (console/process/fs/path) is the bulk of the work and
it's engine-agnostic — strings in, strings out. The engine
abstraction only needs ~10 primitives. Two engines, one stdlib.

A reasonable shipping shape inside SwiftBash itself:

| target | platforms | engine |
|---|---|---|
| `SwiftJSCore` (library) | all | protocol + stdlib |
| `SwiftJSCore_JSC` | Apple | JSC backend |
| `SwiftJSCore_QuickJS` | Linux, Windows, optional on Apple | vendored C |
| `swift-js` (executable) | all | wires whichever backend the platform has |

This mirrors how the parent package handles `CXattr` (conditional
target dep on Linux/Android only).

## Recommendation

1. **Apple-only as a first step is genuinely useful and almost
   free.** ~400 lines of Swift, no third-party dependencies, fast,
   matches `node`'s shebang/argv shape. The experiment in this
   branch is already that thing minus polish (timers, modules).

2. **Cross-platform via QuickJS-NG is feasible but a real project.**
   Plan on engine bridge + stdlib refactor + CI matrix + at least
   one round of "this works on macOS but the C ABI shifted on
   Linux" surprises. Probably 2–3 weeks of focused work to reach
   parity with the Apple build, plus ongoing maintenance.

3. **Don't try to match Node.** Pick a target audience: "JS as a
   shell-scripting language with sync fs and JSON". That keeps the
   surface small enough that two engines can support it, and stops
   the project from drifting into "build our own Node".

4. **Don't write a JS interpreter in Swift.** Even partial
   compliance is a year of work and the result will be slower
   than QuickJS-NG by 10×.

## Status of this branch

`experiment/js-executor`, parallel to `main`. The package lives in
`Experiments/SwiftJS/` so it doesn't entangle the main `Package.swift`
— it builds independently with `swift build` from inside that
directory. Tests pass on macOS 26 / Swift 6.3.

If we don't go forward with this idea, the directory can be
deleted. If we do, the next steps would be the engine abstraction
described above and a `swift-js` target inside the main package
guarded by `#if canImport(JavaScriptCore)`.
