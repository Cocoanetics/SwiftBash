import BashInterpreter

extension Shell {

    /// Register every command shipped with `BashCommandKit` on this shell.
    ///
    /// **Filesystem & navigation:** `ls`, `mkdir`, `rmdir`, `rm`, `mv`,
    /// `cp`, `touch`, `find`, `realpath`, `basename`, `dirname`.
    ///
    /// **Reading & writing:** `cat`, `tee`, `head`, `tail`, `nl`, `tac`,
    /// `rev`, `wc`.
    ///
    /// **Searching:** `grep`, `fgrep`, `egrep`, `rg`, `find`.
    ///
    /// **Text manipulation:** `sed`, `sort`, `uniq`, `tr`, `cut`,
    /// `paste`, `comm`.
    ///
    /// **Encoding & hashing:** `base64`, `md5`, `md5sum`, `sha1sum`,
    /// `sha256sum`, `xxd`, `od`.
    ///
    /// **Introspection / shell-state:** `which`, `type`, `command`,
    /// `env`, `printenv`, `whoami`, `hostname`, `clear`.
    ///
    /// **Misc:** `date`, `seq`, `sleep`.
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
        register(TrCommand.self)
        register(CutCommand.self)
        register(Base64Command.self)
        register(Md5Command.self)
        register(XxdCommand.self)

        // Easy-batch additions
        register(ClearCommand.self)
        register(TacCommand.self)
        register(RevCommand.self)
        register(RmdirCommand.self)
        register(TeeCommand.self)
        register(PasteCommand.self)
        register(CommCommand.self)
        register(WhichCommand.self)
        register(TypeCommand.self)
        register(CommandBuiltinCommand.self)
        register(PrintenvCommand.self)
        register(OdCommand.self)
        register(Md5sumCommand.self)
        register(Sha1sumCommand.self)
        register(Sha256sumCommand.self)
        register(DiffCommand.self)
        register(GzipCommand.self)
        register(GunzipCommand.self)
        register(JqCommand.self)
        register(AwkCommand.self)
        register(ExprCommand.self)
        register(XargsCommand.self)
        register(SplitCommand.self)
        register(JoinCommand.self)
        register(ExpandCommand.self)
        register(UnexpandCommand.self)
        register(FoldCommand.self)
        register(StatCommand.self)
        register(ReadlinkCommand.self)
        register(LnCommand.self)
        register(ChmodCommand.self)
        register(TreeCommand.self)
        register(StringsCommand.self)
        register(ColumnCommand.self)

        // fgrep / egrep are thin grep aliases. Resolve `grep` from the
        // *running* shell rather than capturing the registering shell —
        // works correctly inside subshells too, and avoids reference
        // cycles on closure capture.
        register(name: "egrep") { argv, shell in
            guard let grep = shell.commands["grep"] else {
                shell.stderr("egrep: grep not registered\n")
                return .failure
            }
            return try await grep.run(["grep", "-E"]
                + Array(argv.dropFirst()), shell: shell)
        }
        register(name: "fgrep") { argv, shell in
            // We don't have grep -F yet; substring is grep's default
            // matching mode anyway, so this is effectively a name alias.
            // When -F lands later, prepend it here.
            guard let grep = shell.commands["grep"] else {
                shell.stderr("fgrep: grep not registered\n")
                return .failure
            }
            return try await grep.run(["grep"]
                + Array(argv.dropFirst()), shell: shell)
        }
    }
}
