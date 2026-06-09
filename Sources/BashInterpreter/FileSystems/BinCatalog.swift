import Foundation

/// Canonical "where this command would live on a real macOS system"
/// catalog, owned by `BashInterpreter`.
///
/// Two consumers, both in this module:
///
/// 1. ``Shell/install(_:)`` (the bare, catalog-default overload) reads
///    a command's canonical install path from ``knownPaths``.
/// 2. ``BinCatalogOverlay`` takes the *directory geometry* of the
///    synthetic `/bin`, `/usr/bin`, and `/usr/local/bin` from
///    ``knownDirectories``. The *files* inside those directories come
///    from the live command registry (``Shell/commandsByPath``), not
///    from this map — so a command shows up wherever it's actually
///    installed, cataloged or not.
///
/// The catalog is a static map of *known* command names → canonical
/// absolute path. Names not in the map are treated as shell-only
/// built-ins (`cd`, `export`, `eval`, …) — they have no file on disk.
///
/// It mirrors what a recent macOS ships under `/bin` and `/usr/bin`.
/// When a command is both a bash built-in *and* a file on disk
/// (`echo`, `printf`, `pwd`, `test`, `[`, `kill`, `wait`, `true`,
/// `false`), the file path wins — matching what `/usr/bin/which`
/// reports on a real macOS system.
enum BinCatalog {

    /// Map of command name → canonical absolute path. Names not in
    /// this map are treated as shell-only built-ins.
    static let knownPaths: [String: String] = {
        var paths: [String: String] = [:]

        // /bin — the small set of commands macOS keeps in /bin.
        for name in [
            "bash", "cat", "chmod", "cp", "dash", "date", "dd", "df",
            "echo", "expr", "hostname", "kill", "link", "ln", "ls",
            "mkdir", "mv", "ps", "pwd", "realpath", "rm", "rmdir",
            "sh", "sleep", "stty", "sync", "test", "[", "unlink"
        ] { paths[name] = "/bin/\(name)" }

        // /usr/bin — everything else we ship that would normally be
        // installed there on macOS. The trailing group (`clear`,
        // `open`, `pbcopy`, `pbpaste`, `say`) are macOS-specific
        // tools; embedders register them through their own platform
        // shim (iBash's `AppleBuiltins`) but the canonical install
        // location is `/usr/bin` on real macOS, so listings here
        // match what users see on their host.
        for name in [
            "awk", "base64", "basename", "bc", "cmp", "column", "comm",
            "cut", "diff", "dirname", "du", "egrep", "env", "expand",
            "false", "fgrep", "find", "fold", "gunzip", "groups",
            "gzip", "head", "id", "join", "jq", "less", "md5", "md5sum",
            "mktemp", "more", "nl", "od", "paste", "patch", "pgrep", "pkill",
            "printenv", "printf", "readlink", "rev", "sed", "seq",
            "sha1sum", "sha256sum", "shasum", "sort", "split",
            "stat", "strings", "tac", "tail", "tar", "tee", "time",
            "timeout", "touch", "tr", "tree", "true", "truncate",
            "uname", "unexpand", "uniq", "wait", "wc", "which",
            "whoami", "xargs", "xattr", "xxd", "yes",
            "clear", "open", "pbcopy", "pbpaste", "say"
        ] { paths[name] = "/usr/bin/\(name)" }

        // Third-party commonly-installed utilities (Homebrew /
        // user-installed). We slot them under /usr/local/bin so
        // their location matches the convention macOS users expect.
        for name in [
            "rg", "fd", "yq",
            // SwiftPorts CLI surface — git/gh/glab and the
            // compression family ship via the BashCommandKit /
            // SwiftPorts registration, but `which` and `compgen -c`
            // still need a canonical path entry to find them.
            "git", "gh", "glab",
            "zip", "unzip",
            "bzip2", "bunzip2", "bzcat",
            "zstd", "unzstd", "zstdcat",
            "xz", "unxz", "xzcat",
            "lz4", "unlz4", "lz4cat", "zcat",
            // In-process script interpreters. Both routes work —
            // `swift-js hello.js` finds the closure command in
            // `shell.commands`, and `#!/usr/bin/env swift-js` finds
            // the matching ``ScriptInterpreter`` — and they share
            // backing logic. The catalog entry is here so
            // `which swift-js` reports `/usr/local/bin/swift-js`
            // rather than dropping back to "not found".
            "swift", "swift-script", "swift-js", "node", "bun"
        ] {
            paths[name] = "/usr/local/bin/\(name)"
        }

        // Embedder-supplied CLIs that ship as primary system tools
        // belong in /usr/bin alongside `awk`, `sed`, `find`, etc.
        // Whether `coder` actually surfaces in `ls /usr/bin` depends
        // on whether the host shell registers it; this entry just
        // declares where it WOULD live on a hypothetical "real"
        // install.
        paths["coder"] = "/usr/bin/coder"

        // `curl` ships at /usr/bin/curl on macOS.
        paths["curl"] = "/usr/bin/curl"

        return paths
    }()

    /// All directories that contain at least one entry. Drives the
    /// directory geometry the synthetic FS overlay exposes.
    static let knownDirectories: Set<String> = {
        Set(knownPaths.values.map { ($0 as NSString).deletingLastPathComponent })
    }()
}
