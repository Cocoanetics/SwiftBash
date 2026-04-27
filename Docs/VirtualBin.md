# Virtual `/bin` and `/usr/bin`

A SwiftBash script never executes real on-disk binaries — every
command is dispatched in-process through `Shell.commands`. So the
host's `/bin` and `/usr/bin` are irrelevant; what matters is the set
of commands the script can actually invoke.

`VirtualBinFileSystem` wraps every shell's `FileSystem` and
synthesises `/bin`, `/usr/bin`, and `/usr/local/bin` from the live
command registry. `ls /bin` reflects exactly what your script can run.

```bash
$ ls /bin
[
cat
chmod
cp
date
echo
…
test

$ ls /usr/bin | head
awk
base64
basename
bc
column
…

$ which cat
/bin/cat
$ which cd
cd: shell built-in command
$ stat /bin/cat
File: "/bin/cat"
Size: 33
Mode: -rwxr-xr-x
…
```

## Catalog

`BinCatalog.knownPaths` maps every known command name to the path
where it lives on a real macOS system. The catalog is the source of
truth for *where* a command would appear; the live registry is the
source of truth for *whether* it appears at all. The wrapper FS shows
exactly the intersection.

If a script `unregister`s a command, its entry disappears from `ls`
and `which` immediately:

```swift
let shell = Shell()
shell.registerStandardCommands()
shell.unregister("cat")
try await shell.run("ls /bin | grep cat")  // (no output)
try await shell.run("which cat")           // exit 1, no output
```

## Built-ins that *also* have files

A handful of bash built-ins (`echo`, `printf`, `pwd`, `test`, `[`,
`kill`, `wait`, `true`, `false`) ship as both a shell built-in and a
binary in `/bin` or `/usr/bin` on macOS. SwiftBash matches that — they
appear in both the registry and under their `/bin/<name>` path:

```bash
$ which echo
/bin/echo
$ type echo
echo is /bin/echo
```

Pure built-ins (`cd`, `export`, `eval`, `let`, `read`, `trap`, …) have
no file shadow — they don't on real macOS either:

```bash
$ which cd
cd: shell built-in command
$ type cd
cd is a shell builtin
```

## Reading a synthesized binary

`cat /bin/cat` works, but the bytes you get back are a one-line marker,
not a real Mach-O:

```bash
$ cat /bin/cat
swift-bash built-in command: cat
```

This keeps `cat /bin/*` from blowing up scripts that do something like
"print the first byte of every executable" — they get a stable,
self-describing string instead of an error.

## Writes are rejected

Synthesized files and directories are read-only. `chmod`, `cp …
/bin/x`, `rm /bin/cat`, `mkdir /bin/sub`, `touch /usr/bin/foo` all
return `permission denied`. The catalog is part of the runtime, not
the filesystem state.

## Rationale

The user's script lives in two worlds:

1. **The script's perception** — what `ls /bin` shows, what `which X`
   reports, what shows up in `$PATH`. This needs to match the set of
   commands the script can actually call.
2. **The host's actual filesystem** — wherever the embedder mounted
   the workspace.

Without the synthesis, those two diverge: a SwiftBash script on a
real Mac would `ls /bin` and see `bash`, `csh`, `ksh`, `zsh`, `dd`,
`pax`, `launchctl`, `wait4path` — none of which the interpreter can
actually run. And inside `--sandbox`, `ls /bin` would either show a
real path the user can't actually read (overlay) or nothing at all
(InMemoryFileSystem). Neither matches what a script-author would
expect.

`VirtualBinFileSystem` fixes that asymmetry. The script sees a `/bin`
listing that's exactly its capability surface. `which`, `type`, and
`command -v` all line up with what the script can actually invoke.
