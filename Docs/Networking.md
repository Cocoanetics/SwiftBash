# Networking

SwiftBash's `curl` is the single network entry point. It defaults to
**deny-all** — until the embedder explicitly populates an allow-list,
every fetch fails with `Network access denied: URL not in allow-list`
and exit status 7 (curl's `CURLE_COULDNT_CONNECT`).

## Configuring access

```swift
import BashInterpreter

shell.networkConfig = NetworkConfig(
    allowedURLPrefixes: [
        "https://api.github.com/repos/example/",
        "https://docs.example.com/",
    ],
    allowedMethods: ["GET", "POST"],
    denyPrivateIPs: true            // block 127/8, 10/8, 169.254/16, etc.
)
```

A request must match **all** of:

1. **Scheme** — only `http://` and `https://` are ever allowed.
2. **Method** — `Request.httpMethod` is in `allowedMethods` (default
   `["GET"]`).
3. **URL prefix** — the request URL has one of `allowedURLPrefixes`
   as a prefix, with **segment-boundary matching**:
   `https://example.com/api` matches `https://example.com/api/v1`
   but **not** `https://example.com/api-internal`.
4. **Encoding sanity** — URL contains no `%2f`, `%2F`, `%5c`, `%5C`
   (URL-encoded slash / backslash). These are rejected outright to
   block path-traversal and prefix-evasion attacks.
5. **Host class** — when `denyPrivateIPs == true`, the resolved IP
   must not be in any RFC-1918 / loopback / link-local range. DNS
   resolution happens before the policy check; spoofed hostnames
   (e.g. `evil.example.com → 127.0.0.1`) are caught.

## CLI flags

The `swift-bash exec` CLI surfaces the same configuration:

```bash
$ swift-bash exec \
    --allow-url https://api.github.com/repos/example/ \
    --allow-url https://docs.example.com/ \
    --allow-method GET --allow-method POST \
    --no-deny-private \                  # opt out of the private-IP guard
    script.sh

# Escape hatch (use with caution): unrestricted network.
$ swift-bash exec --dangerous-full-network script.sh
```

`--allow-url` is repeatable. `--dangerous-full-network` overrides
everything; pass it only when the script is fully trusted.

## What `curl` supports

| Flag                  | Behaviour                                            |
|-----------------------|------------------------------------------------------|
| `-X METHOD`           | HTTP method.                                         |
| `-d DATA` / `--data`  | Request body (auto-sets `Content-Type` form-encoded). |
| `-H 'Name: value'`    | Add a request header (repeatable).                   |
| `-o FILE`             | Write the body to FILE instead of stdout.            |
| `-O`                  | Save to a file named after the URL's basename.       |
| `-L`                  | Follow redirects (within the allow-list).            |
| `-s`                  | Silent — suppress progress meter.                    |
| `-i`                  | Include response headers in the output.              |
| `-I`                  | HEAD request; print just the response headers.       |
| `-w 'FORMAT'`         | Print extra info after the body (subset of curl's writes). |
| `--max-time N`        | Hard timeout in seconds.                             |
| `--user U:P`          | HTTP basic auth.                                     |

Returns curl-compatible exit codes: `0` success, `6` couldn't resolve
host, `7` couldn't connect (used for allow-list rejection too), `22`
HTTP error with `-f`, `28` timeout.

## Threat model recap

The allow-list is designed to defend against:

- **SSRF** — accidental fetches of internal services (`169.254.169.254`,
  `localhost`, `192.168.x.x`). Defended by `denyPrivateIPs`, with the
  resolution happening before the policy check.
- **Prefix evasion** — `https://example.com/api` granted but the script
  fetches `https://example.com/api-internal/admin`. Defended by
  segment-boundary matching.
- **Encoded-slash bypass** — `https://example.com/api%2f..%2fadmin`.
  Defended by rejecting `%2f`/`%2F`/`%5c`/`%5C` in the URL string.
- **Method-bypass** — script granted GET starts firing DELETE. Defended
  by `allowedMethods`.

It is **not** designed against:

- A network-level adversary on the host's path (use TLS pinning if needed).
- A misconfigured allow-list — `https://github.com/` allows access to
  any repo on github.com. Be specific in the prefixes.
