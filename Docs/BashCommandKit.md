# BashCommandKit

The catalog of "system" commands a real script expects — `ls`, `cat`,
`grep`, `sed`, `find`, `tar`, `curl`, `jq`, …. Built on top of
[Swift Argument Parser](https://github.com/apple/swift-argument-parser)
so each command gets `--help` / `--version` / typed argument validation
for free.

## Quick start

```swift
import BashInterpreter
import BashCommandKit

let shell = Shell()
shell.registerStandardCommands()

try await shell.run("""
    FILE=/tmp/data/report.txt
    NAME=$(basename $FILE .txt)
    DIR=$(dirname $FILE)
    echo "name=$NAME"
    echo "dir=$DIR"

    for n in $(seq -s ' ' 1 3); do
      echo "n=$n"
    done

    echo "today=$(date -f '%Y-%m-%d')"
    """)
```

## Writing your own typed command

Conform to `ParsableBashCommand` (a `ParsableCommand` with `execute()`)
and register the type:

```swift
import ArgumentParser
import BashInterpreter
import BashCommandKit

struct Greet: ParsableBashCommand {
    static let configuration = CommandConfiguration(
        commandName: "greet",
        abstract: "Print a friendly hello."
    )

    @Argument(help: "Who to greet.") var name: String = "world"
    @Flag(name: .shortAndLong)       var loud: Bool = false
    @Option(name: .shortAndLong)     var count: Int = 1

    mutating func execute() async throws -> ExitStatus {
        let msg = loud ? "HELLO \(name.uppercased())" : "hello \(name)"
        for _ in 0..<count { Shell.current.stdout(msg + "\n") }
        return .success
    }
}

let shell = Shell()
shell.register(Greet.self)

try await shell.run("greet --loud --count 2 alice")
// → HELLO ALICE
// → HELLO ALICE
```

`--help` / `--version` are handled automatically; invalid input produces
a formatted error on stderr and a non-zero exit.

## Shipped commands

### Filesystem & navigation

| Command | What it does |
|---------|--------------|
| `ls` | Directory listing — `-a/-A` show dotfiles, `-l/-h` long form, `-S/-r/-d/-R/-F`, classify suffixes. |
| `mkdir` | Create directories — `-p` for parents. |
| `rmdir` | Remove empty directories — `-p` for parents. |
| `rm` | Remove files / dirs — `-r/-f`. |
| `mv` | Move / rename. |
| `cp` | Copy — `-r` recursive. |
| `touch` | Create empty file or update mtime. |
| `find` | `-name`, `-iname`, `-path`, `-type`, `-empty`, `-newer`, boolean ops `-not`/`-a`/`-o`/`( )`, actions `-print`/`-print0`/`-prune`/`-delete`/`-exec`, and `-maxdepth`/`-mindepth`/`-depth`. |
| `realpath` | Canonicalise — `-m` allows missing components. |
| `readlink` | Print symlink target. |
| `basename` | Path leaf, with optional suffix stripping. |
| `dirname` | Path parent. |
| `tree` | Recursive indented directory listing. |
| `du` | Disk usage — `-h`, `-s`, depth control. |
| `df` | Filesystem free-space report (synthetic for sandbox FS). |
| `stat` | Detailed file metadata. |
| `chmod` | Change permission bits — symbolic + octal. |
| `ln` / `link` / `unlink` | Hard or symbolic links; POSIX `link`/`unlink`. |
| `mktemp` | Allocate a unique temp file (`-d` for dir, `-u` dry-run). |
| `truncate` | Set file size — `-s NNN[KMG]`, `+N` / `-N`. |
| `xattr` | List / get / set / remove extended attributes. |

### Reading & writing

| Command | What it does |
|---------|--------------|
| `cat` | Concatenate stdin / files. |
| `tee` | Copy stdin to stdout *and* each FILE — `-a` append. |
| `head` | First N lines (`-n N`). |
| `tail` | Last N lines (`-n N`, `-f` to follow). |
| `nl` | Number lines. |
| `tac` | Reverse line order. |
| `rev` | Reverse each line's characters (grapheme-aware). |
| `wc` | Count lines (`-l`), words (`-w`), bytes (`-c`). |
| `split` | Split a file into N-line / N-byte chunks. |
| `less` | Pager — interactive view via the embedder's [InteractivePresenter](../Sources/BashInterpreter/API/InteractivePresenter.swift) when `Shell.stdoutIsTTY` is true, falls back to `cat` otherwise. Supports `-N` / `-i` / `-S` / `-F` / `-R` / `-X` / `+G` and the `LESS` env prefix. |
| `more` | Same dispatch as `less` with the simpler `more(1)` key set. `-s` collapses runs of blank lines. |

### Searching

| Command | What it does |
|---------|--------------|
| `grep` | Substring or `-E` ERE; `-i`/`-v`/`-n`/`-c`/`-l`/`-q`; `-A`/`-B`/`-C` context; `-r` with `--include=GLOB`. |
| `fgrep` / `egrep` | Aliases for `grep` (substring) and `grep -E` (ERE). |
| `rg` | ripgrep subset: default-recursive, `-n`/`-i`/`-S` smart-case, `-l`/`-q`, `-m N`, `-A`/`-B`/`-C` context, `-g GLOB` (repeatable, `!`-prefix to exclude), `--hidden`, `--files` list-mode. |
| `look` *(alias of `grep ^prefix`)* | Coming. |
| `pgrep` / `pkill` | Match against the virtual process table. |

### Text manipulation

| Command | What it does |
|---------|--------------|
| `sed` | Pragmatic subset: `s/PAT/REP/[gp]`, `d`, `p` with line-number / `$` / `/regex/` addresses; `-n` quiet, `-e PROGRAM`, `-E` ERE, `-i` in-place. |
| `awk` | Subset suitable for typical scripts — pattern/action programs, `BEGIN`/`END`, field vars `$1..$NF`, common functions. |
| `sort` | `-u` dedup, `-n` numeric, `-r` reverse, `-k FIELD`. |
| `uniq` | `-c` count, `-d` only dupes, `-u` only uniques. |
| `tr` | Translate / delete chars; `-d`, `a-z` ranges, `\n`/`\t`/`\\`. |
| `cut` | `-f` (with ranges/lists), `-d DELIM`. |
| `paste` | Side-by-side with `-d DELIM`, `-s` serial. |
| `join` | Relational join on a key field. |
| `comm` | Three-column compare of two sorted files. |
| `expand` / `unexpand` | Tabs ↔ spaces. |
| `fold` | Wrap lines to a width. |
| `column` | Format input into columns. |
| `xargs` | Build & run command lines from stdin. |
| `patch` | Apply a unified diff. |

### Encoding & hashing

| Command | What it does |
|---------|--------------|
| `base64` | Encode / decode (`-d`); 76-char wrapping. |
| `xxd` | Hex dump (16-byte rows + ASCII). |
| `od` | Octal / hex (`-x`) / character (`-c`) dump. |
| `md5` / `md5sum` / `sha1sum` / `sha256sum` / `shasum` | Coreutils-format `<hex>  <file>` digests via CryptoKit. |
| `gzip` / `gunzip` | gzip RFC 1952 via `Compression` framework. |
| `tar` | Archive / extract — POSIX ustar; `-c`/`-x`/`-t`/`-v`/`-f`/`-z`. |
| `cmp` / `diff` | Compare files; `diff -u N` for unified context. |
| `strings` | Print printable runs from binary input. |
| `jq` / `yq` | Filter & transform JSON / YAML. |

### Introspection / shell-state

| Command | What it does |
|---------|--------------|
| `which` | Print `/bin/<name>` for file-shadowed commands; `<name>: shell built-in command` for pure built-ins. |
| `type` | `<name> is /bin/<name>` or `<name> is a shell builtin`. |
| `command` | `command -v X` registry lookup; or run X bypassing functions. |
| `env` | Print sorted environment. |
| `printenv` | Print one or more vars. |
| `whoami` / `id` / `groups` | Identity, all driven by `Shell.hostInfo`. |
| `hostname` / `uname` | Host / kernel info, all driven by `Shell.hostInfo`. |
| `clear` | ANSI clear-screen + cursor-home. |

### Process & timing

| Command | What it does |
|---------|--------------|
| `ps` / `kill` / `pgrep` / `pkill` | Operate on the virtual process table. No host PIDs are ever exposed. |
| `sleep` | Pause for fractional seconds (cancellable). |
| `time` | Wall-clock and CPU timing of a child command. |
| `timeout` | Run a command with a deadline. |
| `yes` | Print a string repeatedly (cancellable). |

### Misc

| Command | What it does |
|---------|--------------|
| `date` | Current date/time with `strftime` formatting (`-f`, `-u`). |
| `seq` | Number sequence (`-s SEP` separator). |
| `expr` | Evaluate integer / string expressions. |
| `bc` | Arbitrary-precision calculator (basic). |
| `curl` | HTTP/S fetch with URL allow-list — see [Networking.md](Networking.md). |

The full registration list lives in `Shell.registerStandardCommands()`;
register individually with `shell.register(LsCommand.self)` if you want
a smaller surface area.

## Where do these appear in the filesystem?

Every kit command is mapped to a canonical `/bin/<name>` or
`/usr/bin/<name>` path via `BinCatalog`. A wrapper `FileSystem`
synthesises those directories so `ls /bin` reflects what the script
can actually invoke. See [VirtualBin.md](VirtualBin.md).
