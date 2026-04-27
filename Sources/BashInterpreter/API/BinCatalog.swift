import Foundation

/// Canonical "where this command would live on a real macOS system"
/// catalog. Drives two things:
///
/// 1. The synthesized `/bin` and `/usr/bin` listings every ``Shell``
///    exposes through ``VirtualBinFileSystem`` — `ls /bin` shows
///    exactly the commands a script can actually invoke.
/// 2. `which` / `type` / `command -v` output: a registered command
///    that has a catalog entry reports its path; one that doesn't
///    reports as a shell built-in.
///
/// The catalog is a static map of *known* command names. A command
/// only becomes visible under `/bin` (or `/usr/bin`) once it's
/// actually registered on the running ``Shell`` — registration is
/// the source of truth for "is this command available?", and the
/// catalog is the source of truth for "where would a real macOS
/// install it?".
///
/// Pure shell built-ins (`cd`, `export`, `exit`, `eval`, `let`,
/// `declare`, `read`, `trap`, `source`, …) have no entry here —
/// they don't appear as files on real systems either.
///
/// The catalog mirrors what a recent macOS ships under `/bin` and
/// `/usr/bin`. When a command is both a bash built-in *and* shipped
/// as a file on disk (`echo`, `printf`, `pwd`, `test`, `[`, `kill`,
/// `wait`, `true`, `false`), the file path wins — that matches what
/// `/usr/bin/which` reports on a real macOS system.
public enum BinCatalog {

    /// Map of command name → canonical absolute path. Names not in
    /// this map are treated as shell-only built-ins.
    public static let knownPaths: [String: String] = {
        var m: [String: String] = [:]

        // /bin — the small set of commands macOS keeps in /bin.
        for name in [
            "bash", "cat", "chmod", "cp", "dash", "date", "dd", "df",
            "echo", "expr", "hostname", "kill", "link", "ln", "ls",
            "mkdir", "mv", "ps", "pwd", "realpath", "rm", "rmdir",
            "sh", "sleep", "stty", "sync", "test", "[", "unlink",
        ] { m[name] = "/bin/\(name)" }

        // /usr/bin — everything else we ship that would normally be
        // installed there on macOS.
        for name in [
            "awk", "base64", "basename", "bc", "cmp", "column", "comm",
            "cut", "diff", "dirname", "du", "egrep", "env", "expand",
            "false", "fgrep", "find", "fold", "gunzip", "groups",
            "gzip", "head", "id", "join", "jq", "md5", "md5sum",
            "mktemp", "nl", "od", "paste", "patch", "pgrep", "pkill",
            "printenv", "printf", "readlink", "rev", "sed", "seq",
            "sha1sum", "sha256sum", "shasum", "sort", "split",
            "stat", "strings", "tac", "tail", "tar", "tee", "time",
            "timeout", "touch", "tr", "tree", "true", "truncate",
            "uname", "unexpand", "uniq", "wait", "wc", "which",
            "whoami", "xargs", "xattr", "xxd", "yes",
        ] { m[name] = "/usr/bin/\(name)" }

        // Third-party commonly-installed utilities (Homebrew /
        // user-installed). We slot them under /usr/local/bin so
        // their location matches the convention macOS users expect.
        for name in ["rg", "yq"] {
            m[name] = "/usr/local/bin/\(name)"
        }

        // `curl` ships at /usr/bin/curl on macOS.
        m["curl"] = "/usr/bin/curl"

        return m
    }()

    /// All directories that contain at least one entry. Drives the
    /// directory entries the synthetic FS exposes.
    public static let knownDirectories: Set<String> = {
        Set(knownPaths.values.map { ($0 as NSString).deletingLastPathComponent })
    }()

    /// Names registered at `path` if any — the inverse mapping used
    /// by ``VirtualBinFileSystem`` when listing a directory.
    public static func names(in directory: String) -> [String] {
        knownPaths.compactMap { (name, path) in
            (path as NSString).deletingLastPathComponent == directory
                ? name : nil
        }
    }
}
