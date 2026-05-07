import BashInterpreter
import Bzip2Command
import GhCommand
import GitCommand
import GlabCommand
import GzipCommand
import JqCommand
import Lz4Command
import TarCommand
import UnzipCommand
import XzCommand
import ZipCommand
import ZstdCommand

extension Shell {

    /// Register every CLI that [SwiftPorts](https://github.com/Cocoanetics/SwiftPorts)
    /// ships as Bash builtins on this shell.
    ///
    /// Every SwiftPorts CLI is an `AsyncParsableCommand` whose body
    /// reads from / writes to ``ShellKit/Shell/current`` rather than
    /// `FileHandle.standard*`, so the registered builtins
    /// participate fully in pipes / `<` `>` redirection / `$(...)`
    /// capture / background jobs — no `Process()` fork, no OS pipe
    /// per pipeline stage. The shell binds itself onto
    /// `ShellKit.Shell.current` for every dispatch, so the routing
    /// is automatic.
    ///
    /// Registered surface (in order of likely-use):
    ///
    ///   • **`jq`** — pure-Swift JSON processor (full standard
    ///     surface incl. `--slurpfile` / `--rawfile` / `--args`).
    ///   • **`gh`** — GitHub CLI (`api`, `auth`, `pr`, `issue`,
    ///     `release`, `run`, `gist`, `project`, `repo`, …).
    ///   • **`glab`** — GitLab CLI (`mr`, `issue`, `ci`, `repo`,
    ///     `release`, `tag`, `variable`, `auth`, `api`).
    ///   • **`git`** — libgit2-backed `git` (full local-side
    ///     surface — clone, fetch, pull, push, log, status, diff,
    ///     stash, rebase, cherry-pick, branch, tag, remote, …).
    ///   • **Archives:** `tar`, `zip`, `unzip`.
    ///   • **Compression family:** `gzip`/`gunzip`/`zcat`,
    ///     `bzip2`/`bunzip2`/`bzcat`, `xz`/`unxz`/`xzcat`,
    ///     `zstd`/`unzstd`/`zstdcat`, `lz4`/`unlz4`/`lz4cat`.
    ///
    /// Per-binary personalities (`gunzip` / `zcat` / `bunzip2` /
    /// etc.) are separate `AsyncParsableCommand` types in
    /// SwiftPorts; we register each one individually so the bash
    /// `which` / `type` / `compgen -c` introspection sees them
    /// distinctly.
    public func registerSwiftPortsCommands() {
        // jq — JSON processor. Standalone-CLI surface, no
        // GitHub-style subcommand tree.
        register(Jq.self)

        // gh / glab / git — large multi-tool CLIs. Their
        // root command's `subcommands:` list pulls in the entire
        // subcommand tree automatically; registering the root
        // makes `gh issue list`, `glab mr view`, `git log`, etc.
        // all addressable as one builtin per top-level command.
        register(GhCommand.self)
        register(GlabCommand.self)
        register(GitCommand.self)

        // Archive family.
        register(TarCommand.self)
        register(ZipCommand.self)
        register(UnzipCommand.self)

        // Compression family — gzip personalities.
        register(Gzip.self)
        register(Gunzip.self)
        register(Zcat.self)

        // bzip2 personalities.
        register(Bzip2.self)
        register(Bunzip2.self)
        register(Bzcat.self)

        // xz personalities.
        register(Xz.self)
        register(Unxz.self)
        register(Xzcat.self)

        // zstd personalities.
        register(Zstd.self)
        register(Unzstd.self)
        register(Zstdcat.self)

        // lz4 personalities.
        register(Lz4.self)
        register(Unlz4.self)
        register(Lz4cat.self)
    }
}
