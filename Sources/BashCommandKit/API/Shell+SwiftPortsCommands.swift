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

        // gzip personalities — zlib is universally available, no
        // platform gate.
        register(Gzip.self)
        register(Gunzip.self)
        register(Zcat.self)

        // bzip2 / zstd — libbz2 / libzstd aren't in the iOS /
        // tvOS / watchOS / visionOS SDK and aren't in Android's
        // NDK. SwiftPorts gates these command types behind
        // `#if os(macOS) || os(Linux) || os(Windows)`; mirror
        // that gate here.
        #if os(macOS) || os(Linux) || os(Windows)
        register(Bzip2.self)
        register(Bunzip2.self)
        register(Bzcat.self)

        register(Zstd.self)
        register(Unzstd.self)
        register(Zstdcat.self)
        #endif

        // xz / lz4 — Apple platforms back these via the
        // Compression framework (`canImport(Compression)`); Linux
        // / Windows have system liblzma / liblz4. Android has
        // neither. SwiftPorts gates the command types behind
        // `#if canImport(Compression) || os(Linux) || os(Windows)`;
        // mirror that.
        #if canImport(Compression) || os(Linux) || os(Windows)
        register(Xz.self)
        register(Unxz.self)
        register(Xzcat.self)

        register(Lz4.self)
        register(Unlz4.self)
        register(Lz4cat.self)
        #endif
    }
}

#endif // !os(Android)
