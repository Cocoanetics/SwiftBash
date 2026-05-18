import BashInterpreter

// Android: SwiftPorts is not yet a supported target — its transitive
// C-library graph (libgit2, BoringSSL, swift-archive, the
// pkg-config-driven systemLibrary shims for zlib / lz4 / zstd /
// lzma / bz2) injects unconditional `-lz` / `-ldl` and host
// pkg-config search paths that pull `/lib/x86_64-linux-gnu/` onto
// ld.lld's resolver, breaking Bionic libc symbol resolution. The
// SwiftPorts product references in Package.swift are gated to
// non-Android platforms; mirror that gate at the source level so
// this file's imports don't fail on Android. The companion call
// site in `Shell+StandardCommands.swift` is gated the same way.
#if !os(Android)

import Bzip2Command
import FdCommand
import GhCommand
import GitCommand
import GlabCommand
import GzipCommand
import JqCommand
import Lz4Command
import RgCommand
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
    ///   • **gzip family:** `gzip` / `gunzip` / `zcat` (always —
    ///     zlib is on every supported platform).
    ///   • **bzip2 / xz / zstd / lz4 families** — gated to the
    ///     platforms where the underlying C library is available.
    ///     The `#if` guards mirror the platform gates SwiftPorts'
    ///     own command targets carry, so this code compiles
    ///     identically on every supported OS.
    ///
    /// Per-binary personalities (`gunzip` / `zcat` / `bunzip2` /
    /// etc.) are separate `AsyncParsableCommand` types in
    /// SwiftPorts; we register each one individually so the bash
    /// `which` / `type` / `compgen -c` introspection sees them
    /// distinctly.
    public func registerSwiftPortsCommands() {
        // jq — JSON processor. Standalone-CLI surface, no
        // GitHub-style subcommand tree.
        install(Jq.self)

        // gh / glab / git — large multi-tool CLIs. Their
        // root command's `subcommands:` list pulls in the entire
        // subcommand tree automatically; registering the root
        // makes `gh issue list`, `glab mr view`, `git log`, etc.
        // all addressable as one builtin per top-level command.
        install(GhCommand.self)
        install(GlabCommand.self)
        install(GitCommand.self)

        // rg / fd — pure-Swift ports of BurntSushi's ripgrep and
        // sharkdp's fd. Supersede `BashCommandKit/Commands/RgCommand`
        // (whose `register(RgCommand.self)` call was dropped from
        // `registerStandardCommands()` for that reason). The new rg
        // honours `.gitignore` / `.ignore` / `.rgignore`, walks parent
        // dirs, supports `-F` fixed-string matching and
        // `--no-require-git`; fd reuses RipgrepKit's walker so its
        // gitignore semantics line up.
        //
        // RipgrepKit's command type is named `Rg` (not `RgCommand`) so
        // it doesn't collide with BashCommandKit's local
        // `Commands/RgCommand.swift` type — that local type still
        // ships for source compat. Use the explicit module-level type
        // here to make sure the SwiftPorts one is what gets registered.
        install(Rg.self)
        // `fd` isn't in the BinCatalog yet — slot under
        // `/usr/local/bin` to match the Homebrew / user-skill
        // convention used for the rest of the SwiftPorts surface.
        install(FdCommand.self, at: "/usr/local/bin/fd")

        // Archive family.
        install(TarCommand.self)
        install(ZipCommand.self)
        install(UnzipCommand.self)

        // gzip personalities — zlib is universally available, no
        // platform gate.
        install(Gzip.self)
        install(Gunzip.self)
        install(Zcat.self)

        // bzip2 / zstd — libbz2 / libzstd aren't in the iOS /
        // tvOS / watchOS / visionOS SDK and aren't in Android's
        // NDK. SwiftPorts gates these command types behind
        // `#if os(macOS) || os(Linux) || os(Windows)`; mirror
        // that gate here.
        #if os(macOS) || os(Linux) || os(Windows)
        install(Bzip2.self)
        install(Bunzip2.self)
        install(Bzcat.self)

        install(Zstd.self)
        install(Unzstd.self)
        install(Zstdcat.self)
        #endif

        // xz / lz4 — Apple platforms back these via the
        // Compression framework (`canImport(Compression)`); Linux
        // / Windows have system liblzma / liblz4. Android has
        // neither. SwiftPorts gates the command types behind
        // `#if canImport(Compression) || os(Linux) || os(Windows)`;
        // mirror that.
        #if canImport(Compression) || os(Linux) || os(Windows)
        install(Xz.self)
        install(Unxz.self)
        install(Xzcat.self)

        install(Lz4.self)
        install(Unlz4.self)
        install(Lz4cat.self)
        #endif
    }
}

#endif // !os(Android)
