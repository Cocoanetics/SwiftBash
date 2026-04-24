import ArgumentParser
import BashSyntax
import BashInterpreter
import BashCommandKit
import Foundation

/// `swift-bash exec` — execute a bash script using the SwiftBash
/// interpreter, inheriting the current process environment and
/// forwarding stdout, stderr, and the exit status.
///
/// ```
/// swift-bash exec Examples/date-loop.sh
/// ```
///
/// The interpreter sees:
/// - the host process's environment (copy) as `shell.environment`
/// - `registerStandardCommands()` preloaded, so `cat`, `seq`, `sleep`,
///   `date`, `grep`, `wc`, `head`, etc. are all available
/// - stdout / stderr wired directly to the process's file handles so
///   output is live, not buffered by the CLI
///
/// The script's exit status is propagated via `ExitCode`, so shell
/// idioms like `if swift-bash exec foo.sh; then …` work correctly.
struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Execute a bash script via the SwiftBash interpreter."
    )

    @Argument(help: "Path to a bash script file.")
    var scriptPath: String

    func run() async throws {
        let source: String
        do {
            source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        } catch {
            throw CLIError(
                "could not read \(scriptPath): \(error.localizedDescription)"
            )
        }

        let shell = Shell(environment: .current())
        shell.registerStandardCommands()
        shell.stdout = { data in FileHandle.standardOutput.write(data) }
        shell.stderr = { data in FileHandle.standardError.write(data) }

        let status: ExitStatus
        do {
            status = try await shell.run(source)
        } catch let err as BashInterpreterError {
            throw CLIError(err.description)
        } catch let err as BashSyntaxError {
            throw CLIError(err.description)
        }
        // Propagate the script's exit code back through ArgumentParser.
        throw ExitCode(status.code)
    }
}
