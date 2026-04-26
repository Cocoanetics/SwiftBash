# Bash version conformance

SwiftBash targets **bash 4.x semantics** for every feature it implements,
not the bash 3.2 (2007) that ships as `/bin/bash` on macOS.

This page lists every place where `swift-bash exec script.sh` produces
different output from macOS's `/bin/bash script.sh` because
SwiftBash is implementing a feature bash 3.2 lacks. Modern Linux bash,
Homebrew's bash 4+/5, and bash on most other systems all match
SwiftBash's behaviour.

> **TL;DR.** When you see a difference between SwiftBash and the
> shipped `/bin/bash`, install a current bash (`brew install bash`,
> `/opt/homebrew/bin/bash`) and compare against that — it almost
> always agrees with us.

---

## Parameter expansion

### `${var^^}` `${var,,}` `${var^}` `${var,}` — case conversion

```bash
v=hello
echo "${v^^}"     # SwiftBash & bash 4+: HELLO
                  # macOS bash 3.2:      ${v^^}: bad substitution
echo "${v,}"      # SwiftBash & bash 4+: hello (lowercase first char)
                  # macOS bash 3.2:      bad substitution
```

`^` and `,` operators were introduced in bash 4.0. The pattern variant
(`${v^^[abc]}`) is also supported.

### `${arr[-1]}` — negative array indices

```bash
arr=(a b c d)
echo "${arr[-1]}" # SwiftBash & bash 4.3+: d
                  # macOS bash 3.2:        bad array subscript
```

Negative indexing counts from the highest set slot (sparse-aware,
matching bash 4.3+).

### `${!ref}` — indirect expansion (was missing entirely)

This already existed in bash 2.x, but SwiftBash had a regression where
`${!ref}` returned empty. Fixed alongside the bash 4 work.

---

## Arrays

### `declare -A` — associative arrays

```bash
declare -A m
m[apple]=red          # SwiftBash & bash 4+: works
                      # macOS bash 3.2:      declare: -A: invalid option
```

### `mapfile` / `readarray`

```bash
mapfile -t arr < <(printf "a\nb\nc\n")
echo "${arr[1]}"      # SwiftBash & bash 4+: b
                      # macOS bash 3.2:      mapfile: command not found
```

---

## Brace expansion

### `{01..05}` — zero-padding preserved

```bash
echo {01..05}         # SwiftBash & bash 4+: 01 02 03 04 05
                      # macOS bash 3.2:      1 2 3 4 5
```

bash 4 preserves the visual padding of the endpoints; 3.2 strips it.

`{a..e}` (single-character ranges) and `{N..M..step}` (sequence with
step) are supported in both eras and behave identically.

---

## Globbing

### `globstar` — `**` across directory levels

```bash
shopt -s globstar
ls **/*.txt           # SwiftBash & bash 4+: matches at any depth
                      # macOS bash 3.2:      matches one level only
                      #                       (globstar option missing)
```

### `extglob` — `?(p) *(p) +(p) @(p) !(p)`

```bash
shopt -s extglob
case "abc.txt" in
    *.+(txt|md)) echo "match" ;;
esac
                      # SwiftBash:           match (extglob always
                      #                       enabled in case patterns)
                      # macOS bash 3.2:      enabled by `shopt`,
                      #                       supported there too
```

`extglob` is implicitly on inside `case` patterns and `[[ ... == ... ]]`
in SwiftBash; bash gates it on the `shopt -s extglob` toggle. The
syntax is identical.

### `nullglob`, `dotglob`, `nocaseglob`, `nocasematch`

All four `shopt`-controlled glob options are tracked. Effects:

- `nullglob` — unmatched globs disappear (zero args) instead of being
  passed through literally.
- `dotglob` — globs match leading-dot files (`.hidden`).
- `nocaseglob` — glob matching is case-insensitive.
- `nocasematch` — `case` patterns and `[[ s == p ]]` are
  case-insensitive.

bash 3.2 has the option names but not all the behaviours wired up
consistently.

### Mixed quoted-prefix-plus-glob in `[[ ... == ... ]]`

```bash
[[ "hello" == "h"* ]] && echo prefix
                      # SwiftBash & bash 4+: prefix
                      # macOS bash 3.2:      no output
                      #                      (treats whole RHS as literal
                      #                       once it sees a quote)
```

The RHS is rebuilt as a glob pattern with the quoted spans escaped, so
the `*` after a quoted `"h"` still acts as a glob.

---

## Builtins

### `let EXPR…`

bash 3.2 has `let` too, but with a different exit-status convention
quirk for empty arguments. SwiftBash matches bash 4.x: the exit status
reflects the truthiness of the *last* expression (`let x=0` returns 1,
`let x=42` returns 0).

### `shopt`

Available on bash 3.2 but with fewer recognised option names. SwiftBash
silently accepts unknown option names (set/unset both return success)
so scripts that probe for bash 4.x options like `shopt -s globstar` on
older bash still work.

---

## Commands

### `tac`

```bash
seq 5 | tac           # SwiftBash:           5 4 3 2 1
                      # macOS bash 3.2:      tac: command not found
                      #                      (Linux has it; macOS doesn't)
```

### `cat -A` / `cat -E` (GNU vs BSD)

```bash
printf "x\ty\n" | cat -A
                      # SwiftBash & GNU cat: x^Iy$
                      # macOS BSD cat:       illegal option -- A
```

SwiftBash's `cat` follows GNU semantics; macOS ships BSD `cat` which
lacks several display flags.

### `seq -s,` separator

```bash
seq -s, 1 4           # SwiftBash & GNU seq: 1,2,3,4
                      # BSD seq (macOS):     1,2,3,4,
                      #                      (trailing separator)
```

### `wc` output format

SwiftBash's `wc` right-aligns counts in 8-character columns, matching
both BSD and GNU `wc`. Counts now include `-m` (characters), missing
from older versions.

### `tail -NUM` shorthand

```bash
seq 100 | tail -5     # SwiftBash & coreutils tail: works
                      # bash 3.2 tail (BSD):        also works in BSD,
                      #                              but GNU coreutils
                      #                              prefers `-n 5`
```

SwiftBash accepts both forms.

### `tr -s` (squeeze) and `-c` (complement)

bash 3.2's BSD `tr` supports both, so this is a feature parity rather
than a divergence — listed for completeness.

### `diff` default format

SwiftBash's `diff` defaults to BSD/GNU "normal" format (`<`/`>`); pass
`-u` for unified. This *matches* bash on every platform; the previous
SwiftBash default was unified-only, which differed from both.

### `shasum`

```bash
shasum -a 256 file.txt
                      # SwiftBash & macOS Perl shasum: works
                      # bash 3.2 alone:                shasum is a
                      #                                separate Perl tool
                      #                                that's usually present
```

SwiftBash registers `shasum` as a built-in, so it works in environments
where the Perl script isn't available.

---

## Network: `curl` and the deny-by-default allow-list

SwiftBash ships a `curl` built on `URLSession` that is gated by an
**allow-list policy** held on the shell. Default behaviour:

```bash
swift-bash exec script.sh                  # curl in script → exit 7, denied
```

To allow specific origins (modelled on just-bash's network design):

```bash
swift-bash exec --allow-url https://api.example.com \
                --allow-url https://api.openai.com \
                --allow-method POST \
                script.sh
```

**Allow-list rules** ([URLAllowList.swift](../Sources/BashInterpreter/Network/URLAllowList.swift)):
- Origin (scheme + host + port) must match exactly.
- Path-scoped entries (`https://api.example.com/v1/`) match on segment
  boundaries — `/v1/users` matches, `/v10` and `/v1-admin` do not.
- URLs containing `%2f` or `%5c` in the path are rejected when the
  matching entry is path-scoped (defends against encoded-separator
  bypass).

**Method gate** — defaults to `GET` and `HEAD`. POST / PUT / DELETE
need explicit `--allow-method`.

**Private-range guard** (`--deny-private`, on by default) — blocks
hostnames that are *or resolve to* private / loopback / link-local
IPs (127/8, 10/8, 172.16/12, 192.168/16, 169.254/16 incl. the AWS
metadata endpoint, 100.64/10 CGNAT, IPv6 ULAs/loopback/link-local,
IPv4-mapped private). The guard runs even when
`--dangerous-full-network` is set, so SSRF / DNS-rebinding remain
blocked even in trusted-script mode.

**Header transforms** for credential brokering — entries can carry
headers that get injected at the fetch boundary, so a script never
sees the API key:

```swift
let config = NetworkConfig(allowedURLPrefixes: [
    AllowedURLEntry(
        url: "https://gateway.example.com",
        transforms: [HeaderTransform(headers:
            ["Authorization": "Bearer SECRET"])])
])
shell.networkConfig = config
```

**Curl exit codes** map to curl's `CURLE_*`:

| Code | Meaning |
|---|---|
| 7  | URL not in allow-list / private IP / connection failure |
| 3  | invalid URL or method denied |
| 22 | HTTP 4xx/5xx with `-f` (`--fail`) |
| 28 | request timed out |
| 47 | too many redirects |
| 56 | response body exceeded `--max-response-size` |

Everything above goes through ``SecureFetcher`` — there is no second
network path that could bypass the policy. `--sandbox` (file-system
isolation) does **not** auto-enable network; you still have to pass
`--allow-url` explicitly. The two sandboxes are independent levers.

---

## Things SwiftBash does NOT do that bash does

For honesty:

- **Job control** — `bg`, `fg`, `jobs`, `kill %1`. Not implemented.
- **Background `&`** — runs *foreground* in SwiftBash (the `&` token
  parses but doesn't fork a real subprocess).
- **Real subprocess execution** — every command runs in-process as a
  registered Swift `Command`. We never call `Process` / `fork` / `exec`.
  This is intentional — SwiftBash targets sandboxed iOS/macOS apps
  where spawning subprocesses isn't allowed.
- **Process substitution that needs real fds** — `<(cmd)` / `>(cmd)`
  work via temp files instead of `/dev/fd/N`. The visible behaviour
  matches; performance for large streams may differ.

---

## How we test for divergence

A diff harness in `/tmp/sbx-test/run.sh` (created during development)
runs ~80 hand-written bash scripts under both `swift-bash exec` and
`/bin/bash` and reports exit-code or stdout differences. The script
catalogue covers parameter expansion, arrays, globbing, here-docs,
pipelines, traps, every standard command's flag set, and a battery
of integration scenarios derived from just-bash's vitest suite.

After the bash-4 conformance batch, the harness shows 71/80 — and
every one of the remaining 9 differences is a case where SwiftBash
matches modern bash while `/bin/bash` (3.2) doesn't.
