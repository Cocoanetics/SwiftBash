import ArgumentParser
import BashInterpreter

extension Shell {

    /// Install a ``ParsableBashCommand`` type as a file-backed command
    /// at its `BinCatalog` default path. Traps if the type's
    /// `commandName` has no catalog entry — use ``install(_:at:)`` for
    /// off-catalog commands or ``installShellBuiltin(_:)`` for pure
    /// shell built-ins.
    ///
    /// The command name comes from
    /// `Parsed.configuration.commandName`; if that's `nil`, the Swift
    /// type's lowercased name is used as a fallback. A fresh instance
    /// is parsed on every invocation — same flow as the Swift Argument
    /// Parser's own `main()`.
    public func install<Parsed: ParsableBashCommand>(_ type: Parsed.Type) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        install(ParsableCommandBridge<Parsed>(name: name))
    }

    /// Install a ``ParsableBashCommand`` type at an explicit absolute
    /// path — bypasses the `BinCatalog` default lookup.
    public func install<Parsed: ParsableBashCommand>(
        _ type: Parsed.Type, at path: String
    ) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        install(ParsableCommandBridge<Parsed>(name: name), at: path)
    }

    /// Install a ``ParsableBashCommand`` type as a pure shell built-in
    /// — no path, not PATH-searchable, wins over PATH for the bare
    /// name.
    public func installShellBuiltin<Parsed: ParsableBashCommand>(
        _ type: Parsed.Type
    ) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        installShellBuiltin(ParsableCommandBridge<Parsed>(name: name))
    }

    // MARK: - AsyncParsableCommand overloads

    /// Install an ``AsyncParsableCommand`` type — the shape SwiftPorts
    /// CLIs (`Jq`, `Rg`, `GhCommand`, `TarCommand`, the compression
    /// family) use — at its `BinCatalog` default path.
    public func install<Parsed: AsyncParsableCommand>(
        _ type: Parsed.Type
    ) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        install(AsyncParsableCommandBridge<Parsed>(name: name))
    }

    /// Install an ``AsyncParsableCommand`` type at an explicit
    /// absolute path.
    public func install<Parsed: AsyncParsableCommand>(
        _ type: Parsed.Type, at path: String
    ) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        install(AsyncParsableCommandBridge<Parsed>(name: name), at: path)
    }

    /// Install an ``AsyncParsableCommand`` type as a pure shell built-in.
    public func installShellBuiltin<Parsed: AsyncParsableCommand>(
        _ type: Parsed.Type
    ) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        installShellBuiltin(AsyncParsableCommandBridge<Parsed>(name: name))
    }
}
