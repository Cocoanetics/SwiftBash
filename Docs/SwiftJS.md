# SwiftJS

A Node-style JavaScript executor built on Apple's
JavaScriptCore. Drops a `swift-js` binary into your terminal
that runs `#!/usr/bin/env node` shebang scripts unchanged, and
ships an embeddable `SwiftJSCore` Swift library for putting a
JS runtime inside iOS / macOS apps where `fork` is unavailable.

```bash
$ swift-js install ~/.local/bin
$ cat hello.js
#!/usr/bin/env node
const fs = require('node:fs');
console.log('lines:', fs.readFileSync('/etc/hosts', 'utf-8').split('\n').length);
$ chmod +x hello.js && ./hello.js
lines: 10
```

The runtime is ~1700 lines of Swift across 8 files, builds to
an 8 MB release binary (vs 57 MB for bun, 105 MB for node), and
covers the surface real-world Node CLIs touch: `console`,
`process` (incl. `argv`/`env`/`stdout`/`exitCode`/`pid`),
`Buffer`, `URL`, `TextEncoder`/`TextDecoder`, `fetch`, timers,
`Promise`, `AbortController`, `WebAssembly`, `node:fs` (sync +
promises), `node:path`, `node:os`, `node:util`, `node:url`,
`node:crypto`, `node:zlib`, `node:assert`, `node:events`,
`node:querystring`, `node:perf_hooks`, `node:child_process`,
plus `require()` and ES `import`/`export`. Cold-start is faster
than `node`. Cross-runtime parity is verified script-by-script
against `node` and `bun`.

The novel SwiftBash-specific knobs:
- `child_process` runs through SwiftBash's in-process
  `BashInterpreter` by default (no fork, sandboxable). The
  `swift-js` CLI opts into `/bin/sh` so external binaries work
  the way they do under node.
- `process.env` and `process.argv` are pluggable per
  ``EnvProvider`` / ``ArgvProvider``. `--sandbox-env` exposes
  only a synthetic minimal set; `ShellEnvProvider` lets a JS
  script and a bash script trade state through a single
  in-process `Shell.environment` without ever touching the host
  process env.

For non-Apple platforms (Linux / Windows / Android), every JSC-
touching `.swift` file is wrapped in `#if canImport(JavaScriptCore)`,
so the package builds everywhere — non-Apple builds register an
empty `SwiftJSCore` module and a stub `swift-js` that exits with
`EX_CONFIG`. The static-archive C-API target (`CJavaScriptCore`)
that links Bun's prebuilt JSC into `swift-jsc-smoke` on those
platforms is in place; porting the full SwiftJSCore runtime over
to it is the remaining work. See [§ Cross-platform: JSC everywhere
via Bun's prebuilt archive](#cross-platform-jsc-everywhere-via-buns-prebuilt-archive).

## Layout

```
Sources/SwiftJSCore/                       # the runtime library
│   ├── JSRuntime.swift                # context, exception handler, runloop drain
│   ├── Globals.swift                  # console, process, Buffer,
│   │                                  # TextEncoder/Decoder, atob/btoa,
│   │                                  # URL, queueMicrotask, performance,
│   │                                  # AbortController, structuredClone
│   ├── Modules.swift                  # require() + builtin modules
│   │                                  # (fs, path, os, util, url, assert,
│   │                                  # events, querystring, perf_hooks)
│   │                                  # + CommonJS local-file loader
│   ├── Timers.swift                   # setTimeout, setInterval,
│   │                                  # clearTimeout, clearInterval,
│   │                                  # setImmediate (DispatchSourceTimer)
│   ├── Network.swift                  # fetch, Headers, Response (URLSession,
│   │                                  # AbortSignal-aware)
│   ├── Crypto.swift                   # createHash, createHmac,
│   │                                  # randomBytes, randomUUID,
│   │                                  # timingSafeEqual (CryptoKit)
│   ├── Zlib.swift                     # node:zlib (gzip/gunzip/deflate/inflate)
│   ├── ChildProcess.swift             # execSync/spawnSync/exec, static
│   │                                  # backend (in-process or /bin/sh)
│   ├── ESMRewriter.swift              # static `import`/`export`
│   │                                  # → CommonJS preprocessor
│   └── EnvProvider.swift              # pluggable backing for
│                                      # process.env / process.argv
├── Sources/swift-js/                   # the CLI binary
│   ├── main.swift                     # multi-call binary
│   │                                  # (node/bun aliases), -e/-p/--print,
│   │                                  # --sandbox-env, install subcommand
│   └── Resources/swift-js.entitlements # JIT entitlement
├── scripts/codesign-jit.sh             # post-build sign helper
├── Tests/SwiftJSCoreTests/             # 78 tests, all passing
└── Examples/SwiftJS/
    ├── hello.js                            # shebang demo
    ├── portable.js                         # runs identically on swift-js/node/bun
    ├── async-stress.js                     # nested timers + microtasks
    ├── everything.js                       # cross-runtime parity harness
    ├── bench.js                            # cross-runtime benchmark
    ├── sandbox-env.js                       # demo for --sandbox-env
    ├── shell-shared-env.swift               # bash↔JS shared env doc
    ├── parallel-exec.js                     # concurrent child_process via Tasks
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
| `console.*` (incl. `time/timeEnd/count/group/assert/dir/table`) | Swift sinks + JS extension |
| `process.argv`, `env`, `cwd`, `chdir`, `exit`, `exitCode`, `on('exit')`, `stdout/stderr.write`, `hrtime`, `platform`, `arch`, `version` | Swift bridges + Proxy-backed env/argv |
| `setTimeout`/`setInterval`/`setImmediate`/`queueMicrotask` | DispatchSourceTimer + microtask queue |
| `performance.now()`, `performance.timeOrigin`, `node:perf_hooks` | DispatchTime |
| `Buffer`, `TextEncoder`/`Decoder`, `atob`, `btoa`, `structuredClone` | UTF-8/base64/hex bridged from Swift, classes built in JS on top |
| `URL`, `URLSearchParams`-equivalent fields | `URLComponents`-backed parser |
| `AbortController`, `AbortSignal`, `AbortError` | pure JS, plumbed into `fetch` via URLSessionDataTask.cancel |
| `WebAssembly` (sync `Module`/`Instance`) | **free from JSC** |
| `node:fs` (sync + promises wrapper) | Foundation `FileManager`/`Data` |
| `node:path`, `node:os`, `node:util`, `node:url` | Pure JS where possible, Swift for `os.*` |
| `node:crypto` (createHash/createHmac/randomBytes/randomUUID/timingSafeEqual) | CryptoKit |
| `node:zlib` (gzipSync/gunzipSync/deflateSync/inflateSync/deflateRawSync/inflateRawSync) | host zlib via `CZlib` |
| `node:assert` (equal/strictEqual/deepEqual/throws/match/…) | pure JS |
| `node:events` (EventEmitter) | pure JS |
| `node:querystring` | pure JS |
| `node:child_process` (`execSync`, `spawnSync`, async `exec`) | **SwiftBash `BashInterpreter` in-process** by default; Foundation `Process` as opt-in fallback. Concurrent via `Task.detached`. |
| `fetch`, `Response`, `Headers` (with abort signal) | URLSession |
| `require('./local')`, `require('node:foo')` | CommonJS wrapper, module cache, circular guard |
| ESM `import`/`export` (incl. `import.meta.url`, dynamic `import()`) | static rewriter to CommonJS |

| Still missing | Cost to add |
|---|---|
| `node:stream` (Readable/Writable/Transform) | medium |
| Cipher/Decipher / pbkdf2 / scrypt in `crypto` | small (CryptoKit) |
| WebAssembly **async** path (`WebAssembly.instantiate`) | small — needs runloop integration |
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

## Multi-call binary: shadowing `node` and `bun`

The most useful shebang is `#!/usr/bin/env node` — that's what every
existing JS shell-script is already using, and we don't want to ask
users to rewrite shebangs to point at a tool they've never heard of.

The CLI is a multi-call binary (busybox style). `argv[0]`'s basename
selects the personality:

| Invoked as | Behaviour |
|---|---|
| `node` / `nodejs` | `node script.js [args]`, `node -e expr`, `node -p expr`, `node -v`, `--version` returns `v22.0.0-swiftjs` |
| `bun` | `bun script.js`, `bun -e`, `bun --print`, `bun --version` (returns `1.3.0-swiftjs`) |
| `swift-js` | canonical name, plus `--sandbox-env` and `install` subcommands |

A single `swift-js install [prefix]` lays down three symlinks:

```
~/.local/bin/swift-js  →  /path/to/swift-js
~/.local/bin/node      →  /path/to/swift-js
~/.local/bin/bun       →  /path/to/swift-js
```

Put `~/.local/bin` first on `PATH` and any existing `.js` file
that starts with `#!/usr/bin/env node` finds *our* binary, with
no edits to the script.

```bash
$ swift-js install ~/.local/bin
$ which node
~/.local/bin/node
$ node --version
v22.0.0-swiftjs

$ cat hello.js
#!/usr/bin/env node
console.log("USER =", process.env.USER, "argv =", process.argv.slice(2));

$ ./hello.js Alice Bob
USER = oliver argv = [ 'Alice', 'Bob' ]
```

Identical output between the real `node` and our `swift-js`-as-`node`
on a typical Node CLI script (verified with `diff` on a `wc -l`
implementation reading multiple files). Existing scripts work
unchanged.

This is the answer to the obvious "but why would I write
`#!/usr/bin/env swift-js` when nobody else has heard of it?"
question — they wouldn't. They'd write `#!/usr/bin/env node`
like normal, and the binary takes over node's identity in
whatever PATH order they prefer.

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

### child_process: in-process by default, host-shell when needed

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

The backend is a **static choice made at runtime construction**,
not a per-command decision:

```swift
public enum ChildShell { case inProcess, hostShell }

JSRuntime(... childShell: .inProcess)   // default for embedders
JSRuntime(... childShell: .hostShell)   // what the swift-js CLI uses
```

| Mode | What `child_process` does | Use case |
|---|---|---|
| `.inProcess` (default) | every call goes through `BashInterpreter`. Unknown commands fail with exit 127 the way bash itself does. **No fork, no exec.** | embedded in iOS / macOS app, Swift Playgrounds, sandboxed plugin host — anywhere `fork(2)` is unavailable or undesirable. |
| `.hostShell` | every call forks `/bin/sh`. Any binary on PATH works (`git`, `python3`, `npm`, custom binaries). Matches node `child_process` semantics. | the `swift-js` CLI binary, since it's already running as a normal Unix process. |

The `swift-js` executable explicitly opts into `.hostShell` so a
script with `#!/usr/bin/env node` calling `git status` behaves
exactly the way it would under real node. An embedder dropping
`JSRuntime` into an iOS app gets `.inProcess` by default and
inherits SwiftBash's full sandboxability — the JS can run
`echo | grep | wc -l` but cannot reach for `git` (which isn't
in the catalog and can't be reached without `fork`).

No string parsing, no catalog probe, no per-call branching.
Fewer than ten lines of dispatch:

```swift
private func pickBackendAndRun(command: String, args: [String]?) -> ChildResult {
    switch childShell {
    case .inProcess: return runBashInterpreter(command: command)
    case .hostShell: return runHostShell(command: command, args: args)
    }
}
```

### Concurrent subprocesses via Swift Tasks

Alongside `execSync`, an async `exec(cmd, opts) → Promise` ships
that dispatches each call onto its own `Task.detached`. Multiple
calls run **concurrently inside one OS process** — no fork, just
Swift Tasks scheduled across the cooperative runtime.

```javascript
const cp = require('node:child_process');

await Promise.all([
  cp.exec('sleep 0.1; printf 1'),
  cp.exec('sleep 0.1; printf 2'),
  cp.exec('sleep 0.1; printf 3'),
]);
//  → ~110 ms wall clock (not 300 ms)
```

Verified on the demo script:

| | wall clock |
|---|---:|
| sequential `await` x3 | 318 ms |
| `Promise.all` x3 | 107 ms |
| `Promise.all` x20 | 108 ms |
| `Promise.all` x20 of `echo` (no sleep) | **2 ms** |

The 20-`echo`-in-2 ms result is the unique angle: 20 bash
pipelines running concurrently with zero process spawning.
node and bun would each fork+exec a subshell per call —
~5–10 ms each at minimum. SwiftJS runs them as Swift Tasks
calling registered `Command` types directly, so the limit is
just task-scheduling overhead.

Errors reject with the original `code`, `stdout`, and `stderr`
attached to the Error so callers can recover cleanly:

```javascript
try {
  await cp.exec('exit 7');
} catch (e) {
  console.log(e.code);     // → 7
  console.log(e.stdout);   // → whatever was printed before exit
}
```

## Cross-platform: JSC everywhere via Bun's prebuilt archive

Researched current state (today: 2026-05-09):

### How Bun does it

[Bun](https://github.com/oven-sh/bun) ships a Node-shaped JS
runtime on macOS, Linux x64/aarch64 (glibc + musl), Windows
x64/arm64, and Android — and it links the *same* JavaScriptCore
on every one of them. They maintain a WebKit fork at
[oven-sh/WebKit](https://github.com/oven-sh/WebKit) that strips
out WebCore, WebKit2, the GTK glue, and everything else outside
`Source/JavaScriptCore` + `Source/WTF` + `Source/bmalloc` + ICU.
Each autobuild publishes per-triple `bun-webkit-<os>-<arch>.tar.gz`
release assets containing `lib/libJavaScriptCore.a` (or `.lib`
on Windows), the WTF/bmalloc/ICU statics, and the full Apple-
compatible C API headers (`JSContextRef`, `JSValueRef`,
`JSStringRef`, `JSObjectRef`, `JavaScript.h`).

The C API headers are byte-for-byte the same as Apple's. Swift
code that only uses the C API recompiles unchanged against the
Bun headers — that's exactly what JSC's stable C ABI is for.

### Why this beats `libjavascriptcoregtk-4.1`

The earlier note on this page about "WebKitGTK is 10–20 MB plus
LGPL packaging burden" measured the wrong artifact. WebKitGTK
drags in the WebKit2 process model, GLib mainloop, GObject
bindings, and DBus. Bun's build is JSC-only — same engine,
different glue, much smaller link surface, no system-package
dependency. Both are LGPL; the obligation is the same in either
case (static-link + provide a relink path), and dynamic-linking
the GTK package buys nothing useful in exchange for the heavier
runtime footprint.

### Why this beats QuickJS-NG

The earlier recommendation on this page was QuickJS-NG. It's
still a fine engine — small, MIT, easy to vendor — but it costs
a full engine-abstraction layer (every JS-facing API split into
two backends) and carries different ES2023+ semantics from JSC.
Reusing Bun's JSC keeps a single engine across every platform,
preserves the existing Apple runtime line-for-line, and gets us
JSC's JIT performance for free.

### Engines deliberately rejected

- **Hermes** (Meta): no standalone shipping story, RN-flavoured.
- **Duktape**: only ES5.1; modern destructuring/`const`/template
  literals don't work — disqualifies it for "write your shell
  scripts in modern JS".
- **V8 / libnode**: ~50 MB, build-system pain, overkill.
- **MuJS**: ES5, same issue as Duktape.
- **Pure-Swift JS interpreter**: nothing production-grade exists,
  and writing one is a multi-year project. Not viable.

## Architecture

```
CJavaScriptCore (C umbrella module)
├── include/CJavaScriptCore.h ─ #include <JavaScriptCore/JavaScript.h>
├── module map               ── publishes the C API as a Swift module
├── header search path       ── Apple: framework | non-Apple: Vendor/bun-webkit/current/include
└── linker settings          ── Apple: autolink   | non-Apple: -L Vendor/bun-webkit/current/lib

SwiftJSCore (Apple-only today)
└── #if canImport(JavaScriptCore) — uses ObjC wrappers (JSContext, JSValue)

swift-jsc-smoke (every platform)
└── pure C API — the CI proof that JSC links and evaluates JS
```

A SwiftJSCore that compiles on non-Apple needs a Swift-side
`JSContext`/`JSValue` wrapper over the C API — Apple's framework
provides those classes, Bun's static archive does not. Estimated
~200–400 lines of bridging code, deferred to a follow-up.

## Status

| platform | JSC backend | swift-jsc-smoke | swift-js (full runtime) |
|---|---|---|---|
| macOS / iOS / tvOS / watchOS / visionOS | system framework | builds + runs | builds + runs |
| Linux glibc / musl x64 + arm64 | bun-webkit static `.a` | builds + runs | stub (`EX_CONFIG`) |
| Android (NDK, x64 + arm64) | bun-webkit static `.a` | builds + runs | stub (`EX_CONFIG`) |
| Windows MSVC x64 + arm64 | bun-webkit static `.lib` | **gated off, see below** | stub (`EX_CONFIG`) |

### Windows — pending CRT alignment

Bun's Windows `.lib` artifacts are built with MSVC's `/MT` (static
CRT) flag because their final binary statically links everything
including the CRT. Swift's runtime on Windows ships with `/MD`
(dynamic CRT). `lld-link` rejects the mix:

```
lld-link: error: /failifmismatch: mismatch detected for 'RuntimeLibrary'
>>> swiftrt.obj has value MD_DynamicRelease
>>> JavaScriptCore.lib(...) has value MT_StaticRelease
```

The mismatch is unsafe to override: heap allocations from one CRT
freed by the other corrupt memory (different malloc heaps,
different `FILE*` tables). Three viable resolutions, none
suitable for this PR:

1. Rebuild bun-webkit with `/MD` and host the artifact ourselves.
2. Build a Swift static-stdlib toolchain for Windows so the whole
   binary uses `/MT`.
3. Switch to a JSC build that ships both CRT variants (Bun's
   tarballs only publish `/MT` today).

Until then, `swift-jsc-smoke`'s dependency on `CJavaScriptCore` is
gated off Windows in `Package.swift`, and the binary's
`#if canImport(CJavaScriptCore)` falls through to a skip-message
stub. Tracked as a follow-up.

### Linux/Android — JSC teardown skipped

`JSGlobalContextRelease` deadlocks for ~62s then aborts (likely a
bmalloc heap-shutdown assert against an unfinished worker on
Bun's static archive). All four C-API calls during normal
execution succeed; only teardown trips. The smoke binary exits
directly via `exit(0)` after printing the result instead of
running `defer`-based cleanup; OS process exit reclaims the
memory anyway. A real long-lived runtime that creates/destroys
many contexts would need a proper fix here — the smoke binary
doesn't.

Outstanding: port SwiftJSCore from `JSContext`/`JSValue` to a
thin Swift wrapper over the C API so the full runtime compiles
on non-Apple. Tracked separately.

## How the build links bun-webkit

```
$ ./scripts/fetch-bun-webkit.sh        # one-time per WebKit version
fetch-bun-webkit: downloading bun-webkit-linux-amd64.tar.gz
                  from https://github.com/oven-sh/WebKit/releases/...
fetch-bun-webkit: extracted to Vendor/bun-webkit/linux-amd64-88b2f7a...
fetch-bun-webkit: Vendor/bun-webkit/current -> linux-amd64-88b2f7a...
fetch-bun-webkit: ready

$ swift build --product swift-jsc-smoke
Compiling CJavaScriptCore CJavaScriptCore.c
Compiling swift_jsc_smoke main.swift
Linking swift-jsc-smoke
$ .build/debug/swift-jsc-smoke
swift-jsc-smoke: 1 + 2 = 3  [bun-webkit static archive]
```

The fetcher pins a WebKit-fork commit SHA — bumping that constant
is how we pick up newer JSC. CI runs the fetcher on Linux,
Windows, and Android before `swift build`; on macOS it's a no-op
(the system framework is already on the search path).

LGPL compliance: Bun static-links and ships a relink path in
their LICENSE. SwiftBash mirrors that template — distribute
`libJavaScriptCore.a` from a known WebKit-fork commit, point
recipients at the relink instructions, ship a NOTICE alongside
the binary.

## Source-level platform gating (legacy)

Until the SwiftJSCore port to the JSC C API lands, the existing
runtime stays Apple-only at the source level. Every JSC-touching
`.swift` source file is wrapped in:

```swift
import Foundation
import JavaScriptCore

#if canImport(JavaScriptCore)

// ... runtime code ...

#endif
```

That includes `JSRuntime`, `Globals`, `Modules`, `Crypto`,
`Network`, `Timers`, `ChildProcess`, and `Zlib`. `ESMRewriter`
and `EnvProvider` are pure Foundation (the protocol is useful
on any platform) and stay unguarded.

The `swift-js` executable target also has a non-Apple branch
that prints a clear error and exits with `EX_CONFIG`:

```
$ swift-js --version       # on Linux today
swift-js: JavaScriptCore is not available on this platform.
          Apple platforms (macOS, iOS, tvOS, watchOS) are supported.
```

The test target's `JSRuntimeTests` is similarly guarded so
non-Apple CI runs just skip those tests instead of failing to
compile.

This will be revisited once the C-API wrapper lands — at that
point the runtime targets every platform `swift-jsc-smoke`
already supports.

## Status of this branch

`experiment/js-executor`, parallel to `main`. The package lives in
`` so it doesn't entangle the main `Package.swift`
— it builds independently with `swift build` from inside that
directory. Tests pass on macOS 26 / Swift 6.3.

If we don't go forward with this idea, the directory can be
deleted. If we do, the next steps would be the engine abstraction
described above and a `swift-js` target inside the main package
guarded by `#if canImport(JavaScriptCore)`.
