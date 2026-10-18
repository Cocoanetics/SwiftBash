import Foundation

// The default command surface. It lives outside the `Shell` class
// body, which SwiftLint caps at 250 lines.
extension Shell {

    /// Install SwiftBash's built-in command surface on this shell.
    /// Pure shell built-ins (`cd`, `export`, `eval`, …) go through
    /// ``installShellBuiltin(_:)``; hybrid commands (`echo`, `printf`,
    /// `pwd`, `test`, `[`, `true`, `false`, `wait`) install BOTH as a
    /// shell built-in (wins for bare invocation) AND as a file at
    /// their `BinCatalog` path (reachable via absolute path and
    /// surfaced by `which`); pure file-backed commands (`bash`, `sh`,
    /// `dash`) only install at their catalog path.
    ///
    /// Called automatically from the designated initializer when the
    /// caller-supplied `commands` dict is empty; tests / embedders
    /// that want a clean slate can clear the install storage after
    /// construction or pass a non-empty `commands` dict to opt out.
    public func installDefaultBuiltins() {
        // Pure shell built-ins: no file on disk, not PATH-searchable.
        let pureBuiltins: [Command] = [
            ColonCommand(),
            CdCommand(),
            ExportCommand(),
            UnsetCommand(),
            ExitCommand(),
            EvalCommand(),
            LetCommand(),
            ShoptCommand(),
            MapfileCommand(name: "mapfile"),
            MapfileCommand(name: "readarray"),
            BreakCommand(),
            ContinueCommand(),
            SetCommand(),
            ShiftCommand(),
            ReturnCommand(),
            LocalCommand(),
            SourceCommand(name: "source"),
            SourceCommand(name: "."),
            DeclareCommand(name: "declare"),
            DeclareCommand(name: "typeset"),
            ReadCommand(),
            TrapCommand(),
            GetoptsCommand(),
            CompgenCommand()
        ]
        for builtin in pureBuiltins {
            installShellBuiltin(builtin)
        }

        // Hybrid commands: a built-in wins for the bare name, and a
        // file form at the catalog path is reachable via absolute
        // invocation and via `which`. Both forms share the same Swift
        // implementation — real bash's file form is a separate binary,
        // but inside a virtualised shell the behaviour overlaps
        // closely enough that a single instance covers both.
        let hybrids: [Command] = [
            EchoCommand(),
            TrueCommand(),
            FalseCommand(),
            PwdCommand(),
            WaitCommand(),
            TestCommand(name: "test"),
            TestCommand(name: "["),
            PrintfCommand()
        ]
        for hybrid in hybrids {
            installShellBuiltin(hybrid)
            install(hybrid)
        }

        // File-only commands at their catalog paths.
        install(BashCommand(name: "bash"))
        install(BashCommand(name: "sh"))
        install(BashCommand(name: "dash"))
    }
}
