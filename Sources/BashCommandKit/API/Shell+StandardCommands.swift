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
    }
}
