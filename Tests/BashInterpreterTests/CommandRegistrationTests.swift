import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct CommandRegistrationTests {

    // MARK: Closure-based

    @Test func registerClosureCommand() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "greet") { argv in
            let who = argv.dropFirst().first ?? "world"
            Shell.bashCurrent.stdout("hello \(who)\n")
            return .success
        }
        try await cap.shell.run("greet oliver")
        #expect(cap.stdout == "hello oliver\n")
    }

    @Test func closureCommandCanFail() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "nope") { _ in .failure }
        let status = try await cap.shell.run("nope")
        #expect(status == .failure)
        #expect(cap.shell.lastExitStatus == .failure)
    }

    @Test func closureCommandCanThrow() async {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "boom") { _ in
            throw BashInterpreterError.io("kaboom")
        }
        let err = await #expect(throws: BashInterpreterError.self) {
            try await cap.shell.run("boom")
        }
        #expect(err == .io("kaboom"))
    }

    @Test func closureCommandMutatesEnvironment() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "bless") { argv in
            for arg in argv.dropFirst() { Shell.bashCurrent.environment[arg] = "ok" }
            return .success
        }
        try await cap.shell.run("bless A B C")
        #expect(cap.shell.environment["A"] == "ok")
        #expect(cap.shell.environment["B"] == "ok")
        #expect(cap.shell.environment["C"] == "ok")
    }

    // MARK: Struct-based

    @Test func registerStructCommand() async throws {
        struct UpperCaseCommand: Command {
            let name = "upper"
            func run(_ argv: [String]) async throws -> ExitStatus {
                let out = argv.dropFirst().joined(separator: " ").uppercased()
                Shell.bashCurrent.stdout(out + "\n")
                return .success
            }
        }
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(UpperCaseCommand())
        try await cap.shell.run("upper hello world")
        #expect(cap.stdout == "HELLO WORLD\n")
    }

    // MARK: Unregister / override

    @Test func uninstallRemovesCommand() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "once") { _ in
            Shell.bashCurrent.stdout("first\n"); return .success
        }
        try await cap.shell.run("once")
        #expect(cap.stdout == "first\n")

        let removed = cap.shell.uninstall(name: "once")
        #expect(removed >= 1)

        try await cap.shell.run("once")
        #expect(cap.shell.lastExitStatus.code == 127)
        #expect(cap.stderr.contains("once: command not found"))
    }

    @Test func uninstallReturnsZeroIfMissing() {
        let cap = CapturingShell()
        #expect(cap.shell.uninstall(name: "nope") == 0)
    }

    @Test func registeringOverridesBuiltin() async throws {
        let cap = CapturingShell()
        // Override `echo` with a louder version.
        cap.shell.installShellBuiltin(name: "echo") { argv in
            let loud = argv.dropFirst().joined(separator: " ").uppercased()
            Shell.bashCurrent.stdout(loud + "!\n")
            return .success
        }
        try await cap.shell.run("echo hello")
        #expect(cap.stdout == "HELLO!\n")
    }

    // MARK: Interaction with control flow

    @Test func registeredCommandInsideLoop() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "collect") { argv in
            let prior = Shell.bashCurrent.environment["COLLECTED"] ?? ""
            Shell.bashCurrent.environment["COLLECTED"] = prior
                + (prior.isEmpty ? "" : ",")
                + argv.dropFirst().joined(separator: " ")
            return .success
        }
        try await cap.shell.run("for x in a b c; do collect $x; done")
        #expect(cap.shell.environment["COLLECTED"] == "a,b,c")
    }

    @Test func registeredCommandUsedInPipelinePositions() async throws {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "emit") { argv in
            for arg in argv.dropFirst() { Shell.bashCurrent.stdout("\(arg)\n") }
            return .success
        }
        try await cap.shell.run("emit 1 2 && emit 3")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    // MARK: Default registry sanity

    @Test func defaultRegistryContainsBundledCommands() {
        let shell = Shell()
        for name in [":", "cd", "export", "unset", "exit", "break", "continue"] {
            #expect(shell.shellBuiltins[name] != nil,
                "pure built-in `\(name)` missing from default registry")
        }
        // Hybrid commands (built-in AND file form).
        for name in ["echo", "true", "false", "pwd"] {
            #expect(shell.shellBuiltins[name] != nil,
                "hybrid built-in `\(name)` missing")
        }
    }

    @Test func initWithEmptyRegistryOnlyRunsExplicitlyRegistered() async throws {
        let cap = CapturingShell()
        cap.shell.commands = [:]
        cap.shell.commandsByPath = [:]
        cap.shell.pathsByBasename = [:]
        cap.shell.shellBuiltins = [:]
        // Even `echo` is gone now — must report not-found and return 127.
        try await cap.shell.run("echo hi")
        #expect(cap.shell.lastExitStatus.code == 127)

        // Register something and verify only it works.
        cap.shell.installShellBuiltin(name: "hi") { _ in
            Shell.bashCurrent.stdout("hi\n"); return .success
        }
        try await cap.shell.run("hi")
        #expect(cap.stdout == "hi\n")
    }
}
