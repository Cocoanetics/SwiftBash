# SwiftBash

Swift libraries for working with bash source.

| Product                | Status     | What it does                                    |
|------------------------|------------|-------------------------------------------------|
| **`BashSyntax`**       | Available  | Parse bash into a typed AST; smart tokeniser.   |
| **`BashInterpreter`**  | Skeleton   | Execute ASTs — built-ins only (no subprocess yet). |
| **`swift-bash`** (CLI) | Available  | Command-line front-end for `BashSyntax`.        |

The rest of this README covers `BashSyntax`. Additional products will get
their own sections as they land.

---

# BashSyntax

A modern Swift implementation of a bash syntax parser. Parses bash source
into a full AST — without executing anything — and handles the tricky
constructs (command and process substitutions, nested quoting, heredocs)
that trip up `shlex`-style splitters.

## Features

- **Value-typed AST** — a single `Node` struct wrapping an
  `indirect enum Kind`; every node knows its source span.
- **Correct nested substitutions** — `$(…)`, `` `…` ``, `<(…)`, `>(…)`
  parse recursively, with positions that point back into the original source.
- **Quoting that matches bash** — single quotes are literal, double quotes
  allow expansion, backslash escapes follow shell rules.
- **Full command structure** — lists (`&&`, `||`, `;`, `&`, `\n`), pipelines
  (`|`, `|&`), redirections (all variants including `<<`, `<<-`, `<<<`, `&>`),
  `if` / `while` / `until` / `for` / `case`, subshells, group commands,
  function definitions, heredocs.
- **Visitor protocol** — traverse the AST with default-implemented
  `NodeVisitor` methods.
- **Readable `dump()`** for inspecting the AST during development.
- **No dependencies** beyond Swift's standard library. `Sendable`- and
  `Hashable`-conformant throughout.

## Install

Add the `SwiftBash` package to your `Package.swift`:

```swift
.package(url: "https://github.com/.../SwiftBash", from: "0.1.0")
```

and depend on the `BashSyntax` product:

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "BashSyntax", package: "SwiftBash"),
]),
```

## Usage

### Parse a bash command

```swift
import BashSyntax

let parts = try BashSyntax.parse("true && cat <(echo $(echo foo))")
for ast in parts {
    print(ast.dump())
}
```

Output:

```
ListNode(pos=(0, 31), parts=[
  CommandNode(pos=(0, 4), parts=[
    WordNode(pos=(0, 4), word='true'),
  ]),
  OperatorNode(op='&&', pos=(5, 7)),
  CommandNode(pos=(8, 31), parts=[
    WordNode(pos=(8, 11), word='cat'),
    WordNode(pos=(12, 31), word='<(echo $(echo foo))', parts=[
      ProcesssubstitutionNode(command=
        CommandNode(pos=(14, 30), parts=[
          WordNode(pos=(14, 18), word='echo'),
          WordNode(pos=(19, 30), word='$(echo foo)', parts=[
            CommandsubstitutionNode(command=
              CommandNode(pos=(21, 29), parts=[
                WordNode(pos=(21, 25), word='echo'),
                WordNode(pos=(26, 29), word='foo'),
              ]), pos=(19, 30)),
          ]),
        ]), pos=(12, 31)),
    ]),
  ]),
])
```

Pass `source:` to `dump()` to substitute each `pos=(a, b)` with the actual
source slice `s='…'`.

### Smart tokenising

`BashSyntax.split` is a drop-in replacement for `shlex.split`-style tokenisers
that understands shell-specific constructs such as command and process
substitutions:

```swift
try BashSyntax.split(#"cat <(echo "a $(echo b)") | tee"#)
// => ["cat", #"<(echo "a $(echo b)")"#, "|", "tee"]
```

A naive splitter would incorrectly break `<(echo "a $(echo b)")` apart at
whitespace.

### Inspect an AST

`Node.kind` is an enum you pattern-match on:

```swift
let node = try BashSyntax.parseSingle("ls | grep foo")

guard case .pipeline(let parts) = node.kind else {
    fatalError("not a pipeline")
}
for part in parts {
    switch part.kind {
    case .command(let words):
        print("command with \(words.count) word(s)")
    case .pipe(let op):
        print("pipe operator: \(op)")
    default:
        break
    }
}
```

For generic traversals, use the visitor:

```swift
struct CommandCounter: NodeVisitor {
    var count = 0
    mutating func visitCommand(_ node: Node, parts: [Node]) -> Bool {
        count += 1
        return true
    }
}

var counter = CommandCounter()
try BashSyntax.parseSingle("a && b | c || d").walk(&counter)
print(counter.count) // 4
```

### Position tracking

Every node has a `range: Range<Int>` mapping to character offsets in the
original source — including nodes created from recursively parsed
substitution bodies:

```swift
let src = "echo $(date)"
let node = try BashSyntax.parseSingle(src)
guard case .command(let parts) = node.kind,
      case .word(_, let wordParts) = parts[1].kind,
      case .commandSubstitution(let cmd) = wordParts.first?.kind
else { return }

print(cmd.source(from: src)) // "date"
```

### Error handling

`BashSyntax.parse` throws `BashSyntaxError.parsing(message:source:position:)` on
syntax errors:

```swift
do {
    _ = try BashSyntax.parse(#"echo "unterminated"#)
} catch let err as BashSyntaxError {
    print(err) // "unexpected EOF while looking for matching '\"' (position 18)"
    print(err.position ?? -1)
}
```

## Public API summary

| Symbol                      | Purpose                                             |
|-----------------------------|-----------------------------------------------------|
| `BashSyntax.parse(_:)`         | Full parse; returns `[Node]` of top-level units.    |
| `BashSyntax.parseSingle(_:)`   | Parse the first top-level unit only.                |
| `BashSyntax.split(_:)`         | Shell-aware tokeniser that preserves substitutions. |
| `Node`                      | AST node; has `kind`, `range`, and helpers.         |
| `Node.Kind`                 | Enum of every AST variant.                          |
| `Node.dump(indent:source:)` | Debug pretty-printer.                               |
| `Node.walk(_:)`             | Run a `NodeVisitor` over the subtree.               |
| `NodeVisitor`               | Protocol with default no-op implementations.        |
| `Tokenizer`, `Parser`       | Lower-level building blocks, for advanced use.      |
| `BashSyntaxError`              | `parsing(message:source:position:)` / `unimplemented`. |

---

# BashInterpreter

A minimal AST-walking interpreter sitting on top of `BashSyntax`. The
current "skeleton" cut runs **built-ins only** — no subprocess spawning,
no pipelines, no redirection plumbing yet — enough to exercise word
expansion, environment management, and list execution end-to-end.

```swift
import BashInterpreter

let shell = Shell()
shell.environment["PATH"] = "/usr/bin:/bin"
shell.environment["USER"] = "oliver"

try shell.run("echo hello $USER")          // → hello oliver
try shell.run("echo PATH is $PATH")        // → PATH is /usr/bin:/bin
try shell.run("export GREETING=welcome")
try shell.run("echo $GREETING")            // → welcome

// Short-circuit lists work:
try shell.run("false || echo fallback")    // → fallback
try shell.run("true && echo yes")          // → yes
```

## What works

- Simple command dispatch against a built-in registry.
- **Built-ins**: `echo` (including `-n`, `--`), `true`, `false`, `:`,
  `pwd`, `cd` (including `cd -`, `cd` with no arg), `export`, `unset`,
  `exit`.
- **Lists**: `;`, `\n`, `&&` and `||` (with short-circuit), `&`
  (currently runs foreground).
- **Variable expansion**: `$NAME`, `${NAME}`, `$?`, `$$`, concatenation
  (`$A$B`), inside double quotes, suppressed inside single quotes.
- **Command substitution**: `$(…)` and `` `…` `` — executed in the
  current shell, stdout captured and trimmed.
- **Tilde expansion**: bare `~` expands to `$HOME`.
- **Assignments**: standalone `X=value` sets a variable; prefix
  `X=value cmd` scopes the assignment to that command (matching bash
  semantics, including expansion order).
- **`$?`** reflects the previous command's exit status.
- **`exit [N]`** unwinds the whole run.

## What's not implemented yet

- Subprocess execution — anything that isn't a registered built-in
  throws `commandNotFound`.
- Pipelines (`|`, `|&`) and redirections.
- Control flow: `if`, `while`, `until`, `for`, `case`.
- Arithmetic evaluation inside `((…))` / `$((…))`.
- Process substitution `<(…)`, `>(…)`, and here-strings `<<<`.
- Globbing, word splitting (on `$IFS`), and `${var:-default}`-style
  parameter expansion operators.

These are the natural next increments; the skeleton gives each of them
a concrete place to land.

## CLI: `swift-bash`

The package ships a command-line front-end built on
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

```
$ swift run swift-bash parse 'true && cat <(echo hi)'
ListNode(pos=(0, 22), parts=[
  CommandNode(pos=(0, 4), parts=[
    WordNode(pos=(0, 4), word='true'),
  ]),
  OperatorNode(op='&&', pos=(5, 7)),
  CommandNode(pos=(8, 22), parts=[
    WordNode(pos=(8, 11), word='cat'),
    WordNode(pos=(12, 22), word='<(echo hi)', parts=[
      ProcesssubstitutionNode(command=
        CommandNode(pos=(14, 21), parts=[
          WordNode(pos=(14, 18), word='echo'),
          WordNode(pos=(19, 21), word='hi'),
        ]), pos=(12, 22)),
    ]),
  ]),
])
```

Options on `parse`:

- positional `<source>` — a bash command string.
- `-f, --file <path>` — read the source from a file instead.
- `-s, --with-source` — render `s='…'` slices instead of `pos=(…,…)`.
- `--first` — parse only the first top-level unit.

Install the binary once with `swift build -c release` (output at
`.build/release/swift-bash`), or run directly during development with
`swift run swift-bash parse …`.

## Limitations

A handful of bash features are intentionally out of scope for now:

- Arithmetic **expressions** inside `((…))` / `$((…))` are captured as a
  raw body string on the corresponding `arithmeticCommand` /
  `arithmeticSubstitution` node — the math itself is not parsed into a
  sub-AST.
- Complex parameter expansions like `${parameter#word}` parse into a single
  `parameter` node carrying the literal body — no sub-parsing.
- `[[ … ]]` test commands, `select`, `coproc`, and the `time` reserved word
  are recognised lexically but not fully represented in the AST.
- `$'…'` ANSI-C quoting is preserved literally; escape sequences are not
  interpreted.

## Layout

`BashSyntax` keeps one top-level declaration per file, grouped into
semantic folders. Extensions live in `Type+Extension.swift`.

```
Sources/BashSyntax/
  API/
    BashSyntax.swift                     Public facade (parse / parseSingle / split)
    BashSyntaxError.swift                Error type

  AST/
    Node.swift                           struct Node { enum Kind }
    Node+Inspection.swift                kindName, children, source(from:)
    Node+Walk.swift                      walk(_:)
    Node+Dump.swift                      dump(indent:source:)
    Node+Shifted.swift                   shifted(by:) for splicing subtrees
    Node+CustomStringConvertible.swift
    NodeVisitor.swift                    Protocol
    NodeVisitor+Defaults.swift           Default no-op implementations
    Dumper.swift                         Internal pretty-print engine

  Tokenizer/
    Token.swift                          struct Token
    TokenType.swift                      enum TokenType
    TokenType+Lookup.swift               Reserved words + command-start types
    TokenFlags.swift                     OptionSet on word tokens
    Tokenizer.swift                      Hand-written shell tokenizer
    SyntaxClass.swift                    Shell-character classification tables
    Character+isASCIIDigit.swift

  Parser/
    Parser.swift                         Recursive-descent parser
    WordExpander.swift                   $(…), <(…), ${…}, ~, backticks

Sources/swift-bash/
  SwiftBashCLI.swift                     Root command (@main)
  ParseCommand.swift                     `swift-bash parse` subcommand
  CLIError.swift                         LocalizedError wrapper for nice output

Sources/BashInterpreter/
  API/
    Shell.swift                          Main executor class
    Environment.swift                    Variables + cwd
    ExitStatus.swift                     0 = success, non-zero = failure
    BashInterpreterError.swift           commandNotFound / unimplemented / io
  Builtins/
    Builtin.swift                        Protocol
    EchoBuiltin.swift … ExitBuiltin.swift One file per built-in
  Execution/
    Shell+Run.swift                      Top-level dispatch + lists
    Shell+Expansion.swift                $VAR / $(…) / ~ expansion
```

## License

MIT. See [LICENSE](LICENSE).
