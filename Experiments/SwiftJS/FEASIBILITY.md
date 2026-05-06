# SwiftJS — feasibility report

A quick experiment to answer: can we ship a Node-style JavaScript
executor that runs `#!/usr/bin/env swift-js` shebang scripts on
Apple platforms (using the system JavaScriptCore framework), and
optionally on Linux / Windows too?

**Short answer**: yes on Apple, easily. The runtime in this
experiment is ~1700 lines of Swift across 7 files, builds to an
8 MB release binary (vs 57 MB for bun, 105 MB for node), and
runs `node`-shaped scripts with `console`, `process`, `fs`, `path`,
and `os` modules. Cold-start is faster than `node`. For non-Apple,
QuickJS-NG is the right backend, but you pay an abstraction layer
to share the stdlib between engines.

## What was built (this branch, Apple-only)

```
Experiments/SwiftJS/
├── Package.swift                          # standalone SwiftPM package
├── Resources/swift-js.entitlements        # JIT entitlement
├── scripts/codesign-jit.sh                # post-build sign helper
├── Sources/
│   ├── SwiftJSCore/
│   │   ├── JSRuntime.swift                # context, exception handler, runloop drain
│   │   ├── Globals.swift                  # console, process, Buffer,
│   │   │                                  # TextEncoder/Decoder, atob/btoa,
│   │   │                                  # URL, queueMicrotask
│   │   ├── Modules.swift                  # require() + builtin modules
│   │   │                                  # (fs, path, os, util, url) +
│   │   │                                  # CommonJS local-file loader
│   │   ├── Timers.swift                   # setTimeout, setInterval,
│   │   │                                  # clearTimeout, clearInterval,
│   │   │                                  # setImmediate (DispatchSourceTimer)
│   │   ├── Network.swift                  # fetch, Headers, Response (URLSession)
│   │   ├── Crypto.swift                   # createHash, createHmac,
│   │   │                                  # randomBytes, randomUUID,
│   │   │                                  # timingSafeEqual (CryptoKit)
│   │   ├── ChildProcess.swift             # execSync, spawnSync routed
│   │   │                                  # through SwiftBash's
│   │   │                                  # in-process bash interpreter
│   │   ├── ESMRewriter.swift              # static `import`/`export`
│   │   │                                  # → CommonJS preprocessor
│   │   └── EnvProvider.swift              # pluggable backing for
│   │                                      # process.env: OS / dict /
│   │                                      # SwiftBash Shell-shared
│   └── swift-js/main.swift                # CLI: file mode, -e, -p,
│                                          # `--sandbox-env` flag
├── Tests/SwiftJSCoreTests/                 # 52 tests, all passing
└── Examples/
    ├── hello.js                            # shebang demo
    ├── portable.js                         # runs identically on swift-js/node/bun
    ├── async-stress.js                     # nested timers + microtasks
    ├── everything.js                       # cross-runtime parity harness
    ├── bench.js                            # cross-runtime benchmark
    ├── sandbox-env.js                       # demo for --sandbox-env
    ├── shell-shared-env.swift               # bash↔JS shared env doc
    └── esm-app/                            # 3-file ES module app
        ├── main.mjs
        ├── Greeter.mjs
        └── util.mjs
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
- `fs/promises` / `node:fs/promises`: async wrappers over the sync
  fs ops (`readFile`, `writeFile`, `mkdir`, `rm`, `stat`, …)
- `path` / `node:path`: full string-API surface (`sep`, `delimiter`,
  `join`, `basename`, `dirname`, `extname`, `isAbsolute`, `resolve`,
  `parse`)
- `os` / `node:os`: `homedir`, `tmpdir`, `hostname`, `platform`,
  `arch`, `EOL`
- `util` / `node:util`: `format` (with `%s %d %j` etc.), `inspect`
- `url` / `node:url`: `URL`, `fileURLToPath`, `pathToFileURL`
- `crypto` / `node:crypto`: `createHash` (sha256/sha384/sha512/sha1/md5),
  `createHmac` (same algorithms), `randomBytes`, `randomUUID`,
  `timingSafeEqual` — backed by CryptoKit
- `child_process` / `node:child_process`: `execSync`, `spawnSync` —
  default backend is **SwiftBash's `BashInterpreter` running
  in-process**, no `fork`/`exec`. Pass `{ shell: 'host' }` (or set
  `SWIFTJS_HOST_SHELL=1`) to fall through to Foundation's `Process`
  on `/bin/sh`.
- Local files: `require('./helper')` with `.js` auto-extension,
  CommonJS wrapper (`(function(exports,require,module,__filename,__dirname){...})`),
  module cache, circular-require guard

**Network**:
- `fetch(url, init?) → Promise<Response>`. Backed by `URLSession`.
  `Response` has `.text()`, `.json()`, `.arrayBuffer()`, `.bytes()`,
  `.headers` (with `Headers` class), `.ok`, `.status`, `.url`.
  `init` accepts `method`, `headers`, `body` (string or Uint8Array).
  In-flight requests register a sentinel timer so the runloop
  drain keeps the process alive until the response arrives.

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

For full benchmark numbers see [§ Benchmarks](#benchmarks)
below. Briefly: cold start <1 ms (vs 10–20 ms for node/bun);
fib(28) and regex parity-or-faster vs node *with the JIT
entitlement applied*; Buffer/crypto bridge calls 70–100× slower
than node on tight loops.

## What's in JSC vs what we built vs what's still missing

JSC ships only the language — typed arrays, Promise, Map/Set,
Symbol, BigInt, Proxy, Reflect, Intl, WeakRef, Date, JSON, RegExp.
**Everything platform-shaped is missing.** Confirmed by direct
introspection: `URL`, `TextEncoder`/`TextDecoder`,
`queueMicrotask`, `structuredClone`, `crypto`, `atob`, `btoa`,
`setTimeout`, `fetch`, `console`, `process` — all `undefined` on a
fresh `JSContext`.

This experiment now bridges most of the surface a real-world
shell-style Node script touches:

| Now supported | How |
|---|---|
| `console`, `process`, timers, `setImmediate`, `queueMicrotask` | Swift bridges + JS shim |
| `Buffer`, `TextEncoder`/`Decoder`, `atob`, `btoa` | UTF-8/base64/hex bridged from Swift, classes built in JS on top |
| `URL`, `URLSearchParams`-equivalent fields | `URLComponents`-backed parser |
| `node:fs` (sync + promises wrapper) | Foundation `FileManager`/`Data` |
| `node:path`, `node:os`, `node:util`, `node:url` | Pure JS where possible, Swift for `os.*` |
| `node:crypto` (createHash/createHmac/randomBytes/randomUUID/timingSafeEqual) | CryptoKit |
| `node:child_process` (execSync/spawnSync) | **SwiftBash `BashInterpreter` in-process** by default; Foundation `Process` as opt-in fallback |
| `fetch`, `Response`, `Headers` | URLSession |
| `require('./local')`, `require('node:foo')` | CommonJS wrapper, module cache, circular guard |

| Still missing | Cost to add |
|---|---|
| `node:zlib` | small (parent has zlib) |
| `node:stream` | medium |
| Cipher/Decipher / pbkdf2 / scrypt in `crypto` | small (CryptoKit + a few spins) |
| Top-level `await` in modules | needs real `JSScript` module support, not exposed in public API |
| `node:worker_threads` | unclear — JSC's threading is not Node's |
| Native addons (`*.node`) | impossible |
| npm `node_modules` package resolution | out of scope |

### ES module syntax (`import` / `export`)

JSC's `evaluateScript` runs in script mode only. The `JSScript`
class with `SourceType.module` is forward-declared in JSC's
public headers but the actual class is not shipped — there's no
public way to evaluate ES modules.

The experiment works around this with a **regex-based rewriter**
(`Sources/SwiftJSCore/ESMRewriter.swift`) that runs before
evaluation. It transforms ESM-shape source into the equivalent
CommonJS:

| ESM | rewritten to |
|---|---|
| `import { a, b } from "./x"` | `const { a, b } = require("./x")` |
| `import { a as b } from "./x"` | `const { a: b } = require("./x")` |
| `import x from "./y"` | `const x = (() => { const __m = require("./y"); return __m.__esModule ? __m.default : __m; })();` |
| `import * as ns from "./y"` | `const ns = require("./y")` |
| `import x, { a } from "./y"` | combined form, default-with-`__esModule` honoured |
| `import "./side-effect"` | `require("./side-effect")` |
| `import("./dyn")` (dynamic) | `Promise.resolve(require("./dyn"))` |
| `import.meta.url` | `("file://" + __filename)` |
| `export const x = ...` | `const x = exports.x = ...` |
| `export function foo() {…}` | `const foo = exports.foo = function foo() {…}` |
| `export class Foo {…}` | `const Foo = exports.Foo = class Foo {…}` |
| `export default expr` | `exports.__esModule = true; exports.default = expr;` |
| `export { a, b as c }` | `exports.a = a; exports.c = b;` |

The loader recognises `.js`, `.mjs`, `.cjs`, and `.json` (the
last loaded as parsed data). `Examples/esm-app/` ships a 3-file
ES module application (default + named + namespace imports +
class export + dynamic import + `import.meta.url`) that produces
**byte-for-byte identical output on swift-js, node, and bun**.

What this approach can't do:
- **Top-level `await`** — script mode forbids it.
- `export * from "./x"` (re-export). Niche.
- `import "./x" assert { type: "json" }`. Niche.
- 100% correctness on adversarial source (a string literal
  containing `"export default 1"` will get mangled). The cost of
  fixing this is pulling in a JS parser, which is out of scope.

Trade-off summary: a regex pass beats waiting on Apple to ship
`JSScript` to Swift, and covers the forms a person actually
writes. A real solution would need either (a) Apple to expose the
module-loading API, or (b) embedding QuickJS-NG, which already
ships `JS_EvalThis(... JS_EVAL_TYPE_MODULE)`.

For the "JS as a shell-scripting language" target, the surface is
now complete enough that the **`Examples/everything.js` harness
produces byte-for-byte identical output** when run on `swift-js`,
`node`, and `bun`. See [§ Cross-runtime parity](#cross-runtime-parity).

## Cross-runtime parity

`Examples/everything.js` exercises every layer in one script:
process/os/path → fs (sync + Buffer) → Buffer/TextEncoder/URL →
crypto (sha256/md5/hmac/random) → child_process pipeline → util →
async (timers + microtasks + Promise). Running it on all three
runtimes:

```bash
$ swift-js everything.js Oliver > /tmp/sj.txt
$ node     everything.js Oliver > /tmp/n.txt
$ bun      everything.js Oliver > /tmp/b.txt
$ diff /tmp/sj.txt /tmp/n.txt && echo identical
$ diff /tmp/sj.txt /tmp/b.txt && echo identical
identical
identical
```

Same hashes, same Buffer hex, same URL parse, same microtask order,
same Promise order, same timer order. The only divergences worth
calling out:
- `URL` strips default-port `:443` for https on Node/Bun but not
  on our `URLComponents`-backed shim (use a non-default port to
  avoid the divergence).
- `child_process.execSync` returns `Buffer` by default in Node;
  ours defaults to a string. Pass `{ encoding: 'utf-8' }` to make
  it explicit and all three agree.

## Benchmarks

`Examples/bench.js` (release build, M1, JIT entitlement applied
via `scripts/codesign-jit.sh`):

| operation | swift-js | node v22 | bun v1.3 | swift-js vs node |
|---|---:|---:|---:|---:|
| fib(28) (3 runs) | 5 ms | 7 ms | 5 ms | **0.7×** (faster) |
| JSON.parse (3000 ops) | 1 ms | 1 ms | 1 ms | parity |
| regex test (300k) | 3 ms | 6 ms | 3 ms | **0.5×** (faster) |
| fs write+read (3000) | 277 ms | 170 ms | 100 ms | 1.6× slower |
| Buffer.from utf-8 (30k) | 509 ms | 7 ms | 4 ms | **73× slower** |
| sha256 hex (30k) | 1316 ms | 18 ms | 12 ms | **73× slower** |

| metric | swift-js | node | bun | deno |
|---|---:|---:|---:|---:|
| cold start `-e '0'` | <1 ms | 20 ms | 10 ms | 4 ms |
| binary size | 8.1 MB | 105 MB | 57 MB | – |

Two clear stories:

**Pure-JS performance is competitive — but only with the JIT
entitlement.** JavaScriptCore's high-tier JIT (FTL) requires
`com.apple.security.cs.allow-jit` in the binary's entitlements.
Without it, JSC falls back to the lower JIT tiers and `fib(30) x5`
took 280 ms; signed with the entitlement, the same runs in 18 ms.
SwiftPM's auto-generated ad-hoc signature **does not include JIT
entitlements** — the included `scripts/codesign-jit.sh` resigns
the binary with `Resources/swift-js.entitlements`. Once signed,
swift-js matches or beats node on tight pure-JS loops.

**Bridge crossings dominate when JS↔Swift is on the hot path.**
Each `Buffer.from(string)` and each `crypto.createHash().update()
.digest()` chain crosses the JS↔Swift boundary 1–3 times. Node
and Bun implement these as engine-internal C++, so they're 70–100×
faster on tight loops. For shell-script-shaped workloads this
doesn't matter (there's no inner loop on `Buffer.from`); for tight
data-munging it does.

The two known optimizations:
- For Buffer: keep `Buffer.from(string)` in pure JS using a
  manual UTF-8 encoder (avoid the Swift round-trip per call).
  Trades correctness on edge cases (invalid surrogates) for ~50×.
- For crypto: expose stateless functions like `crypto.sha256(data)`
  that do the whole hash in one Swift call, so 30k iterations cost
  30k bridge crossings instead of 90k. ~10× win.

Neither optimization is needed for the target use case — they're
listed for completeness.

## Pluggable `process.env` and `process.argv`

Out of the box, `process.env` reads the host process's environment
— same as `node`. But the experiment treats it as a **proxied
view over a pluggable provider**:

```swift
public protocol EnvProvider: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
    var allKeys: [String] { get }
}
```

Three backends ship:

| Backend | Reads from | Mutations propagate to |
|---|---|---|
| `OSEnvProvider` (default) | `ProcessInfo.environment` | `setenv()` (child processes see updates) |
| `DictionaryEnvProvider` | in-memory dict the embedder owns | the dict only |
| `ShellEnvProvider` | a `SwiftBash.Shell.environment` | the same `Shell` (bash code in that shell sees updates) |

The JS side never sees a frozen snapshot — `process.env` is a
`Proxy` whose `get`/`set`/`has`/`ownKeys`/`deleteProperty` traps
each call into Swift. So a `process.env.X = 'y'` actually invokes
`envProvider.set("X", "y")`, and the next `process.env.X` read
goes back through `envProvider.get`. Reads are live.

### CLI: `--sandbox-env`

Passing `--sandbox-env` switches the CLI to a `DictionaryEnvProvider`
pre-populated with the same minimal set `swift-bash exec --sandbox`
uses (`PATH=/usr/bin:/bin`, `HOME=/home/user`, `USER=user`,
`SHELL=/bin/sh`, `TERM=dumb`, `LANG=C.UTF-8`). The host's real
environment — secrets, tokens, the user's actual `$HOME` — is
invisible to the script.

```bash
$ SECRET_TOKEN=password "$SWIFTJS" sandbox-env.js
keys:    AI_AGENT, ANTHROPIC_API_KEY, …, SECRET_TOKEN, …  (49 vars)
hidden:  password

$ SECRET_TOKEN=password "$SWIFTJS" --sandbox-env sandbox-env.js
keys:    HOME, LANG, PATH, SHELL, TERM, USER  (6 vars)
hidden:  <not visible>
```

This composes naturally with SwiftBash's existing per-axis
sandboxing (filesystem, network, identity).

### Same pattern for `process.argv`

`process.argv` follows an identical pluggable model:

```swift
public protocol ArgvProvider: AnyObject {
    func argv() -> [String]
    func setArgv(_ value: [String])
}
```

Two backends:

| Backend | argv source |
|---|---|
| `StaticArgvProvider` (default) | `[String]` set at init time |
| `ShellArgvProvider` | `[interpreter, script, ...shell.positionalParameters]` |

`process.argv` is a **regular JS Array** (not a Proxy) — `for-of`,
`spread`, `slice`, `Array.isArray` all work normally, mutations
on the JS reference are local. Embedders that need to update it
between `run` calls can call `JSRuntime.refreshArgv()` to re-snap
from the provider — useful when bash code has just modified
`shell.positionalParameters` and the next JS script needs to see
it.

This means a bash script's `$1, $2, $3` and a JS script's
`process.argv.slice(2)` map to **the same Swift array** when both
share a `Shell`:

```swift
let shell = Shell()
shell.positionalParameters = ["red", "green", "blue"]

let js = JSRuntime(
    argvProvider: ShellArgvProvider(shell),
    envProvider: ShellEnvProvider(shell)
)
js.run(\#"console.log(process.argv.slice(2));"\#)
//  → ["red","green","blue"]

try await shell.run(#"echo "$1 $2 $3""#)
//  → red green blue
```

### Bash↔JS shared environment

The `ShellEnvProvider` is the genuinely novel angle. A single
`Shell` instance can be handed to:

1. A bash script run via `Shell.run`
2. A JS script run via `JSRuntime`

…and they **share state through `Shell.environment`** without
either touching the host process. A bash command sets a variable;
JS reads it. JS rewrites it; bash sees the new value. Neither
escapes to `setenv`.

```swift
let shell = Shell()
shell.registerStandardCommands()

// 1. Bash sets a value.
try await shell.run("MY_TOKEN='from bash'")

// 2. JS reads it via ShellEnvProvider.
let js = JSRuntime(envProvider: ShellEnvProvider(shell))
js.run("""
console.log(process.env.MY_TOKEN);   // → "from bash"
process.env.MY_TOKEN = 'rewritten';
process.env.JS_GIFT = 'hello';
""")

// 3. Bash sees the JS mutations.
try await shell.run("echo $MY_TOKEN; echo $JS_GIFT")
// → rewritten
// → hello

// 4. Host process env is untouched.
ProcessInfo.processInfo.environment["JS_GIFT"]   // → nil
```

This is what node/bun/deno can't do: an in-process JS-and-bash
hybrid where the two scripts trade context through a virtualised
environment that lives entirely inside one Swift process. Useful
for: agentic systems where the LLM emits both bash and JS that
need to coordinate; iOS apps that can't fork; sandboxed plugins.

### child_process novelty

When a JS script does:

```javascript
const { execSync } = require('node:child_process');
execSync('printf "alpha\\nbeta\\ngamma\\n" | grep a | wc -l');
//   →  3
```

…all three of `printf`, `grep`, and `wc` run **inside the same
process** as the JavaScript. There is no `fork`, no `exec`, no
`/bin/sh`. SwiftBash's `Shell` parses the bash, registers the
standard commands, runs the pipeline as `AsyncStream<Data>`
between Swift `Command` types, and hands the captured stdout back
to JS. This is the angle node and bun can't match: a
sandboxable JS-and-bash hybrid that doesn't touch the OS process
table.

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
