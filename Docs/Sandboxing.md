# Sandboxing

SwiftBash exists to be embedded inside a host app — including
sandboxed Mac and iOS apps — and run untrusted scripts (often
LLM-generated) safely. That goal drives the architecture: a script
should not, by default, be able to fingerprint or reach the host.

The defaults make this true. A freshly-constructed `Shell()` leaks
nothing about the machine it's running on — no real username, no
host name, no real PIDs, no real `/bin` listing, no network access.
Embedders opt in to each axis individually.

## Four virtualisation axes

### 1. Filesystem

All file I/O routes through a `FileSystem` protocol. Three
implementations ship:

- **`InMemoryFileSystem`** — pure in-memory tree. No disk involvement.
- **`SandboxedOverlayFileSystem`** — confines a script to a single
  host directory plus an in-memory `/tmp`. Reads fall through to
  the host root; writes are captured in memory. Symlink escape is
  blocked, every host path passes through `realpath(3)` and is
  rejected if it escapes the canonical root, and error messages
  reference virtual paths only — host paths never leak.
- **`RealFileSystem`** — the host's real `FileManager`. Use only
  when the script is fully trusted.

Whatever you pass to `Shell(fileSystem:)` is wrapped in
`VirtualBinFileSystem` so `/bin`, `/usr/bin`, and `/usr/local/bin`
listings always reflect *this shell's* command registry, not the
host's actual bin directories. See [VirtualBin.md](VirtualBin.md).

### 2. Network

`curl` (and any other network-using command) reads `Shell.networkConfig`.
The default is `nil`, which means **deny all**. Curl reports
`Network access denied: URL not in allow-list` and exits with status 7.

To enable, populate a `NetworkConfig` with concrete URL prefixes:

```swift
shell.networkConfig = NetworkConfig(
    allowedURLPrefixes: [
        "https://api.example.com/v1/",
        "https://docs.example.com/",
    ],
    allowedMethods: ["GET", "POST"],
    denyPrivateIPs: true            // block 127.0.0.1, 10/8, 192.168/16, …
)
```

Allow-list matching is segment-boundary safe: `https://example.com/api`
does **not** match `https://example.com/api-internal`. URL-encoded
slashes (`%2f`) and backslashes (`%5c`) are rejected outright. See
[Networking.md](Networking.md).

### 3. Processes

`&`, `wait`, `ps`, `kill`, `pgrep`, `pkill` operate on
`Shell.processTable` — a virtual table backed by Swift `Task`s.
Background jobs spawn as Tasks; `wait $!` awaits them; `kill PID`
cancels the Task. `$$` returns `Shell.virtualPID` (default 1) —
never the host's PID. There is no path to the host's real process
table.

Cancellation is cooperative — Swift has no `SIGKILL` for in-process
Tasks. Long-running commands check `Task.checkCancellation()` at each
iteration so `kill` ends them in roughly a millisecond.

### 4. Identity

`Shell.hostInfo` is a `HostInfo` struct holding the values that
`whoami`, `hostname`, `id`, `uname`, `df`, file ownership in `ls -l`,
`$USER`, `$HOSTNAME`, and so on, all read from. The default is
`HostInfo.synthetic`:

```
userName     = "user"
fullUserName = "user"
hostName     = "sandbox"
uid          = 1000
gid          = 1000
groups       = [1000]
groupName    = "users"
kernelName   = "Darwin"
machine      = "arm64"
nodeName     = "sandbox"
```

Embedders that want the script to see the real host identity opt in
explicitly:

```swift
shell.hostInfo = HostInfo.real()
```

`HostInfo.real()` queries `ProcessInfo`, `getuid(2)`, `getgroups(2)`,
`uname(3)`, `getgrgid(3)` and surfaces the actual values.

## Putting it together — the `--sandbox` flag

The `swift-bash` CLI's `exec --sandbox PATH` flag enforces all four
axes at once:

- `fileSystem = SandboxedOverlayFileSystem(.init(root: PATH, mountPoint: "/batch"))`
- `networkConfig = nil` (deny-all)
- `hostInfo = .synthetic`
- Process table is always virtual (no flag needed)

```bash
$ swift-bash exec --sandbox /tmp/work script.sh
```

The script sees `/batch` as its workspace, can `cd /batch && ls`,
write files there, but can't reach `/Users/`, `~/Documents`,
`/etc/passwd`, or anything else on the host. It can't make network
requests. `whoami` says "user". `hostname` says "sandbox".

For embedders not using the CLI, mirror the same setup:

```swift
let shell = Shell(
    environment: {
        var env = Environment.empty()
        env.workingDirectory = "/batch"
        return env
    }(),
    fileSystem: try SandboxedOverlayFileSystem(.init(
        root: NSHomeDirectory() + "/Documents/scratch",
        mountPoint: "/batch"))
)
shell.registerStandardCommands()
// hostInfo defaults to .synthetic; networkConfig defaults to nil.
```

## Threat model

The sandbox is designed against a script that is **adversarial but
in-process** — the threat is information leakage and unauthorized
state changes, not memory-level exploitation of the runtime itself.

**In scope:**
- Reading host files outside the mount point.
- Writing host files (sandboxed → all writes captured in memory).
- Discovering host identity (uid, username, hostname, machine).
- Seeing host processes via `ps` / `pgrep`.
- Probing the network (default deny; allow-list with segment-safe matching).
- TOCTOU and symlink-traversal escape attempts.

**Out of scope:**
- Memory-corruption attacks against Swift runtime / Foundation.
- DoS via CPU / memory exhaustion (caller decides time / resource limits).
- Side-channel inference from system load.

If you need the first category, run the host process inside an OS-level
sandbox (App Sandbox, `sandbox-exec`) in addition to SwiftBash's
in-process sandbox.

## Verifying the sandbox

The fastest sanity check after wiring things up:

```bash
$ echo 'whoami; hostname; id; ls /Users 2>&1; cat /etc/passwd 2>&1' \
    | swift-bash exec --sandbox /tmp/work /dev/stdin
user
sandbox
uid=1000(user) gid=1000(users) groups=1000(users)
ls: /Users: No such file or directory
cat: /etc/passwd: No such file or directory
```

If any of those leaks the real values, file an issue — that's the bug,
not "expected sandbox behaviour".
