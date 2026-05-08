# Agent instructions

A pure-Swift, sandboxed bash interpreter for embedding in Mac / iOS
apps. No `Process`, no `fork`, no `exec` — every command is a Swift
type, every byte streams through `AsyncStream<Data>`, every host
axis (FS / network / processes / identity) is virtualised.

Read [README.md](README.md) for the user pitch, then
[Docs/InterpreterArchitecture.md](Docs/InterpreterArchitecture.md)
for how the pieces fit together.

## Commands

- `swift build` — compile.
- `swift test --no-parallel` — full suite. **Always run before
  committing.** Currently ~1758 tests; failures from your change
  are the first signal something's off.
- `swift test --no-parallel --filter <name>` — single suite.
- `swift run swift-bash exec [--sandbox PATH] /dev/stdin <<<'…'`
  — fastest way to verify behaviour end-to-end during development.
- `swift-bash exec ./script.swift` — runs a Swift script through
  the in-process SwiftScript interpreter (registered by default).
  See [Docs/SwiftScript.md](Docs/SwiftScript.md).

## Where things live

```
Sources/BashSyntax/          Parser + tokenizer + AST. No interpreter deps.
Sources/BashInterpreter/
  API/                       Shell, Environment, Command, FileSystem, BinCatalog
  Builtins/                  cd, echo, export, declare, source, …
  Execution/                 Shell+Run, Shell+Pipeline, Shell+ControlFlow, …
  FileSystems/               Real, InMemory, SandboxedOverlay, VirtualBin
  Network/                   curl plumbing + URL allow-list
  Arithmetic/                ((…)) lexer + Pratt parser + evaluator
Sources/BashCommandKit/
  API/                       ParsableBashCommand bridge
  Commands/                  ls, cat, grep, sed, awk, find, jq, curl, …
Sources/swift-bash/          CLI (`exec`, `parse`)
Tests/                       One suite per source module
Docs/                        Architecture, sandboxing, networking, etc.
```

One declaration per file. `Type+Concern.swift` extensions for
splitting big types — `Shell` lives in `API/Shell.swift` plus ~15
`Shell+*.swift` extension files.

## Conventions to follow

- **Reach shell state via `Shell.current`.** Don't add `shell:`
  parameters to functions. `Shell.current` is a `@TaskLocal`,
  propagated automatically across pipelines, subshells, and child
  Tasks. Adding a parameter to thread "the current shell" is
  almost always wrong.
- **New shell-scoped option? Add it to `Shell.copy()`.** That's
  the single source of truth for what propagates into subshells
  and pipeline stages. Forgetting to add a field there means it
  silently doesn't inherit, which is a real footgun.
- **New command? Decide built-in vs kit.**
  - Pure shell semantics (manipulates env, control flow, registry):
    `BashInterpreter/Builtins/`, conform to `Command`.
  - System-style tool (operates on files, text, network):
    `BashCommandKit/Commands/`, conform to `ParsableBashCommand`,
    register in `Shell+StandardCommands.swift`.
- **File-shadowed commands need a `BinCatalog` entry.** Update
  `Sources/BashInterpreter/API/BinCatalog.swift` so the command
  appears under `/bin/<name>` or `/usr/bin/<name>` and `which`/
  `type` resolve correctly.
- **Long-running loops must call `try Task.checkCancellation()`
  each iteration.** `kill PID` against background jobs depends on
  cooperative cancellation. Loops that don't check are uninterruptible.
- **Non-local exits use thrown errors, not return-value flags.**
  Existing patterns: `ShellExit`, `ReturnSignal`,
  `LoopControlSignal`. Don't invent `enum Result { case ok, exit,
  returned }`-style returns.
- **File system writes go through `Shell.current.fileSystem`.**
  Never `FileManager.default.createFile(...)` from a command.
- **All paths to the FS are absolute.** Convert via
  `Shell.current.resolvePath(_:)` first. Relative paths reaching
  the FS layer are a bug.
- **Identity-revealing commands defer to `Shell.current.hostInfo`.**
  Never call `getuid()`, `gethostname()`, `uname()`, etc. directly
  — that leaks the real machine even in sandbox mode.

## Test discipline

- **Add a test in the same commit as the behaviour change.** The
  full suite is fast (~5s); leaving regressions invisible until
  later is more expensive than writing the test now.
- **Suite-per-source-file convention.** A new `FooCommand.swift`
  ships with `FooCommandTests.swift` next to the related ones.
- **Use `CapturingShell` for stdio assertions.** It wires fresh
  in-memory `OutputSink`s to a `Shell` and exposes `cap.stdout` /
  `cap.stderr` strings.
- **Assert full output rather than `.contains(...)` where possible.**
  Substring assertions hide whitespace bugs and ordering issues
  that exact-string assertions catch.
- **Sandbox tests use `SandboxedOverlayFileSystem`** with a real
  temp dir as root and `mountPoint: "/batch"`. Clean up the temp
  dir in `defer`.
- **Never re-test the parser from interpreter tests.** Parser
  behaviour belongs in `BashSyntax` tests; interpreter tests
  exercise execution against pre-parsed shapes.

## Things to avoid

- **Don't call `Process` / `fork` / `exec` / `posix_spawn`.** The
  interpreter is in-process by design. If you need parallelism,
  use `Task` / `TaskGroup` and route I/O through `OutputSink` /
  `InputSource`.
- **Don't read `ProcessInfo.processInfo.environment` from
  commands.** That's the host process's env — bypasses
  `Shell.current.environment` entirely. The CLI does this *once*
  in `Environment.current()` for non-sandbox mode.
- **Don't add new defaults that depend on the host.** Defaults
  must be safe for sandbox mode. If a command needs the real
  hostname / uid / cwd, read it from `hostInfo` / `environment`
  — both are sandbox-defaulted.
- **Don't `await` blocking I/O on a Task without
  `Task.checkCancellation` somewhere in the loop.** Pipelines
  cancel upstream when downstream finishes; commands that ignore
  cancellation hold up the entire pipeline.
- **Don't write `// TODO` without a follow-up.** Either spawn a
  task via `mcp__ccd_session__spawn_task` or fix it inline.

## Architectural guardrails

These are the four invariants the sandbox model rests on. Don't
break them; if you must, document why in the commit message:

1. **Filesystem confinement.** Every path resolves through a
   `FileSystem` protocol. Never assume a real disk is reachable.
2. **Network deny-by-default.** `Shell.networkConfig == nil`
   means deny-all. Don't add network access without a config check.
3. **Virtual processes.** `&` / `wait` / `kill` / `ps` operate on
   `Shell.processTable`. Never expose host PIDs.
4. **Synthetic identity.** `whoami` / `hostname` / `id` / `$USER`
   read from `Shell.hostInfo`. Default is `.synthetic`. Never
   leak real values unless `hostInfo == .real()`.

## Documentation

When changing public API surface, update the relevant `Docs/*.md`
file:

- New built-in command → mention in
  [Docs/BashCommandKit.md](Docs/BashCommandKit.md) (kit) or
  [Docs/BashInterpreter.md](Docs/BashInterpreter.md) (built-in).
- New sandbox layer → [Docs/Sandboxing.md](Docs/Sandboxing.md).
- New /bin or /usr/bin entry → already automatic via `BinCatalog`,
  but mention in [Docs/VirtualBin.md](Docs/VirtualBin.md) if
  semantics changed.
- New CLI flag → [Docs/CLI.md](Docs/CLI.md).
- Architectural change → [Docs/InterpreterArchitecture.md](Docs/InterpreterArchitecture.md).
- New script-shebang interpreter → mention in
  [Docs/BashInterpreter.md](Docs/BashInterpreter.md) (the
  "Script-shebang interpreters" section). The SwiftScript bridge
  has its own page at [Docs/SwiftScript.md](Docs/SwiftScript.md).

## Commits

- Subject line ≤ 70 chars, lowercase prefix tagging the area
  (`sandbox:`, `arithmetic:`, `bash:`, `cwd:`, `docs:`, `env:`).
- Body explains *why*, not just *what*. The diff shows what.
- End with `Co-Authored-By: Claude …` when the agent contributed.
- One logical change per commit. Refactors that only move code
  ship separately from behaviour changes.
- Note the test count delta in the body when it changed
  (`Suite: 1780 → 1784 tests`).

## When stuck

- Real bash semantics are the spec. If unclear, run
  `/bin/bash -c '…'` (macOS ships 3.2; `brew install bash` for 5.x)
  and compare. Diverge from bash only with a documented reason.
- The closest reference implementation is just-bash
  (TypeScript) at `/Users/oliver/Developer/Others/just-bash`.
  It's solving the same problem; check its conventions when our
  decision feels arbitrary.
