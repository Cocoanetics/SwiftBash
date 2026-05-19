# Interpreter architecture — lessons from SwiftBash

A field report on how SwiftBash is structured, what worked, and what
to keep / change when building a new interpreter (e.g. for Swift) on
top of the same scaffolding. Not a tutorial — assumes the reader has
written interpreters before.

---

## 1. Two packages: a syntax library and an interpreter on top

`BashSyntax` parses source into an AST and stops. It depends on
nothing but the standard library and contains no notion of a "shell"
or "command registry". `BashInterpreter` consumes that AST and
executes it. The split has paid off in three concrete ways:

- **Parser is reusable in isolation.** Linters, syntax highlighters,
  IDE plugins, and the `swift-bash parse` debug subcommand all
  depend on `BashSyntax` only — never paying the interpreter's
  weight or its concurrency requirements.
- **The AST is a stable contract.** Internal interpreter changes
  (new built-ins, new sandboxing layers, networking, the virtual
  process table) never required touching the AST.
- **Tests partition cleanly.** `BashSyntax` tests are pure functions
  over strings; `BashInterpreter` tests need a shell with stdio
  but never re-test parsing.

For a Swift interpreter: do the same. `SwiftSyntax` already exists
and is excellent. The interpreter package depends on it, never
implements its own parser. (More on this in §10.)

---

## 2. The AST shape: `struct + indirect enum`, value-typed, span-tagged

```swift
public struct Node: Hashable, Sendable {
    public let kind: Kind
    public let range: Range<Int>      // span in original source

    public indirect enum Kind: Hashable, Sendable {
        case list(parts: [Node])
        case command(parts: [Node])
        case pipeline(parts: [Node])
        case word(String, parts: [Node])
        case ifCommand(parts: [Node])
        case forCommand(parts: [Node])
        case function(name: Node, body: Node, parts: [Node])
        // …
    }
}
```

Three deliberate choices:

1. **One outer struct, every variant in one enum.** Not 30 protocol
   conformers, not class hierarchies. Pattern-matching the enum is
   the entire dispatch story. In Swift, this scales to ~30
   variants with no perceptible slowdown vs. open polymorphism.

2. **`Hashable` and `Sendable` everywhere.** Because the AST is a
   value tree, equality and hashing fall out for free, and we can
   pass nodes between Tasks (pipelines, subshells, async
   command implementations) without `@unchecked` escape hatches.

3. **`range: Range<Int>` on every node.** The span points back into
   the original source string. Three uses:
   - **Error messages** (`script.sh: line 42: command not found`).
   - **Word expansion**: instead of re-tokenising a word's parts
     into a re-assemblable structure, the interpreter walks the
     raw source bytes inside the word's range and splices in
     sub-node values where `sub.range.lowerBound` matches the
     cursor. Quoting and escapes are interpreted by the executor,
     not re-encoded by the parser.
   - **Function bodies** survive across `run()` boundaries. A
     function defined in one source string and called later (when
     `currentSource` is something else) still has its body's range
     pointing into the *original* source text — which we capture
     into `FunctionCommand.definitionSource` at definition time.

That third point is worth emphasising. The interpreter holds spans
into source text, not deep-copied AST data. This means the source
string is a real participant — captured by reference into anything
that needs it later. It's cheap (Swift `String` is a value type
with copy-on-write), but the discipline is real.

---

## 3. Function calling — the answer to the question

> "do you do function calling within the same file?"

In bash there are no separate files / modules / compilation units.
A script is one source string; functions are values bound into the
shell's runtime registry as that string is interpreted, top-to-
bottom. That makes the answer simple:

- A `name() { … }` definition produces a `Node` of kind
  `.function(name, body, parts)`.
- When the executor visits that node (`Shell+Run.swift:128`), it
  *evaluates the function as a side effect*: it creates a
  `FunctionCommand` value carrying the body AST and the source
  text, and inserts it into `Shell.commands[name]`.
- Subsequent simple-command dispatch looks up `argv[0]` in
  `commands`, finds the `FunctionCommand`, and calls its `run`.

```swift
// Shell+Run.swift, AST dispatch (extract):
case .function(let nameNode, let body, _):
    let name = try await expand(word: nameNode)
    commands[name] = FunctionCommand(
        name: name,
        body: body,
        definitionSource: currentSource)
    return .success
```

```swift
// FunctionCommand.swift (full):
struct FunctionCommand: Command {
    let name: String
    let body: Node
    let definitionSource: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        let savedParams = Shell.current.positionalParameters
        let savedSource = Shell.current.currentSource

        Shell.current.positionalParameters = Array(argv.dropFirst())
        Shell.current.currentSource = definitionSource
        Shell.current.functionCallDepth += 1
        Shell.current.localVarStack.append([])

        defer {
            if let frame = Shell.current.localVarStack.popLast() {
                for (name, prior) in frame.reversed() {
                    Shell.current.environment[name] = prior
                }
            }
            Shell.current.functionCallDepth -= 1
            Shell.current.positionalParameters = savedParams
            Shell.current.currentSource = savedSource
        }

        do {
            let result = try await Shell.current.execute(body)
            Shell.current.lastExitStatus = result
            return result
        } catch let ret as ReturnSignal {
            return ret.status
        }
    }
}
```

Key shape:

- **Functions and built-ins live in the same registry.**
  `Shell.commands: [String: Command]`. A function call and a
  `cat` invocation hit the same dispatch path. This means a
  user-defined `cat() { … }` shadows the kit `CatCommand` — same
  rule bash follows. No special "is this a function vs. a
  builtin" lookup.

- **Call frames are managed by the function value itself**, in
  `defer`. Each save/restore pair is paired textually so it's
  obvious nothing leaks. Locals are tracked as
  `(name, priorValue)` so `local x` shadows on push and restores
  the real value on pop, regardless of intervening assignments.

- **`return N` is an `Error` thrown by the `return` builtin** and
  caught by `FunctionCommand`. Single exit point. No flag to
  thread through every executor function.

For a Swift interpreter, the analogous shape would be: a `Function`
value carrying `parameters` (with type / default), `body: Stmt`,
and a `closureEnvironment: Environment` reference. Closures need
that captured environment; bash doesn't, because all variables are
shell-global except `local`.

**Recursion just works** because each call pushes a new frame
(`positionalParameters`, `localVarStack` element). Stack depth
bound is enforced by Swift's own recursion limit and a
`functionCallDepth` counter for diagnostic purposes.

**Mutual recursion across the file** also just works for the same
reason functions can be called at all: definitions are processed
top-to-bottom as side effects, so by the time a call site executes,
the function it references is in the registry. (Forward-references
*before* the def runs would fail — same as bash. Most scripts
top-load all their function defs to avoid this.)

---

## 4. The `Command` protocol — extensible dispatch

```swift
public protocol Command: Sendable {
    var name: String { get }
    func run(_ argv: [String]) async throws -> ExitStatus
}
```

Two lines that carry the entire extensibility story.

- **Built-ins** (`cd`, `export`, `eval`, `read`, `printf`, `trap`,
  `[`, `test`, …) — Swift structs conforming directly. Live in
  `BashInterpreter/Builtins/`. ~25 of them.
- **Kit commands** (`ls`, `cat`, `grep`, `sed`, `awk`, `find`,
  `curl`, `jq`, …) — adapt `ParsableCommand` (Swift Argument
  Parser) to `Command` via a thin bridge type. ~70 of them.
- **User functions** — `FunctionCommand` (above).
- **Closure-defined commands** — `ClosureCommand` lets a host
  embed `shell.register(name:_:) { argv in … }` without defining a
  type.

Dispatch is `commands[argv[0]]?.run(argv)`. A handful of language
constructs (arithmetic `((…))`, conditional `[[ … ]]`, group
`{ …; }`, subshell `( … )`) bypass the registry because they're
syntactic, not commands.

For Swift: the analog would be a `Builtin` or `BuiltinFunction`
protocol that wraps host-implemented `print`, `Array.append`, etc.
The registry pattern works equally well. Some interpreters fuse
this with the function-value type — same idea.

---

## 5. Streams as IPC — `AsyncStream<Data>` instead of file descriptors

The interpreter never opens a real pipe(2). Pipelines are wired up
via `OutputSink` / `InputSource`, both backed by
`AsyncStream<Data>`. Each pipeline stage runs in its own `Task`
inside a `TaskGroup`; stage *i*'s `stdout` is a fresh `OutputSink`,
stage *i+1*'s `stdin` is the matching `InputSource(bytes: sink.bytes)`.

This is the most powerful design choice in the project. Consequences:

- **No fork/exec required.** Works inside iOS App Sandbox, Swift
  Playgrounds, anywhere with a Swift runtime.
- **Streaming is first-class.** `tail -f log | grep ERROR | head -n 5`
  works because each stage iterates its stdin lazily. When `head`
  has 5 matches, its task exits, the group cancels upstream, and
  `tail`'s loop sees `Task.isCancelled`.
- **Binary data round-trips cleanly** — `Data`, not `String`.
- **Tests can capture stdout** by swapping `OutputSink.forwarding(to:)`
  for an `OutputSink()` whose `onWrite` accumulates into a string
  buffer. No file system involvement.

The cost: every command author has to be `async`-aware. Worth it.

For a Swift interpreter you probably don't need stdio at all in the
language. But the same pattern — async channels for I/O abstractions
that the host wires to either real I/O or test buffers — is a
strong default.

---

## 6. The shell as a `@TaskLocal`

```swift
@TaskLocal public static var current: Shell = Shell()
```

Every command, expansion, trap handler, and pipeline stage reads
shell state via `Shell.current`. The dispatcher binds it once at
the top of `run()`:

```swift
public func run(_ parts: [Node], source: String) async throws -> ExitStatus {
    return try await withCurrent {
        try await runImpl(parts, source: source)
    }
}
```

Subshells push their own `Shell.copy()` the same way. Pipelines per
stage do the same. The TaskLocal is propagated automatically by
Swift Concurrency across `await` boundaries — including child Tasks
spawned inside a `TaskGroup`.

Why this is better than passing `shell:` through every function:

- Adding a new shell-scoped option (`networkConfig`, `hostInfo`,
  `errexit`, `pipefail`, `shoptOptions`, …) requires no signature
  changes anywhere. Just add a property and read
  `Shell.current.X` where you need it.
- Child Tasks don't need explicit captures. `withTaskGroup { group
  in group.addTask { try await sub.withCurrent { … } } }` is the
  whole story.
- Tests can poke at the running shell without it being passed.

The single discipline: **subshell semantics are encoded by
`Shell.copy()`** — the only place that decides what propagates and
what gets snapshotted. Adding a new field means deciding
intentionally whether subshells inherit it (most things do). One
file, one method, one decision per field.

For a Swift interpreter: TaskLocal works equally well for the
"current interpreter" / "current scope" / "current source file"
state. Don't pass that explicitly through every node visitor.

---

## 7. Control flow via thrown signals

Three internal `Error` types serve as non-local exits:

```swift
struct ShellExit:        Error { let status: ExitStatus }
struct ReturnSignal:     Error { let status: ExitStatus }
struct LoopControlSignal: Error {
    enum Kind { case breakLoop, continueLoop }
    let kind: Kind
    var remainingLevels: Int
}
```

Bash's `exit`, `return`, `break N`, and `continue N` are non-local
unwinds — they have to skip past arbitrary numbers of conditionals,
loops, and command boundaries to reach the right handler. Encoding
them as thrown `Error` values means:

- **Each handler catches only its kind.** `executeWhileLike`
  catches `LoopControlSignal`; `FunctionCommand` catches
  `ReturnSignal`; the top-level `runImpl` catches `ShellExit`.
- **`break N` decrement-and-rethrow** — each enclosing loop
  decrements `remainingLevels` and re-throws if it's still > 0.
  No need to thread "are we breaking?" state.
- **Cleanup runs naturally** via `defer`. Subshell teardown,
  redirection restoration, local-variable pop all happen on the
  way up the stack.

This pattern generalises. For a Swift interpreter:
- `return` from a function → `ReturnSignal(value:)`
- `throw` (Swift's) → `UserThrowSignal(error:)` (runs deferred
  blocks until caught by `do/catch`)
- `break` / `continue` (with optional label) → exact same shape as
  ours.

Avoid encoding control flow as `enum NodeResult { case value, return, break, ... }` returned by every visitor. It poisons every
function signature. Throwing is cheaper and localises the concern.

---

## 8. Word expansion — walk source bytes, splice sub-node values

This is the single design choice I'd revisit for Swift, because it
doesn't translate. Sketching it for completeness:

A bash word like `"hello $name $(date)"` parses into a
`.word("hello $name $(date)", parts: [.parameter("name"),
.commandSubstitution(date)])`. Each sub-part has a `.range` into
the original source.

To expand at runtime, the executor walks the source bytes inside
the outer word's `range`, character by character. Whenever the
cursor matches a sub-part's `range.lowerBound`, the part is
*resolved* (variable lookup, command substitution executed, etc.)
and its result string is appended; cursor jumps past the part's
upper bound. Otherwise quoting / escapes / literal characters are
processed.

Why this works for bash: word semantics have lots of context-
sensitive rules (single quotes are literal, double quotes allow
expansion, backslashes mean different things in different
contexts, `~` only expands in specific positions, …). Re-deriving
those rules at execution time from the raw source is simpler than
encoding every nuance into AST node variants.

It wouldn't work for Swift. Swift expressions deserve a fully
typed AST. String interpolation is the closest analogue, and
`SwiftSyntax` already represents it as a tree of segments + parsed
expressions. Use that.

---

## 9. File and module organisation

One declaration per file, grouped by semantic role:

```
Sources/BashSyntax/
  API/               Public facade & error types
  AST/               Node, Kind, NodeVisitor, Dumper
  Tokenizer/         Token, TokenType, Tokenizer (one big hand-written class)
  Parser/            Parser (recursive descent), WordExpander

Sources/BashInterpreter/
  API/               Shell, Environment, Command, ExitStatus, FileSystem,
                     OutputSink, InputSource, BinCatalog, HostInfo
  Builtins/          One file per built-in (CdCommand.swift, EchoCommand.swift, …)
  Execution/         Shell+Run.swift, Shell+Pipeline.swift,
                     Shell+ControlFlow.swift, Shell+Expansion.swift,
                     Shell+ParameterExpansion.swift, Shell+Arithmetic.swift,
                     FunctionCommand.swift, ProcessTable.swift, …
  FileSystems/       RealFileSystem, InMemoryFileSystem,
                     MountedFileSystem, OverlayFileSystem (+ BinCatalogOverlay)
  Network/           NetworkConfig, URLAllowList, SecureFetcher
  Arithmetic/        ArithToken, ArithLexer, ArithParser, ArithExpr, Arithmetic
```

Three patterns worth highlighting:

- **`Type+Concern.swift` extensions** instead of one giant file
  for the central type. `Shell` is split across ~15 files, each
  scoping a behaviour (Pipeline, ControlFlow, Expansion, …). One
  `class Shell` declaration in `API/Shell.swift`; everything else
  is `extension Shell`.
- **Sub-DSLs live in their own folder.** Arithmetic is a
  language-within-the-language with its own lexer, parser, AST,
  and evaluator. Same goes for `awk`, `jq`, `sed` (in
  `BashCommandKit`). Treating them as separate self-contained
  units keeps the main interpreter pipeline clean.
- **Per-built-in files**, even when each is 10 lines. Easier to
  find, easier to test in isolation, no merge conflicts. Worth
  the directory bloat.

For a Swift interpreter: do the same. Resist the "one big
Interpreter.swift" temptation.

---

## 10. What I'd change for a Swift interpreter

The bash architecture transfers, but Swift's nature changes which
parts are easy and which are hard. Concrete differences:

| Aspect | Bash interpreter | Swift interpreter |
|---|---|---|
| Parser | Hand-written tokenizer + recursive-descent (~2 KLOC) | **Use `SwiftSyntax`.** Don't reinvent. |
| AST shape | One `struct Node { enum Kind }`, value-typed | `SwiftSyntax` gives you this; conform to `SyntaxVisitor` to walk |
| Type system | None; everything is a string | **Real type checker pass needed before execution.** This is the bulk of the work. |
| Variable scoping | One global env + `local` shadow stack | Lexical scoping. Each block a new scope. Closures capture references. Use a `Scope` linked-list / persistent map. |
| Function values | Names → `FunctionCommand` in a single map | Real function values. First-class. Closures with captured environment. Can be passed/returned. |
| Control flow signals | Errors (`ShellExit`, `ReturnSignal`, …) | Same approach: throw `ReturnSignal(value)`, `BreakSignal(label?)`, `ContinueSignal(label?)`, `UserThrowSignal(error)`. |
| `await` | Built into the executor — every `Command.run` is `async` | Swift's `async` / `await` keywords mean the executor needs to track concurrency context. Async functions return `Task`-like values. |
| Error handling | Exit codes (Int32) + a single side-channel `Error` enum | Real `try` / `catch` / `throws`. Typed throws? You decide. |
| I/O | `AsyncStream<Data>` channels for stdio | Probably no stdio in the language; `print` is a builtin. |
| Pipelines | First-class via `\|` operator + Task per stage | N/A — Swift has no shell-style pipelines. |
| Sandboxing | FS, network, processes, identity all virtualised by default | Likely just resource limits + module allow-list. |

Two bigger structural calls:

1. **Type checking is its own pass.** Bash skips this entirely;
   it's all string-typed, errors at runtime. Swift can't. Plan for
   a separate `TypeChecker` that walks the syntax tree, builds a
   typed-AST or attaches inferred types as side data, and reports
   errors before execution. This is where most of the engineering
   effort lives.

2. **Closures are the hard part of "function calling".** In bash,
   a function captures nothing — every variable is shell-global
   except `local`. In Swift, every function value can capture its
   enclosing scope. This means:
   - `Function` values carry a reference to their definition-time
     `Scope`.
   - Scopes are reference-typed (not value-typed Environment
     copies) so multiple closures see updates to shared captured
     vars.
   - Memory model: closures keep their captured scope alive.
     Either reference-count it (Swift's runtime does this for you
     if you use real Swift types under the hood) or implement a
     mark-sweep GC if you want the long-term option.

---

## 11. What I'd keep verbatim

- **The two-package split** (syntax vs interpreter). Non-negotiable.
- **Value-typed AST with Hashable / Sendable conformance.**
  `SwiftSyntax` gives you this for free.
- **`@TaskLocal current`** for the interpreter / scope. Adopt
  immediately; it removes 90% of "thread the context through every
  function" pain.
- **`Command`-style protocol** for built-ins / host-provided
  functions. Registry-based dispatch. Lets the host embed custom
  builtins easily.
- **Thrown signals for non-local exits.** Localises the concern;
  keeps every regular function's signature honest.
- **`Shell.copy()`-style "what propagates to a sub-context"
  single-source-of-truth.** Whatever your "scope inheritance" rule
  is, encode it in one method, not scattered across visitors.
- **Per-construct files.** No god classes. No 5000-line
  interpreter file.
- **Tests at every level.** SwiftBash is at 1780 tests across the
  parser, the interpreter, and each built-in. Refactors stay
  fearless because every layer has a safety net.

---

## 12. Suggested project layout for a Swift interpreter

```
SwiftInterp/
  Package.swift
  Sources/
    SwiftInterpAST/              optional: re-exports SwiftSyntax bits + helpers
    SwiftInterpTypeChecker/      type-inference + diagnostic pass
    SwiftInterpRuntime/          values, scopes, function-call frames
    SwiftInterpInterpreter/      visitor that walks typed AST and executes
      API/                       Interpreter, Scope, Value, BuiltinProtocol
      Builtins/                  print, Array.append, String.lowercased, …
      Execution/                 Interpreter+Statements.swift,
                                 Interpreter+Expressions.swift, etc.
      ControlFlow/               BreakSignal, ContinueSignal, ReturnSignal
    swift-interp/                CLI front-end (parse / typecheck / run)
  Tests/
    SwiftInterpASTTests/
    SwiftInterpTypeCheckerTests/
    SwiftInterpInterpreterTests/
    SwiftInterpBuiltinsTests/
```

Pull `swift-syntax` as a dep; never write your own Swift parser.

The hard work, ranked by effort:

1. **Type checker.** ~50% of the project. Generic constraints,
   protocol conformances, overload resolution, opaque return
   types. Start with a tiny subset — non-generic functions,
   primitive types, `let`/`var` — and grow.
2. **Scope + closure semantics.** ~20%. Get this right early.
3. **Builtins for the standard library subset.** ~20%. Decide what
   to support: pure functions on `String` / `Array` / `Dictionary`,
   probably not the entire Foundation surface.
4. **Statement / expression evaluation.** ~10%. Once typed AST and
   scopes are in place, this falls out naturally — most cases are
   "evaluate sub-expressions, apply operator".

---

## 13. Ten-line summary

1. Two packages: parser and interpreter. Don't fuse them.
2. AST is one struct + one enum, every variant carries spans.
3. Functions are values in a registry; calls dispatch through the
   same path as built-ins.
4. Hosts extend behavior via a `Command`-like protocol.
5. Pipelines / I/O = async channels, never fork.
6. The interpreter is a `@TaskLocal`. Read it; don't pass it.
7. Sub-contexts have one factory method (`copy`) that decides what
   propagates.
8. Non-local exits (`return`, `break`, `exit`) are thrown errors.
9. One declaration per file; concern-scoped extensions on the
   central type.
10. Test the parser and interpreter in isolation, then together.
