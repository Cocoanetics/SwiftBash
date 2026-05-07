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
/// - the host process's environment (copy) as `Shell.bashCurrent.environment`
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

    @Option(name: .long, parsing: .singleValue,
            help: ArgumentHelp(
                "Permit network access to URL prefixes matching this entry. "
                + "Origin-only (\"https://api.example.com\") allows all paths; "
                + "path-scoped (\"https://api.example.com/v1/\") matches at "
                + "segment boundaries. Repeatable. Without any --allow-url, "
                + "curl returns Network access denied."))
    var allowUrl: [String] = []

    @Option(name: .long, parsing: .singleValue,
            help: ArgumentHelp(
                "Permit an HTTP method beyond GET / HEAD. Repeatable. "
                + "Values: GET HEAD POST PUT DELETE PATCH OPTIONS."))
    var allowMethod: [String] = []

    @Option(name: .long,
            help: ArgumentHelp(
                "Cap response body size in bytes. Default 10 MiB."))
    var maxResponseSize: Int = 10 * 1024 * 1024

    @Flag(name: .long,
          inversion: .prefixedNo,
          help: ArgumentHelp(
            "Reject hostnames that resolve to private/loopback IPs "
            + "(SSRF / DNS-rebinding defence). Default: on."))
    var denyPrivate: Bool = true

    @Flag(name: .long,
          help: ArgumentHelp(
            "Bypass the URL allow-list entirely. DANGEROUS: use only "
            + "for trusted scripts. --deny-private still applies."))
    var dangerousFullNetwork: Bool = false

    @Argument(help: "Path to a bash script file.")
    var scriptPath: String

    @Argument(parsing: .captureForPassthrough,
              help: "Arguments passed to the script as $1 $2 ...")
    var scriptArgs: [String] = []

    func run() async throws {
        let source = try Self.readScript(at: scriptPath)

        // Sandbox mode: scrub every host-leaking source. Synthetic
        // identity, minimal env, overlay filesystem, deny-by-default
        // network. Non-sandbox mode: real host info + real env so the
        // user's own scripts behave the way they expect.
        let environment: Environment
        let fileSystem: FileSystem
        let hostInfo: HostInfo
        if let sandboxRoot = sandbox {
            do {
                fileSystem = try SandboxedOverlayFileSystem(.init(
                    root: sandboxRoot,
                    mountPoint: workspace))
            } catch let err as FileSystemError {
                throw CLIError("--sandbox: \(err.description)")
            }
            hostInfo = .synthetic
            var env = Environment.synthetic(hostInfo: hostInfo,
                                            workingDirectory: workspace)
            // The sandbox is the user's home: scripts running here
            // are the agent's "session", and the workspace IS where
            // their files live. This makes `cd` (no arg) and `~`
            // both land at the workspace, and gives `mktemp -t foo`
            // and similar HOME-relative idioms a sensible answer.
            env["HOME"] = workspace
            env["PWD"] = workspace
            env["TMPDIR"] = "/tmp"
            environment = env
        } else {
            fileSystem = RealFileSystem()
            hostInfo = .real()
            environment = Environment.current()
        }

        let shell = Shell(environment: environment, fileSystem: fileSystem)
        shell.hostInfo = hostInfo
        shell.registerStandardCommands()
        shell.scriptName = scriptPath
        shell.positionalParameters = scriptArgs

        // Configure network access. Defaults remain `nil` (deny-all)
        // unless the user passed at least one --allow-url, opted into
        // --dangerous-full-network, or set --max-response-size /
        // --no-deny-private alongside.
        let wantsNetwork = !allowUrl.isEmpty
            || dangerousFullNetwork
            || !allowMethod.isEmpty
        if wantsNetwork {
            var methods: Set<HTTPMethod> = [.GET, .HEAD]
            for raw in allowMethod {
                guard let m = HTTPMethod(rawValue: raw.uppercased()) else {
                    throw CLIError(
                        "--allow-method: unknown method '\(raw)'. "
                        + "Valid: \(HTTPMethod.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                methods.insert(m)
            }
            shell.networkConfig = NetworkConfig(
                allowedURLPrefixes: allowUrl.map { AllowedURLEntry($0) },
                allowedMethods: methods,
                dangerouslyAllowFullInternetAccess: dangerousFullNetwork,
                denyPrivateRanges: denyPrivate,
                maxResponseSize: maxResponseSize)
        }
        // Shell defaults already forward to FileHandle.standardOutput /
        // .standardError — no additional wiring needed.

        let status: ExitStatus
        do {
            status = try await shell.run(source)
        } catch let err as BashInterpreterError {
            throw CLIError(err.description)
        } catch let err as BashSyntaxError {
            throw CLIError(err.description)
        } catch is CancellationError {
            // Top-level cancel (rare; usually scoped to a job) → exit
            // with bash's 128 + SIGTERM convention.
            throw ExitCode(143)
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
