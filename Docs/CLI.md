# `swift-bash` CLI

The package ships a command-line front-end built on
[swift-argument-parser](https://github.com/apple/swift-argument-parser).
Two subcommands: `parse` (AST inspection) and `exec` (run a script).

Install once:

```bash
swift build -c release
# binary at .build/release/swift-bash
```

…or run directly during development with `swift run swift-bash <subcommand> …`.

## `swift-bash parse`

Print the AST for a bash command, without running it.

```
$ swift-bash parse 'true && cat <(echo hi)'
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

Options:

- positional `<source>` — a bash command string.
- `-f, --file <path>` — read the source from a file instead.
- `-s, --with-source` — render `s='…'` slices instead of `pos=(…,…)`.
- `--first` — parse only the first top-level unit.

## `swift-bash exec <script>`

Run a bash script through the interpreter. The process's environment is
forwarded, stdout/stderr stream live through, and the script's exit
status becomes the CLI's exit code. All `registerStandardCommands()`
commands plus the language built-ins are pre-registered.

```bash
$ cat Examples/date-loop.sh
#!/usr/bin/env bash
for i in $(seq 12); do
  date
  sleep 5
done

$ swift-bash exec Examples/date-loop.sh
Fri Apr 24 21:52:31 CEST 2026
…
```

### Sandboxing flags

By default `exec` runs **trusted**: the real filesystem, no network
restrictions, your real identity. Use these flags to lock things down.

| Flag                          | Effect                                                  |
|-------------------------------|---------------------------------------------------------|
| `--sandbox PATH`              | Confine FS to PATH (mounted at `/batch`). Default-deny network, synthetic identity. |
| `--allow-url URL`             | Add URL prefix to the curl allow-list (repeatable).     |
| `--allow-method METHOD`       | Add HTTP method to the allow-list (repeatable).         |
| `--no-deny-private`           | Don't block private-IP destinations (default *blocks*). |
| `--dangerous-full-network`    | Skip allow-list entirely. Only for fully trusted scripts. |

Examples:

```bash
# Sandboxed execution against ~/Documents/scratch with read-only network access.
swift-bash exec --sandbox ~/Documents/scratch \
                --allow-url https://api.github.com/repos/example/ \
                analyze.sh

# Trusted run with the real filesystem and full network — like /bin/bash.
swift-bash exec script.sh

# AI-generated script, no host access.
echo "$llm_output" | swift-bash exec --sandbox /tmp/work /dev/stdin
```

### Identity flags

By default `exec` uses `HostInfo.real()` (real `whoami` / `hostname` /
`id` etc.); `--sandbox` switches to `HostInfo.synthetic`. To customize:

| Flag                 | Effect                                       |
|----------------------|----------------------------------------------|
| `--synthetic-identity` | Force synthetic identity even without `--sandbox`. |
| `--real-identity`      | Force real identity even with `--sandbox`. |

## What's pre-registered

`swift-bash exec` runs `Shell.registerStandardCommands()` on startup,
which gives the script the full kit catalog —
[BashCommandKit](BashCommandKit.md) lists every command. The language
built-ins (`cd`, `export`, `let`, `read`, `printf`, `trap`, `wait`, …)
come from `BashInterpreter` and are always available.

## Coverage report

`swift-bash` ships a couple of lesser-used subcommands for CI and
benchmarking:

- `swift-bash claude-usage` — print which standard bash features are
  exercised by a corpus of LLM-generated scripts (used to drive
  conformance work).
- `swift-bash codex-usage` — same, but for OpenAI Codex–style scripts.

These are project-internal observability tools, not user-facing
features.
