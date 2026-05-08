# SwiftScript integration

`BashSwiftScript` is the library that wires
[SwiftScript](https://github.com/Cocoanetics/SwiftScript) — a Swift
tree-walking interpreter — into a SwiftBash `Shell` so a script
with `#!/usr/bin/env swift-script` (or just `#!/usr/bin/env swift`)
runs in-process via SwiftScript instead of returning
`command not found`.

```bash
$ cat hello.swift
#!/usr/bin/env swift-script
let names = CommandLine.arguments.dropFirst()
for name in names {
    print("hello, \(name)")
}

$ chmod +x hello.swift

$ swift-bash exec /dev/stdin <<'EOF'
./hello.swift alice bob
echo "exit=$?"
EOF
hello, alice
hello, bob
exit=0
```

## How it fits together

SwiftScript and SwiftBash both run in-process and both read their
host-touching surface — IO sinks, environment, sandbox, network
policy, identity — from `ShellKit.Shell.current`. That shared
contract is why the bridge is small: register a
`ScriptInterpreter` for the `swift-script` / `swift` shebang, hand
it the script body, and `print` / `FileManager` / `URLSession` /
`ProcessInfo` / `exit(_:)` automatically flow through whatever
shell SwiftBash has bound.

```
                         ┌── ShellKit.Shell.current ────────┐
                         │  stdin / stdout / stderr         │
   `./script.swift` ──▶  │  environment + scriptName + $@   │
   bash dispatcher       │  sandbox  (URL gate)             │
   (Shell+ExternalScript)│  networkConfig (URL allow-list)  │
                         │  hostInfo (whoami / hostname)    │
                         │  processTable + virtualPID       │
                         └──────────────────────────────────┘
                                        ▲
                                        │ SwiftScript reads through
                                        │ this same TaskLocal — no
                                        │ per-call wiring needed.
```

## Embedding

```swift
import BashInterpreter
import BashCommandKit
import BashSwiftScript

let shell = Shell()
shell.registerStandardCommands()  // BashCommandKit
shell.registerSwiftScript()       // swift-script + swift shebangs

try await shell.run("/abs/path/to/script.swift arg1 arg2")
```

`registerSwiftScript()` accepts a `names:` parameter — by default
`["swift-script", "swift"]` — so both `#!/usr/bin/env swift-script`
and `#!/usr/bin/env swift` shebangs route to the same backend. Pass
a custom list to opt out of one or the other.

The `swift-bash exec` CLI calls `registerSwiftScript()` for you —
script files with a Swift shebang work without any flag.

## What flows through automatically

Because SwiftScript reads `ShellKit.Shell.current` for its host
surface, **every bash sandbox knob also confines a Swift script**:

| Bash knob | What it does to a Swift script under `swift-script` |
|---|---|
| `Shell.stdout` / `.stderr` | `print` / runtime-error renders go to the same sinks. Capturing tests, `$(…)` substitution, `2>&1` all work. |
| `Shell.stdin` | `readLine()` and the script's stdin reads pull from here, so `echo input \| ./script.swift` feeds the script. |
| `Shell.environment` | `ProcessInfo.processInfo.environment[...]` reads from here — what `export FOO=bar` set in bash. |
| `Shell.scriptName` + `positionalParameters` | `CommandLine.arguments` and `ProcessInfo.processInfo.arguments` mirror these — argv[0] = script path, argv[1..] = the rest of the command line. |
| `Shell.sandbox` (URL gate) | `FileManager.default.fileExists(...)` / `String(contentsOfFile:)` / `URLSession.shared.data(from:)` etc. all call `Shell.current.sandbox?.authorize(_:)` before touching disk or the network. Outside-root paths throw into the script's `do/catch`. |
| `Shell.networkConfig` (URL allow-list) | `URLSession.shared.data(from:)` enforces the allow-list and method gate. |
| `Shell.hostInfo` | `ProcessInfo.processInfo.userName` / `.hostName` / `.processIdentifier` / `.processName` redirect through here — the script sees the synthetic identity, not the host's. |

## Diagnostics

- **Parse errors** print SwiftScript's caret-style diagnostics on
  the bound shell's stderr, then exit `1`. Line numbers match the
  original file (the shebang line is stripped but the trailing
  newline is preserved, so what `swift` itself reports as line `N`
  arrives as line `N` here too).
- **Runtime errors** go through `Interpreter.renderRuntimeError(_:)`
  for the same caret format, then exit `1`.
- **`exit(N)`** unwinds the script and surfaces as `ExitStatus(N)`
  to the bash dispatcher — `$?` after `./script.swift` reads the
  script's chosen code.
- **Cancellation** (e.g. `kill` against a backgrounded script)
  arrives as `CancellationError` and is reported as exit code 143
  (bash 128 + SIGTERM).

## Subshell isolation

The script runs inside `Shell.copy()` — a snapshot subshell — so
`$0`, positional parameters, errexit toggling, and any environment
`export`s done by the script don't leak back to the parent shell.
Same rule as `bash FILE` semantics.

## CLI

```bash
swift-bash exec ./script.swift arg1 arg2
swift-bash exec --sandbox ~/work ./script.swift   # confined
swift-bash exec --allow-url https://api.example.com/ ./script.swift
```

The `swift-bash exec` driver registers SwiftScript automatically.
All `--sandbox`, `--allow-url`, and identity flags apply uniformly
to bash and SwiftScript scripts.

## Known limitations

- **`--sandbox` confines escape but blocks all real disk IO from
  SwiftScript.** The `--sandbox HOST_DIR` flag binds two things:
  the legacy `Shell.fileSystem` overlay (used by bash builtins like
  `cat` / `ls`, mounted at `/batch` so scripts see a virtual view)
  AND the URL-gate `Shell.sandbox` (used by SwiftScript's
  Foundation bridges, rooted at the canonical host path). The two
  mechanisms haven't been unified yet — Foundation can't see the
  bash overlay's `/batch` mount, so a SwiftScript that does
  `FileManager.default.contents(atPath: "/batch/foo")` is denied
  by the URL gate even though the file exists in the bash view.
  Result: under `--sandbox`, SwiftScript scripts can compute and
  print but can't usefully read or write through Foundation's file
  APIs. Network, identity, and stdio still flow correctly. The
  full unification is the migration target tracked in issue #10.

- **Not every Foundation IO surface is gated yet.** The bridge
  generator currently inserts `authorizePath` / `authorizeURL`
  calls only on `FileManager`, `URLSession` (URL-arg methods),
  `String` / `Data` file-IO inits, and explicit hand-rolled
  bridges. Receivers like `FileHandle`, `Bundle`,
  `OutputStream`/`InputStream`, `NSDictionary(contentsOf:)`, and
  `URLSession` methods that take a `URLRequest` (instead of a
  bare `URL`) aren't gated yet — a determined script can reach
  the real filesystem through them. Tracked as the broader
  "inventory + gate every IO-shaped Foundation method"
  follow-up: issue #13.
