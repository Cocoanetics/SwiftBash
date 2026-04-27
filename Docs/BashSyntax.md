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

## Limitations

A handful of bash features are intentionally out of scope for now:

- Complex parameter expansions like `${parameter#word}` parse into a single
  `parameter` node carrying the literal body — no sub-parsing.
- `[[ … ]]` test commands, `select`, `coproc`, and the `time` reserved word
  are recognised lexically but not fully represented in the AST.
- `$'…'` ANSI-C quoting is preserved literally; escape sequences are not
  interpreted.
