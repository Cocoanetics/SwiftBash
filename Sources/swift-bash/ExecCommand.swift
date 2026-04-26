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

    @Option(name: .long,
            help: ArgumentHelp(
                "Confine the script to a sandboxed view of HOST_DIR. "
                + "The host directory is mounted at the virtual --workspace "
                + "path (default /batch); writes are kept in memory and "
                + "never touch disk. Paths outside the mount return ENOENT."))
    var sandbox: String?

    @Option(name: .long,
            help: "Virtual mount point for --sandbox. Default: /batch.")
    var workspace: String = "/batch"

    @Argument(help: "Path to a bash script file.")
    var scriptPath: String

    @Argument(parsing: .captureForPassthrough,
              help: "Arguments passed to the script as $1 $2 ...")
    var scriptArgs: [String] = []

    func run() async throws {
        let source = try Self.readScript(at: scriptPath)

        var environment = Environment.current()
        let fileSystem: FileSystem
        if let sandboxRoot = sandbox {
            do {
                fileSystem = try SandboxedOverlayFileSystem(.init(
                    root: sandboxRoot,
                    mountPoint: workspace))
            } catch let err as FileSystemError {
                throw CLIError("--sandbox: \(err.description)")
            }
            // Drop the host's PWD; the script sees only the virtual mount.
            environment.workingDirectory = workspace
            environment["PWD"] = workspace
            environment["OLDPWD"] = nil
            environment["TMPDIR"] = "/tmp"
        } else {
            fileSystem = RealFileSystem()
        }

        let shell = Shell(environment: environment, fileSystem: fileSystem)
        shell.registerStandardCommands()
        shell.scriptName = scriptPath
        shell.positionalParameters = scriptArgs
        // Shell defaults already forward to FileHandle.standardOutput /
        // .standardError — no additional wiring needed.

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

    /// Read script source from `path`. Handles three cases that
    /// `String(contentsOfFile:)` doesn't:
    ///
    /// - `-`, `/dev/stdin`, `/dev/fd/0` → `FileHandle.standardInput`
    /// - `/dev/fd/N` (N > 0) → open the matching fd directly so bash
    ///   process-substitution (`<(echo …)`) works
    /// - regular files / FIFOs / pipes → `FileHandle(forReadingAtPath:)`
    ///   uses `read(2)` and tolerates non-mappable kinds
    ///
    /// `String(contentsOfFile:)` memory-maps the path under the hood,
    /// which the kernel rejects for pipes, sockets, and other
    /// non-regular files — Foundation reports the rejection as a
    /// "permission denied" error, which is misleading.
    static func readScript(at path: String) throws -> String {
        let data: Data
        do {
            if path == "-" || path == "/dev/stdin" || path == "/dev/fd/0" {
                data = (try FileHandle.standardInput.readToEnd()) ?? Data()
            } else if path.hasPrefix("/dev/fd/"),
                      let fd = Int32(path.dropFirst("/dev/fd/".count)) {
                let handle = FileHandle(fileDescriptor: fd,
                                        closeOnDealloc: false)
                data = (try handle.readToEnd()) ?? Data()
            } else {
                guard let handle = FileHandle(forReadingAtPath: path) else {
                    throw CLIError("could not read \(path): no such file")
                }
                defer { try? handle.close() }
                data = (try handle.readToEnd()) ?? Data()
            }
        } catch let err as CLIError {
            throw err
        } catch {
            throw CLIError(
                "could not read \(path): \(error.localizedDescription)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
