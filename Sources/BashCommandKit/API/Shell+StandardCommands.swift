import BashInterpreter

extension Shell {

    // Register every command shipped with `BashCommandKit` on this Shell.
    //
    // **Filesystem & navigation:** `ls`, `mkdir`, `rmdir`, `rm`, `mv`,
    // `cp`, `touch`, `find`, `realpath`, `basename`, `dirname`.
    //
    // **Reading & writing:** `cat`, `tee`, `head`, `tail`, `nl`, `tac`,
    // `rev`, `wc`.
    //
    // **Searching:** `grep`, `fgrep`, `egrep`, `rg`, `find`.
    //
    // **Text manipulation:** `sed`, `sort`, `uniq`, `tr`, `cut`,
    // `paste`, `comm`.
    //
    // **Encoding & hashing:** `base64`, `md5`, `md5sum`, `sha1sum`,
    // `sha256sum`, `xxd`, `od`.
    //
    // **Introspection / shell-state:** `which`, `type`, `command`,
    // `env`, `printenv`, `whoami`, `hostname`, `clear`.
    //
    // **Misc:** `date`, `seq`, `sleep`.
    //
    // Individual commands can still be registered à la carte via
    // ``install(_:)``; this is just the convenient one-call form.
    //
    // Single flat registration list; splitting by category would scatter
    // sibling commands across multiple files and add cross-file plumbing
    // for no gain.
    // swiftlint:disable:next function_body_length
    public func registerStandardCommands() {
        install(DateCommand.self)
        install(BasenameCommand.self)
        install(DirnameCommand.self)
        install(RealpathCommand.self)
        install(SeqCommand.self)
        install(SleepCommand.self)
        install(EnvCommand.self)
        install(WhoamiCommand.self)
        install(HostnameCommand.self)
        install(CatCommand.self)
        install(WcCommand.self)
        install(HeadCommand.self)
        install(TailCommand.self)
        install(NlCommand.self)
        // `grep` itself isn't in `BinCatalog.knownPaths` (only egrep
        // / fgrep are), but real macOS ships it at `/usr/bin/grep`.
        // Use the explicit-path overload to match.
        install(GrepCommand.self, at: "/usr/bin/grep")
        install(LsCommand.self)
        install(MkdirCommand.self)
        install(RmCommand.self)
        install(MvCommand.self)
        install(CpCommand.self)
        install(TouchCommand.self)
        install(FindCommand())
        install(SortCommand.self)
        install(UniqCommand.self)
        install(SedCommand.self)
        // `rg` is now sourced from SwiftPorts' RipgrepKit, registered
        // in `registerSwiftPortsCommands()` — that one honours
        // `.gitignore`, supports `-F`, and walks parent dirs, none of
        // which this local `RgCommand` (in BashCommandKit/Commands/)
        // does. Type still ships for source-compat; the builtin
        // registration moved.
        install(TrCommand.self)
        install(CutCommand.self)
        install(Base64Command.self)
        install(Md5Command.self)
        install(XxdCommand.self)

        // Easy-batch additions
        install(ClearCommand.self)
        install(TacCommand.self)
        install(RevCommand.self)
        install(RmdirCommand.self)
        install(TeeCommand.self)
        install(PasteCommand.self)
        install(CommCommand.self)
        install(WhichCommand.self)
        // `type` and `command` are real bash built-ins (no file at
        // `/usr/bin/type` or `/usr/bin/command` on macOS). Install
        // them in the shell-built-in bucket so they win over PATH
        // for bare invocations and are correctly absent from
        // `which type` output.
        installShellBuiltin(TypeCommand.self)
        installShellBuiltin(CommandBuiltinCommand.self)
        install(PrintenvCommand.self)
        install(OdCommand.self)
        install(Md5sumCommand.self)
        install(Sha1sumCommand.self)
        install(Sha256sumCommand.self)
        install(ShasumCommand.self)
        install(CurlCommand.self)
        install(DiffCommand.self)
        // GzipCommand / GunzipCommand removed — SwiftPorts'
        // [Gzip](https://github.com/Cocoanetics/SwiftPorts/blob/main/Sources/GzipKit/GzipCommand/GzipCommand.swift)
        // / [Gunzip](https://github.com/Cocoanetics/SwiftPorts/blob/main/Sources/GzipKit/GzipCommand/GzipCommand.swift)
        // / Zcat / Bzip2 / Xz / Zstd / Lz4 are registered via
        // ``registerSwiftPortsCommands()`` instead.
        // JqCommand is registered via ``registerSwiftPortsCommands()`` —
        // SwiftPorts'
        // [Jq](https://github.com/Cocoanetics/SwiftPorts/blob/main/Sources/JqKit/JqCommand/JqCommand.swift)
        // is the source-of-truth jq builtin now.
        install(AwkCommand.self)
        install(ExprCommand.self)
        install(XargsCommand.self)
        install(SplitCommand.self)
        install(JoinCommand.self)
        install(ExpandCommand.self)
        install(UnexpandCommand.self)
        install(FoldCommand.self)
        install(StatCommand.self)
        install(ReadlinkCommand.self)
        install(LnCommand.self)
        install(ChmodCommand.self)
        install(TreeCommand.self)
        install(StringsCommand.self)
        install(ColumnCommand.self)
        install(YqCommand.self)
        install(DuCommand.self)
        install(TimeCommand())
        install(TimeoutCommand())
        // TarCommand removed — SwiftPorts'
        // [TarCommand](https://github.com/Cocoanetics/SwiftPorts/blob/main/Sources/TarKit/TarCommand/TarCommand.swift)
        // is registered via ``registerSwiftPortsCommands()`` instead.
        install(UnameCommand.self)
        install(IdCommand.self)
        install(DfCommand.self)
        install(CmpCommand.self)
        install(BcCommand.self)
        install(XattrCommand.self)
        install(PatchCommand.self)
        install(PsCommand.self)
        install(KillCommand.self)
        install(PgrepCommand.self)
        install(PkillCommand.self)

        // Small POSIX utilities — easy wins on the FileSystem layer.
        install(MktempCommand.self)
        install(TruncateCommand.self)
        install(GroupsCommand.self)
        install(LinkCommand.self)
        install(UnlinkCommand.self)
        install(YesCommand.self)

        // Pagers. They request a host-side scrollable view via
        // ``Shell/interactivePresenter`` when one is installed and
        // stdout is interactive; otherwise they cat content through,
        // matching real `less(1)` / `more(1)` on a non-TTY.
        install(LessCommand.self)
        install(MoreCommand.self)

        // The SwiftPorts CLI family — gh / glab / git / jq / tar /
        // zip / unzip / the gzip+bzip2+xz+zstd+lz4 compression
        // family. Registered here so a single
        // `registerStandardCommands()` call lights up everything
        // SwiftBash ships out of the box.
        //
        // Android: SwiftPorts' transitive C-library graph (libgit2,
        // BoringSSL, swift-archive, the systemLibrary pkg-config
        // shims for zlib / liblz4 / libzstd / liblzma / libbz2) emits
        // unconditional `-lz` / `-ldl` and host-pkg-config search
        // paths that bleed `/lib/x86_64-linux-gnu/` into ld.lld's
        // resolver, breaking Bionic libc symbol resolution at link
        // time. Until SwiftPorts ships proper Android gates, skip
        // the registration on Android — the SwiftPorts product
        // dependencies are also platform-gated in Package.swift so
        // these modules don't even compile here.
        #if !os(Android)
        registerSwiftPortsCommands()
        #endif

        // sqlite3 — registered unconditionally (Android included). It drives
        // SwiftPorts' ArgumentParser-free `Sqlite3Shell` via a native
        // ShellKit command rather than the Android-dropped `*Command`
        // layer, so it builds and runs on every platform. See
        // `Shell+Sqlite3.swift`.
        registerSqlite3()

        // fgrep / egrep are thin grep aliases. Resolve `grep` from the
        // *running* shell rather than capturing the registering shell —
        // works correctly inside subshells too, and avoids reference
        // cycles on closure capture.
        install(name: "egrep") { argv in
            guard let grep = Shell.bashCurrent.commands["grep"] else {
                Shell.bashCurrent.stderr("egrep: grep not registered\n")
                return .failure
            }
            return try await grep.run(["grep", "-E"]
                + Array(argv.dropFirst()))
        }
        install(name: "fgrep") { argv in
            // We don't have grep -F yet; substring is grep's default
            // matching mode anyway, so this is effectively a name alias.
            // When -F lands later, prepend it here.
            guard let grep = Shell.bashCurrent.commands["grep"] else {
                Shell.bashCurrent.stderr("fgrep: grep not registered\n")
                return .failure
            }
            return try await grep.run(["grep"]
                + Array(argv.dropFirst()))
        }
    }
}
