import Testing
@testable import BashInterpreter

@Suite struct CommandRegistrationTests {

    // MARK: Closure-based

    @Test func registerClosureCommand() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "greet") { argv, shell in
            let who = argv.dropFirst().first ?? "world"
            shell.stdout("hello \(who)\n")
            return .success
        }
        try await cap.shell.run("greet oliver")
        #expect(cap.stdout == "hello oliver\n")
    }

    @Test func closureCommandCanFail() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "nope") { _, _ in .failure }
        let status = try await cap.shell.run("nope")
        #expect(status == .failure)
        #expect(cap.shell.lastExitStatus == .failure)
    }

    @Test func closureCommandCanThrow() async {
        let cap = CapturingShell()
        cap.shell.register(name: "boom") { _, _ in
            throw BashInterpreterError.io("kaboom")
        }
        let err = await #expect(throws: BashInterpreterError.self) {
            try await cap.shell.run("boom")
        }
        #expect(err == .io("kaboom"))
    }

    @Test func closureCommandMutatesEnvironment() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "bless") { argv, shell in
            for arg in argv.dropFirst() { shell.environment[arg] = "ok" }
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
            func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
                let out = argv.dropFirst().joined(separator: " ").uppercased()
                shell.stdout(out + "\n")
                return .success
            }
        }
        let cap = CapturingShell()
        cap.shell.register(UpperCaseCommand())
        try await cap.shell.run("upper hello world")
        #expect(cap.stdout == "HELLO WORLD\n")
    }

    // MARK: Unregister / override

    @Test func unregisterRemovesCommand() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "once") { _, shell in
            shell.stdout("first\n"); return .success
        }
        try await cap.shell.run("once")
        #expect(cap.stdout == "first\n")

        let removed = cap.shell.unregister("once")
        #expect(removed != nil)
        #expect(removed?.name == "once")

        let err = await #expect(throws: BashInterpreterError.self) {
            try await cap.shell.run("once")
        }
        guard case .commandNotFound(let name) = err else {
            Issue.record("got \(String(describing: err))")
            return
        }
        #expect(name == "once")
    }

    @Test func unregisterReturnsNilIfMissing() {
        let cap = CapturingShell()
        #expect(cap.shell.unregister("nope") == nil)
    }

    @Test func registeringOverridesBuiltin() async throws {
        let cap = CapturingShell()
        // Override `echo` with a louder version.
        cap.shell.register(name: "echo") { argv, shell in
            let loud = argv.dropFirst().joined(separator: " ").uppercased()
            shell.stdout(loud + "!\n")
            return .success
        }
        try await cap.shell.run("echo hello")
        #expect(cap.stdout == "HELLO!\n")
    }

    // MARK: Interaction with control flow

    @Test func registeredCommandInsideLoop() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "collect") { argv, shell in
            let prior = shell.environment["COLLECTED"] ?? ""
            shell.environment["COLLECTED"] = prior
                + (prior.isEmpty ? "" : ",")
                + argv.dropFirst().joined(separator: " ")
            return .success
        }
        try await cap.shell.run("for x in a b c; do collect $x; done")
        #expect(cap.shell.environment["COLLECTED"] == "a,b,c")
    }

    @Test func registeredCommandUsedInPipelinePositions() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "emit") { argv, shell in
            for arg in argv.dropFirst() { shell.stdout("\(arg)\n") }
            return .success
        }
        try await cap.shell.run("emit 1 2 && emit 3")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    // MARK: Default registry sanity

    @Test func defaultRegistryContainsBundledCommands() {
        let defaults = Shell.defaultCommands()
        for name in ["echo", "true", "false", ":", "pwd", "cd",
                     "export", "unset", "exit", "break", "continue"]
        {
            #expect(defaults[name] != nil,
                "bundled command `\(name)` missing from default registry")
        }
    }

    @Test func initWithEmptyRegistryOnlyRunsExplicitlyRegistered() async throws {
        let cap = CapturingShell()
        cap.shell.commands = [:]
        // Even `echo` is gone now.
        await #expect(throws: (any Error).self) {
            try await cap.shell.run("echo hi")
        }

        // Register something and verify only it works.
        cap.shell.register(name: "hi") { _, shell in
            shell.stdout("hi\n"); return .success
        }
        try await cap.shell.run("hi")
        #expect(cap.stdout == "hi\n")
    }
}
