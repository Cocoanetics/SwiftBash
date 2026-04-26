import ArgumentParser
import BashInterpreter

extension Shell {

    /// Register a ``ParsableBashCommand`` type with this Shell.current. The
    /// command name comes from
    /// `Parsed.configuration.commandName`; if that's `nil`, the Swift
    /// type's lowercased name is used as a fallback.
    ///
    /// A fresh instance is parsed on every invocation — just like the
    /// Swift Argument Parser's own `main()` flow.
    public func register<Parsed: ParsableBashCommand>(_ type: Parsed.Type) {
        let name = Parsed.configuration.commandName
                ?? String(describing: type).lowercased()
        register(ParsableCommandBridge<Parsed>(name: name))
    }
}
