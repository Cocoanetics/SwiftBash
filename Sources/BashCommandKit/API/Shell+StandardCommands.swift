import BashInterpreter

extension Shell {

    /// Register every command shipped with `BashCommandKit` on this shell:
    ///
    /// - `date` — ``DateCommand``
    /// - `basename` — ``BasenameCommand``
    /// - `dirname` — ``DirnameCommand``
    /// - `realpath` — ``RealpathCommand``
    /// - `seq` — ``SeqCommand``
    /// - `sleep` — ``SleepCommand``
    /// - `env` — ``EnvCommand``
    /// - `whoami` — ``WhoamiCommand``
    /// - `hostname` — ``HostnameCommand``
    /// - `cat` — ``CatCommand``
    /// - `wc` — ``WcCommand``
    /// - `head` — ``HeadCommand``
    /// - `tail` — ``TailCommand``
    /// - `nl` — ``NlCommand``
    /// - `grep` — ``GrepCommand``
    /// - `ls` — ``LsCommand``
    /// - `mkdir` — ``MkdirCommand``
    /// - `rm` — ``RmCommand``
    /// - `mv` — ``MvCommand``
    /// - `cp` — ``CpCommand``
    /// - `touch` — ``TouchCommand``
    /// - `find` — ``FindCommand``
    /// - `sort` — ``SortCommand``
    /// - `uniq` — ``UniqCommand``
    /// - `sed` — ``SedCommand``
    /// - `rg` — ``RgCommand``
    ///
    /// Individual commands can still be registered à la carte via
    /// ``register(_:)-<…>``; this is just the convenient one-call form.
    public func registerStandardCommands() {
        register(DateCommand.self)
        register(BasenameCommand.self)
        register(DirnameCommand.self)
        register(RealpathCommand.self)
        register(SeqCommand.self)
        register(SleepCommand.self)
        register(EnvCommand.self)
        register(WhoamiCommand.self)
        register(HostnameCommand.self)
        register(CatCommand.self)
        register(WcCommand.self)
        register(HeadCommand.self)
        register(TailCommand.self)
        register(NlCommand.self)
        register(GrepCommand.self)
        register(LsCommand.self)
        register(MkdirCommand.self)
        register(RmCommand.self)
        register(MvCommand.self)
        register(CpCommand.self)
        register(TouchCommand.self)
        register(FindCommand())
        register(SortCommand.self)
        register(UniqCommand.self)
        register(SedCommand.self)
        register(RgCommand.self)
    }
}
