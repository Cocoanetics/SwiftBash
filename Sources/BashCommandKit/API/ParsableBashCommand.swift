import ArgumentParser
import BashInterpreter

/// A bash ``Command`` whose argv is parsed via
/// [Swift Argument Parser](https://github.com/apple/swift-argument-parser).
///
/// Conform to get typed `@Argument`, `@Option`, `@Flag` parsing plus
/// automatic `--help` / `--version` / validation for free:
///
/// ```swift
/// import ArgumentParser
/// import BashInterpreter
/// import BashCommandKit
///
/// struct Greet: ParsableBashCommand {
///     static let configuration = CommandConfiguration(
///         commandName: "greet",
///         abstract: "Print a friendly hello."
///     )
///
///     @Argument(help: "Who to greet.")
///     var name: String = "world"
///
///     @Flag(name: .shortAndLong, help: "Shout it.")
///     var loud: Bool = false
///
///     func execute() throws -> ExitStatus {
///         let msg = loud ? "HELLO \(name.uppercased())" : "hello \(name)"
///         Shell.bashCurrent.stdout(msg + "\n")
///         return .success
///     }
/// }
///
/// let shell = Shell()
/// shell.install(Greet.self)
/// try shell.run("greet --loud alice")    // → HELLO ALICE
/// ```
///
/// Implementations read shell state via ``Shell/current`` (the
/// task-local set by the dispatcher).
///
/// Registration uses the type (not an instance) so a fresh value is
/// parsed per invocation. The `commandName` in `configuration` is used
/// as the shell command name; when `configuration.commandName` is `nil`
/// the lowercased Swift type name is used as a fallback.
///
/// `--help` prints to the shell's stdout and exits with status 0.
/// `--version` does the same. Parse errors print to stderr with a
/// non-zero exit status (64, matching `EX_USAGE` on BSD).
public protocol ParsableBashCommand: ParsableCommand {
    /// Run this parsed command. Implementors read `@Argument` /
    /// `@Option` / `@Flag` properties and perform any work, returning
    /// the exit status. Reads shell state via ``Shell/current``.
    ///
    /// Mutating so assignments to `@Option var …` inside the body
    /// behave as expected.
    mutating func execute() async throws -> ExitStatus
}
