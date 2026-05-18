import ArgumentParser
import BashSyntax
import BashInterpreter
import BashCommandKit
import Foundation
import ShellKit

import BashSwiftScript

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

        let setup = try makeShellSetup()
        let shell = Shell(fileSystem: setup.fileSystem,
                          environment: setup.environment)
        shell.hostInfo = setup.hostInfo
        shell.sandbox = setup.urlSandbox
        shell.registerStandardCommands()
        // `#!/usr/bin/env swift-script` and `#!/usr/bin/env swift`
        // shebangs route through the in-process SwiftScript
        // interpreter, which reads its IO / FS / network / identity
        // through `Shell.current` — same surface the bash sandbox
        // and the registered SwiftPorts CLIs use.
        shell.registerSwiftScript()
        shell.scriptName = scriptPath
        shell.positionalParameters = scriptArgs

        try configureNetworkAccess(on: shell)
        // Shell defaults already forward to FileHandle.standardOutput /
        // .standardError — no additional wiring needed.

        let status = try await runScript(source: source, shell: shell)
        // Propagate the script's exit code back through ArgumentParser.
        throw ExitCode(status.code)
    }

    /// Bundle of host-facing state for the bound `Shell`. Sandbox vs.
    /// non-sandbox modes pick different sources for each field, but the
    /// downstream wiring is uniform — so the caller just unpacks one
    /// struct rather than juggling four parallel variables.
    private struct ShellSetup {
        let environment: Environment
        let fileSystem: FileSystem
        let hostInfo: HostInfo
        let urlSandbox: ShellKit.Sandbox?
    }

    /// Build the per-mode host-facing state. Sandbox mode: scrub every
    /// host-leaking source. Synthetic identity, minimal env, overlay
    /// filesystem, deny-by-default network. Non-sandbox mode: real host
    /// info + real env so the user's own scripts behave the way they
    /// expect.
    private func makeShellSetup() throws -> ShellSetup {
        guard let sandboxRoot = sandbox else {
            return ShellSetup(
                environment: Environment.current(),
                fileSystem: RealFileSystem(),
                hostInfo: .real(),
                urlSandbox: nil)
        }
        let fileSystem: FileSystem
        do {
            fileSystem = try SandboxedOverlayFileSystem(.init(
                root: sandboxRoot,
                mountPoint: workspace))
        } catch let err as FileSystemError {
            throw CLIError("--sandbox: \(err.description)")
        }
        let hostInfo = HostInfo.synthetic
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
        // ShellKit-side URL gate. Bash builtins consult the
        // `fileSystem` overlay above; ShellKit-aware bridges
        // (the registered SwiftPorts CLIs and the SwiftScript
        // interpreter) consult `Shell.sandbox` instead.
        // Bind the same physical root so both confinements stay
        // in lock-step and a `--sandbox` invocation actually
        // confines a Swift script the same way it confines a
        // bash one. Migration target (#10): retire the legacy
        // `fileSystem` overlay and have bash consult the URL
        // gate too.
        let urlSandbox = ShellKit.Sandbox.rooted(
            at: URL(fileURLWithPath: sandboxRoot),
            allowedHosts: [])
        return ShellSetup(
            environment: env,
            fileSystem: fileSystem,
            hostInfo: hostInfo,
            urlSandbox: urlSandbox)
    }

    /// Apply --allow-url / --allow-method / --dangerous-full-network /
    /// --deny-private / --max-response-size to `shell.networkConfig`.
    /// Defaults remain `nil` (deny-all) unless the user passed at
    /// least one --allow-url, opted into --dangerous-full-network, or
    /// set --max-response-size / --no-deny-private alongside.
    private func configureNetworkAccess(on shell: BashInterpreter.Shell) throws {
        let wantsNetwork = !allowUrl.isEmpty
            || dangerousFullNetwork
            || !allowMethod.isEmpty
        guard wantsNetwork else { return }
        var methods: Set<HTTPMethod> = [.GET, .HEAD]
        for raw in allowMethod {
            guard let method = HTTPMethod(rawValue: raw.uppercased()) else {
                throw CLIError(
                    "--allow-method: unknown method '\(raw)'. "
                    + "Valid: \(HTTPMethod.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            methods.insert(method)
        }
        shell.networkConfig = NetworkConfig(
            allowedURLPrefixes: allowUrl.map { AllowedURLEntry($0) },
            allowedMethods: methods,
            dangerouslyAllowFullInternetAccess: dangerousFullNetwork,
            denyPrivateRanges: denyPrivate,
            maxResponseSize: maxResponseSize)
    }

    /// Decide whether the source's first line names a registered
    /// ``ScriptInterpreter`` (e.g. `#!/usr/bin/env swift-script`).
    /// If so we run the script PATH as a bash command line so the
    /// shebang-dispatch fallthrough fires and routes the body to that
    /// interpreter. Otherwise feed the source to bash directly — bash,
    /// sh, dash, and any other shebang the bash interpreter handles
    /// natively (it strips the line itself).
    ///
    /// Stdin / `/dev/fd/N` shorthands always run as bash source —
    /// we already consumed the stream by reading `source`, so a
    /// re-read by the dispatcher would see EOF.
    private func shouldDispatchAsScript(source: String, shell: BashInterpreter.Shell) -> Bool {
        let isStreamPath = scriptPath == "-"
            || scriptPath == "/dev/stdin"
            || scriptPath.hasPrefix("/dev/fd/")
        guard !isStreamPath else { return false }
        let firstLine = source.split(separator: "\n", maxSplits: 1)
            .first.map(String.init) ?? ""
        guard let parsed = parseShebangLine(firstLine) else { return false }
        return shell.scriptInterpreters[parsed.interpreter] != nil
    }

    /// Run the script through the bound `Shell`, translating interpreter
    /// / syntax errors to `CLIError` and top-level cancellation to
    /// bash's `128 + SIGTERM` exit convention.
    private func runScript(source: String, shell: BashInterpreter.Shell) async throws -> ExitStatus {
        do {
            if shouldDispatchAsScript(source: source, shell: shell) {
                let resolved = shell.resolvePath(scriptPath)
                var line = Self.bashSingleQuote(resolved)
                for arg in scriptArgs {
                    line += " " + Self.bashSingleQuote(arg)
                }
                return try await shell.run(line)
            } else {
                return try await shell.run(source)
            }
        } catch let err as BashInterpreterError {
            throw CLIError(err.description)
        } catch let err as BashSyntaxError {
            throw CLIError(err.description)
        } catch is CancellationError {
            // Top-level cancel (rare; usually scoped to a job) → exit
            // with bash's 128 + SIGTERM convention.
            throw ExitCode(143)
        }
    }

    /// Wrap `s` in single quotes for a bash command line, escaping
    /// any embedded single quotes via the standard `'\''`
    /// close-then-reopen idiom. Used when synthesising a one-line
    /// invocation for shebang-dispatch routing — the path and each
    /// arg are quoted so spaces / shell metacharacters in them stay
    /// literal.
    private static func bashSingleQuote(_ str: String) -> String {
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                      let descriptor = Int32(path.dropFirst("/dev/fd/".count)) {
                let handle = FileHandle(fileDescriptor: descriptor,
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
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
