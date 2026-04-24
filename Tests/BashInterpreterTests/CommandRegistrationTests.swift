import XCTest
@testable import BashInterpreter

final class CommandRegistrationTests: XCTestCase {

    // MARK: Closure-based

    func testRegisterClosureCommand() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "greet") { argv, shell in
            let who = argv.dropFirst().first ?? "world"
            shell.stdout("hello \(who)\n")
            return .success
        }
        try cap.shell.run("greet oliver")
        XCTAssertEqual(cap.stdout, "hello oliver\n")
    }

    func testClosureCommandCanFail() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "nope") { _, _ in .failure }
        let status = try cap.shell.run("nope")
        XCTAssertEqual(status, .failure)
        XCTAssertEqual(cap.shell.lastExitStatus, .failure)
    }

    func testClosureCommandCanThrow() {
        let cap = CapturingShell()
        cap.shell.register(name: "boom") { _, _ in
            throw BashInterpreterError.io("kaboom")
        }
        XCTAssertThrowsError(try cap.shell.run("boom")) { err in
            XCTAssertEqual(err as? BashInterpreterError, .io("kaboom"))
        }
    }

    func testClosureCommandMutatesEnvironment() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "bless") { argv, shell in
            for arg in argv.dropFirst() { shell.environment[arg] = "ok" }
            return .success
        }
        try cap.shell.run("bless A B C")
        XCTAssertEqual(cap.shell.environment["A"], "ok")
        XCTAssertEqual(cap.shell.environment["B"], "ok")
        XCTAssertEqual(cap.shell.environment["C"], "ok")
    }

    // MARK: Struct-based

    func testRegisterStructCommand() throws {
        struct UpperCaseCommand: Command {
            let name = "upper"
            func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
                let out = argv.dropFirst().joined(separator: " ").uppercased()
                shell.stdout(out + "\n")
                return .success
            }
        }
        let cap = CapturingShell()
        cap.shell.register(UpperCaseCommand())
        try cap.shell.run("upper hello world")
        XCTAssertEqual(cap.stdout, "HELLO WORLD\n")
    }

    // MARK: Unregister / override

    func testUnregisterRemovesCommand() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "once") { _, shell in
            shell.stdout("first\n"); return .success
        }
        try cap.shell.run("once")
        XCTAssertEqual(cap.stdout, "first\n")

        let removed = cap.shell.unregister("once")
        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.name, "once")

        XCTAssertThrowsError(try cap.shell.run("once")) { err in
            guard case .commandNotFound(let name) = err as? BashInterpreterError
            else { return XCTFail("got \(err)") }
            XCTAssertEqual(name, "once")
        }
    }

    func testUnregisterReturnsNilIfMissing() {
        let cap = CapturingShell()
        XCTAssertNil(cap.shell.unregister("nope"))
    }

    func testRegisteringOverridesBuiltin() throws {
        let cap = CapturingShell()
        // Override `echo` with a louder version.
        cap.shell.register(name: "echo") { argv, shell in
            let loud = argv.dropFirst().joined(separator: " ").uppercased()
            shell.stdout(loud + "!\n")
            return .success
        }
        try cap.shell.run("echo hello")
        XCTAssertEqual(cap.stdout, "HELLO!\n")
    }

    // MARK: Interaction with control flow

    func testRegisteredCommandInsideLoop() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "collect") { argv, shell in
            let prior = shell.environment["COLLECTED"] ?? ""
            shell.environment["COLLECTED"] = prior
                + (prior.isEmpty ? "" : ",")
                + argv.dropFirst().joined(separator: " ")
            return .success
        }
        try cap.shell.run("for x in a b c; do collect $x; done")
        XCTAssertEqual(cap.shell.environment["COLLECTED"], "a,b,c")
    }

    func testRegisteredCommandUsedInPipelinePositions() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "emit") { argv, shell in
            for arg in argv.dropFirst() { shell.stdout("\(arg)\n") }
            return .success
        }
        try cap.shell.run("emit 1 2 && emit 3")
        XCTAssertEqual(cap.stdout, "1\n2\n3\n")
    }

    // MARK: Default registry sanity

    func testDefaultRegistryContainsBundledCommands() {
        let defaults = Shell.defaultCommands()
        for name in ["echo", "true", "false", ":", "pwd", "cd",
                     "export", "unset", "exit", "break", "continue"]
        {
            XCTAssertNotNil(defaults[name],
                "bundled command `\(name)` missing from default registry")
        }
    }

    func testInitWithEmptyRegistryOnlyRunsExplicitlyRegistered() {
        let cap = CapturingShell()
        cap.shell.commands = [:]
        // Even `echo` is gone now.
        XCTAssertThrowsError(try cap.shell.run("echo hi"))

        // Register something and verify only it works.
        cap.shell.register(name: "hi") { _, shell in
            shell.stdout("hi\n"); return .success
        }
        XCTAssertNoThrow(try cap.shell.run("hi"))
        XCTAssertEqual(cap.stdout, "hi\n")
    }
}
