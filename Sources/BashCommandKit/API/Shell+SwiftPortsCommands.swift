import BashInterpreter

// Android: SwiftPorts' ArgumentParser-backed command surface is not a
// supported target there — its transitive C-library graph (libgit2, BoringSSL,
// the pkg-config-driven systemLibrary shims for zlib / lz4 / zstd / lzma / bz2)
// injects unconditional `-lz` / `-ldl` and host pkg-config search paths that
// break Bionic libc resolution. The `SwiftPortsCommands` product is gated to
// non-Android platforms in Package.swift; mirror that gate here so this file's
// import doesn't fail on Android. `sqlite3` is the exception — its
// ArgumentParser-free shell port installs everywhere, registered separately by
// `registerSqlite3()` (see `Shell+Sqlite3.swift`).
#if !os(Android)

import SwiftPortsCommands

extension Shell {

    /// Install every SwiftPorts CLI port as a Bash builtin (a virtual bin).
    ///
    /// SwiftPorts vends each port as a ready-to-install ShellKit ``Command`` —
    /// already bridged from its `AsyncParsableCommand` through ShellKit's own
    /// `ShellCommandKit`. This installer does **no** bridging of its own: it
    /// just places each command at its `BinCatalog` path. The command-building
    /// base lives in ShellKit, the ports in SwiftPorts; SwiftBash only installs.
    ///
    /// Every SwiftPorts CLI reads from / writes to ``ShellKit/Shell/current``
    /// rather than `FileHandle.standard*`, so the installed builtins
    /// participate fully in pipes / `<` `>` redirection / `$(...)` capture /
    /// background jobs — no `Process()` fork, no OS pipe per pipeline stage.
    ///
    /// Registered surface: `jq`, `gh`, `glab`, `git`, `rg`, `fd`, the archive
    /// family (`tar` / `zip` / `unzip`), and the gzip / bzip2 / xz / zstd / lz4
    /// compression families — each gated, in SwiftPorts, to the platforms whose
    /// underlying C library is available. `sqlite3` is installed separately by
    /// ``registerSqlite3()`` so it works on Android too.
    public func registerSwiftPortsCommands() {
        for command in SwiftPortsCommands.argumentParserCommands {
            install(command)
        }
    }
}

#endif // !os(Android)
