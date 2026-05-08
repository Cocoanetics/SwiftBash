# BashInterpreter

The execution layer that walks a `BashSyntax` AST and runs it. Everything
runs in-process — no `Process`, no `fork`, no `exec`. So scripts work on
iOS, in App Sandbox, in Swift Playgrounds, anywhere a Swift binary can run.

```swift
import BashInterpreter

let shell = Shell()
shell.environment["USER"] = "alice"
try await shell.run("echo hello $USER")        // → hello alice
try await shell.run("false || echo fallback")  // → fallback
try await shell.run("for i in 1 2 3; do echo n=$i; done")
```

## What works

The interpreter implements a substantial subset of bash 4.x:

- **Lists** — `;`, `\n`, `&&`, `||` (short-circuit), `&` (background, see
  the [process model](#process-model)).
- **Pipelines** — `|` and `|&`. Stages run concurrently in their own
  Tasks; `tail -f log | grep ERROR | head -n 5` exits as soon as `head`
  has its 5 matches, propagating cancellation upstream.
- **Variable expansion** — `$NAME`, `${NAME}`, `$?`, `$$`, `$#`, `$@`,
  `$*`, `$1`-`$9`, concatenation, double-quote vs single-quote semantics.
- **Parameter operators** — full `${…}` set: `${#var}`, `${var-default}`,
  `${var:-default}`, `${var=default}`, `${var:=default}`, `${var?msg}`,
  `${var:?msg}`, `${var+alt}`, `${var:+alt}`, `${var#pat}`/`${var##pat}`,
  `${var%pat}`/`${var%%pat}`, `${var/pat/rep}`/`${var//pat/rep}`,
  `${var/#pat/rep}`/`${var/%pat/rep}`, `${var:offset:length}` (with
  negative-index support).
- **Command substitution** — `$(…)` and `` `…` `` execute in the current
  shell with stdout captured and trimmed.
- **Process substitution** — `<(cmd)` and `>(cmd)` via temp files in the
  configured filesystem.
- **Arithmetic** — full `((…))` / `$((…))`: 64-bit signed math with all
  bash operators, base literals (`0x`, `0`, `N#…`), short-circuit, exit
  status follows bash's inverted convention.
- **Control flow** — `if/elif/else/fi`, `while`, `until`, `for VAR in …`,
  C-style `for ((…;…;…))`, `case … esac` with glob patterns and the
  `;;` / `;&` / `;;&` terminators, `{ …; }` groups, `( … )` subshells,
  `break N` / `continue N`.
- **Arrays** — indexed (`a=(x y z)`, `${a[1]}`, `${a[@]}`, `${#a[@]}`)
  and associative (`declare -A m; m[key]=value`).
- **Functions** — `name() { … }` and `function name { … }`, with
  `local`, `return`, recursion.
- **`set -e` / `set -u` / `set -o pipefail`**, plus `shopt` for nullglob,
  globstar, extglob, nocaseglob, dotglob, nocasematch.
- **Traps** — `EXIT`, `ERR`, `DEBUG`, `RETURN` plus stored handlers for
  real signal names.
- **Tilde expansion**, **brace expansion** (`{a,b,c}`, `{01..05}`,
  `{a..z..2}`), **globs** (`*`, `?`, `[…]`, `[!…]`), **heredocs**
  (`<<`, `<<-`, `<<<`).
- **Built-in commands** — `cd`, `pwd`, `export`, `unset`, `exit`, `:`,
  `true`, `false`, `read`, `printf`, `echo`, `eval`, `source`, `.`,
  `let`, `local`, `return`, `set`, `shift`, `shopt`, `declare`,
  `typeset`, `mapfile`, `readarray`, `getopts`, `trap`, `wait`, `test`,
  `[`, `break`, `continue`.

For execution-style commands (`ls`, `cat`, `grep`, `sed`, `find`, …),
register them via [`BashCommandKit`](BashCommandKit.md).

## Streams

`stdin`, `stdout`, and `stderr` are byte-oriented async channels —
`InputSource` reads, `OutputSink` writes. Either end can be redirected,
streamed, or captured.

```swift
// 1. Drain everything into strings.
let result = try await shell.runCapturing("echo hi")
print(result.stdout)       // "hi\n"
print(result.exitStatus)   // ExitStatus(0)

// 2. Live: iterate the stream while the script runs.
let sink = OutputSink()
shell.stdout = sink
Task {
    for await line in sink.lines {
        updateUI(with: line)   // renders per line, not per batch
    }
}
try await shell.run("tail-f-like-script")
sink.finish()

// 3. Default: forward to the host process's fd 1 / fd 2.
```

`OutputSink` exposes both `.lines` (text) and `.bytes` (binary-safe)
plus an `onWrite` synchronous hook for accumulating callers.

## The `Shell` is a `@TaskLocal`

`Shell.current` is the active shell during dispatch — every command,
expansion, trap, and pipeline stage reads it. Subshells `( … )` and
pipeline stages run inside `Shell.copy()` snapshots. Subshell mutations
don't leak back to the parent; reference-typed sinks like `stdout` are
shared so output flows to the same destination.

This means options (`networkConfig`, `fileSystem`, `commands`,
`shoptOptions`, `errexit`, …) propagate through pipelines and subshells
**automatically** — there's nothing to plumb manually.

## Filesystems

The interpreter reads and writes through a `FileSystem` protocol —
swappable, per-shell. Three implementations ship:

- **`RealFileSystem`** — backed by `FileManager`, full real-disk access.
  Use on a trusted workstation.
- **`InMemoryFileSystem`** — pure in-memory tree. Useful for tests, iOS
  previews, or scripts that should leave nothing behind.
- **`SandboxedOverlayFileSystem`** — copy-on-write overlay confining a
  script to a single host directory. Reads fall through to the host;
  writes are captured in memory. The sandbox guards against symlink
  escape, TOCTOU, and host-path leaks in error messages.

Whatever you pass to `Shell(fileSystem:)` is automatically wrapped in
`VirtualBinFileSystem` so `/bin`, `/usr/bin`, and `/usr/local/bin`
always reflect the shell's command registry — `ls /bin` shows the set
of commands the script can actually invoke. See
[VirtualBin.md](VirtualBin.md) for details.

## Sandbox-by-default identity

Four virtualisation axes ensure a script can't fingerprint or reach
out to the host unless the embedder explicitly opts in:

1. **Filesystem** — every path goes through a `FileSystem`; default
   for `--sandbox` is `SandboxedOverlayFileSystem`.
2. **Network** — `curl` defaults to deny-all. To enable, set
   `Shell.networkConfig` with an explicit URL allow-list.
3. **Processes** — `&`, `wait`, `ps`, `kill`, `pgrep`, `pkill`
   operate on a virtual process table — no host PIDs, no `fork`.
4. **Identity** — `whoami`, `hostname`, `id`, `uname`, `$USER`,
   `$HOSTNAME`, `df`, file ownership all read from `Shell.hostInfo`
   which defaults to a synthetic `("user", "sandbox", uid 1000, gid 1000)`.
   Embedders can opt in to the real identity via `HostInfo.real()`.

See [Sandboxing.md](Sandboxing.md) for the complete model.

## Process model

`&` runs the right-hand command on a Swift `Task`, registers it in
`Shell.processTable`, and returns its virtual PID. `wait`, `kill`,
`pgrep`, `pkill`, and `ps` operate against that table. There's no
host-process plumbing; cancellation is cooperative (Swift has no
`SIGKILL` equivalent for in-process Tasks). Long-running commands
honour `Task.checkCancellation()` at each loop iteration so
`kill PID` ends them within a millisecond.

`$$` returns `Shell.virtualPID` (defaults to 1, configurable). `$!`
returns the most recently spawned background PID.

## Bash 4.x semantics, not 3.2

SwiftBash targets bash 4.x semantics (case conversion, `${arr[-1]}`,
`declare -A`, `mapfile`, `globstar`, padded `{01..05}`, …) — not the
bash 3.2 (2007) that ships as `/bin/bash` on macOS. When a script
behaves differently between SwiftBash and macOS-shipped `bash`,
install a current bash (`brew install bash`) and SwiftBash almost
always agrees with it.

See [BashVersionConformance.md](BashVersionConformance.md) for the
full catalogue of features where this matters, with side-by-side
examples.

## Custom commands

Every command — built-in or user-added — conforms to the `Command`
protocol (`name` + `run(argv:)`). Register with `Shell.register`:

```swift
struct SumCommand: Command {
    let name = "sum"
    func run(_ argv: [String]) async throws -> ExitStatus {
        let total = argv.dropFirst().compactMap(Int.init).reduce(0, +)
        Shell.current.stdout("\(total)\n")
        return .success
    }
}
shell.register(SumCommand())

// Closure-based:
shell.register(name: "greet") { argv in
    let who = argv.dropFirst().first ?? "world"
    Shell.current.stdout("hello \(who)\n")
    return .success
}

try await shell.run("sum 1 2 3 4")      // → 10
try await shell.run("greet alice")      // → hello alice

shell.unregister("sum")                 // remove
```

For typed argument parsing via Swift Argument Parser, depend on
[`BashCommandKit`](BashCommandKit.md) and conform to
`ParsableBashCommand`.

## Script-shebang interpreters

`./hello.swift` doesn't go through `commands[…]` — it's a path, not
a command name. SwiftBash treats path-shaped tokens as candidate
external scripts: it reads the file, parses the `#!`-shebang, and
dispatches to a registered `ScriptInterpreter`.

```swift
shell.registerScriptInterpreter(name: "swift-script") { ctx in
    // ctx.source has the leading "#!…" line stripped (newline kept,
    // so line numbers in diagnostics still match the original file).
    try await SwiftScriptInterpreter().eval(ctx.source,
                                            fileName: ctx.scriptPath)
    return .success
}
try await shell.run("/abs/path/to/hello.swift one two")
// → ScriptInterpreterContext.argv = [scriptPath, "one", "two"]
```

`#!/usr/bin/env <name>` and `#!/usr/bin/env -S <name> --flag`
shebangs are handled — the dispatcher walks past `env`'s flags and
`KEY=value` pairs to resolve the real interpreter. Diagnostics
follow bash conventions: missing file → 127, directory → 126,
unrecognised shebang → falls through to `command not found`. The
script runs in a fresh `Shell.copy()` so `$0` and positional
parameters stay scoped.

The official SwiftScript binding ships as the
[`BashSwiftScript`](SwiftScript.md) library target. The
`swift-bash exec` CLI auto-registers it; embedders opt in with
`shell.registerSwiftScript()`.

## Limitations

- **No subprocess execution.** Every command runs in-process via the
  registry. Job control (`bg`/`fg`/`jobs`) is intentionally out of
  scope; `&` and `wait` are the supported parallelism primitives.
- **Process substitution uses temp files**, not real `/dev/fd/N`.
  Visible behaviour matches bash; very-large-stream throughput differs.
