import BashInterpreter
import Sqlite3Shell

extension Shell {

    /// Register SwiftPorts' `sqlite3` shell port as a builtin at
    /// `/usr/bin/sqlite3` (where real macOS ships it).
    ///
    /// `Sqlite3Builtin` is SwiftPorts' ArgumentParser-free ShellKit ``Command``
    /// face of the `sqlite3` shell port (`Sqlite3Executable`). Because it
    /// carries no ArgumentParser it installs on every platform — Android
    /// included — unlike the rest of the SwiftPorts family
    /// (``registerSwiftPortsCommands()``, which is `#if !os(Android)`). It is
    /// therefore registered unconditionally, from ``registerStandardCommands()``.
    ///
    /// This installer adds nothing of its own: the command and all its behavior
    /// (argv parsing, dot-commands, the REPL, sandbox-authorized path handling,
    /// version reporting) live in SwiftPorts on ShellKit's command base.
    /// SwiftBash only installs it.
    ///
    /// `sqlite3` isn't in `BinCatalog`, so the explicit-path overload is used;
    /// the registry-driven `BinCatalogOverlay` then surfaces it under `/usr/bin`
    /// from this install alone, so `ls /usr/bin/sqlite3`, `[ -x … ]`, and
    /// tool-presence checks all succeed — not just `which sqlite3`.
    public func registerSqlite3() {
        install(Sqlite3Builtin(), at: "/usr/bin/sqlite3")
    }
}
