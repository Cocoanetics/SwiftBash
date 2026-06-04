import BashInterpreter
import Sqlite3Shell

extension Shell {

    /// Register `sqlite3` — SwiftPorts' SQLite shell port — as a builtin.
    ///
    /// Unlike the rest of the SwiftPorts CLI family (`jq` / `gh` / `git` /
    /// the archive + compression set), which ``registerSwiftPortsCommands()``
    /// installs from ArgumentParser-based `*Command` products and which are
    /// dropped on Android, `sqlite3` is driven through the
    /// ArgumentParser-free ``Sqlite3Shell/Sqlite3Executable`` via a native
    /// ShellKit ``Command``. That target builds on every platform, so this
    /// builtin works everywhere — Android included. It is therefore
    /// registered unconditionally from ``registerStandardCommands()``,
    /// outside the `#if !os(Android)` gate the rest of the family sits behind.
    ///
    /// The driver reads/writes through ``Shell/current`` (stdin / stdout /
    /// stderr) and resolves + authorizes database / `.read` / `.backup`
    /// paths through the host sandbox, so the builtin participates fully in
    /// pipes / `<` `>` redirection / `$(...)` capture, exactly like the
    /// bridged ones.
    ///
    /// Installed at `/usr/bin/sqlite3` (where real macOS ships it); it isn't
    /// in `BinCatalog`, so the explicit-path overload is used. The
    /// registry-driven `BinCatalogOverlay` surfaces it under `/usr/bin` from
    /// this install alone, so `ls /usr/bin/sqlite3`, `[ -x … ]`, and
    /// tool-presence checks all succeed — not just `which sqlite3`.
    public func registerSqlite3() {
        install(Sqlite3Builtin(), at: "/usr/bin/sqlite3")
    }
}

/// Bridges SwiftPorts' ``Sqlite3Shell/Sqlite3Executable`` (the
/// ArgumentParser-free `sqlite3` driver) to a ShellKit ``Command``.
///
/// The whole argv is handed to the driver, which does SQLite's single-dash
/// long-option parsing (`-csv`, `-header`, `-separator X`, …), dot-command
/// dispatch, and the REPL itself — no ArgumentParser involved, so this
/// compiles and runs on Android where the `Sqlite3` `AsyncParsableCommand`
/// wrapper can't. The bridged ``AsyncParsableCommandBridge`` it replaces was
/// pure passthrough for this command anyway (the `Sqlite3` type captures
/// argv with `.captureForPassthrough` and forwards it verbatim), so behavior
/// is unchanged on the platforms that had it.
struct Sqlite3Builtin: Command {
    let name = "sqlite3"

    func run(_ argv: [String]) async throws -> ExitStatus {
        // `Sqlite3Executable` expects argv without the command name, per the
        // `execve` convention `ArgumentParserBridge.dispatch` also follows.
        let args = Array(argv.dropFirst())

        // Uniform GNU-style `--version` banner, matching
        // `ArgumentParserBridge.dispatch` (the path the other builtins take).
        // `sqlite3 -version` (single dash, the spelling real sqlite3 uses)
        // is left to the driver, which reports the SQLite library version.
        if args.first == "--version" {
            Shell.bashCurrent.stdout(
                "sqlite3 (SwiftBash) \(SwiftBashVersion.packageVersion)\n")
            return .success
        }

        let code = try await Sqlite3Executable.run(
            argv: args,
            stdin: Shell.current.stdin,
            stdout: Shell.current.stdout,
            stderr: Shell.current.stderr)
        return ExitStatus(code)
    }
}
