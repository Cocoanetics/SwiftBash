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
- **`MountedFileSystem`** — confines a script to one or more host
  directories mounted at chosen virtual paths. Reads and writes go
  to the real disk under each mount; paths outside every mount
  report `notFound`. Symlinks that escape a mount's host root are
  rejected via canonical-path comparison; virtual ancestor
  directories (e.g. `/` when the only mounts are `/batch` and
  `/tmp`) are synthesised so `cd /` works. Bash builtins and
  FileManager-backed callers (SwiftPorts CLIs, SwiftScript bridges)
  see the same files because both end up at real-disk paths under
  the mounts.
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

- `fileSystem = MountedFileSystem` with mounts on real disk:
  - virtual `/batch` (or `--workspace`) → host `PATH` (read-write)
  - virtual `/tmp` → host `NSTemporaryDirectory()` (read-write)
  - the host's real temp dir → itself, when it isn't `/tmp` (so
    `$TMPDIR/foo` and `/tmp/foo` reach the same files on macOS,
    iOS, Windows)
- `TMPDIR = NSTemporaryDirectory()` in the script's environment
- `sandbox = Sandbox.bashWorkspace(workspace: workspace)` (URL gate for SwiftPorts CLIs)
- `networkConfig = nil` (deny-all)
- `hostInfo = .synthetic`
- Process table is always virtual (no flag needed)

```bash
$ swift-bash exec --sandbox /tmp/work script.sh
```

The script sees `/batch` as its workspace, can `cd /batch && ls`,
write files there (and they persist at `/tmp/work` on the host), and
can use `/tmp` as scratch — writes through either virtual path land
on real disk so FileManager-backed callers (SwiftPorts CLIs,
SwiftScript bridges) see them immediately. The script can't reach
`/Users/`, `~/Documents`, `/etc/passwd`, or anything else on the host.
It can't make network requests. `whoami` says "user". `hostname` says
"sandbox". Issues #48 / #49.

For embedders not using the CLI, mirror the same setup:

```swift
let workspace = NSHomeDirectory() + "/Documents/scratch"
let shell = Shell(
    environment: {
        var env = Environment.empty()
        env.workingDirectory = "/batch"
        return env
    }(),
    fileSystem: MountedFileSystem(
        mounts: [
            .init(virtual: "/batch", host: workspace),
            .init(virtual: "/tmp", host: NSTemporaryDirectory())
        ],
        backing: RealFileSystem())
)
shell.registerStandardCommands()
// hostInfo defaults to .synthetic; networkConfig defaults to nil.
```

## Threat model

The sandbox is designed against a script that is **adversarial but
in-process** — the threat is information leakage and unauthorized
state changes, not memory-level exploitation of the runtime itself.

**In scope:**
- Reading host files outside the mount points.
- Writing host files outside the mount points. Writes *inside* the
  configured mounts (workspace + `/tmp`) land on real disk by design —
  that's how FileManager-backed callers (SwiftPorts CLIs, SwiftScript
  bridges) and bash builtins agree on what's reachable.
- Discovering host identity (uid, username, hostname, machine).
- Seeing host processes via `ps` / `pgrep`.
- Probing the network (default deny; allow-list with segment-safe matching).
- TOCTOU and symlink-traversal escape attempts.

**Inside the mounts**, writes persist to real disk (the CLI's choice
for `--sandbox`). The workspace is wherever the user pointed
`--sandbox`; `/tmp` resolves to `NSTemporaryDirectory()` on the host,
shared with other processes per the platform's convention.

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
