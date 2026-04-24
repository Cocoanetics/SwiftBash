import Testing
import ArgumentParser
@testable import BashInterpreter
@testable import BashCommandKit

// MARK: Test commands

private struct GreetCommand: ParsableBashCommand {
    static let configuration = CommandConfiguration(
        commandName: "greet",
        abstract: "Print a friendly hello."
    )

    @Argument(help: "Who to greet.")
    var name: String = "world"

    @Flag(name: .shortAndLong, help: "Shout it.")
    var loud: Bool = false

    @Option(name: .shortAndLong, help: "Say it this many times.")
    var count: Int = 1

    mutating func execute(shell: Shell) async throws -> ExitStatus {
        let line = loud ? "HELLO \(name.uppercased())" : "hello \(name)"
        for _ in 0..<count { shell.stdout(line + "\n") }
        return .success
    }
}

private struct SumCommand: ParsableBashCommand {
    static let configuration = CommandConfiguration(commandName: "sum")

    @Argument var values: [Int] = []

    mutating func execute(shell: Shell) async throws -> ExitStatus {
        shell.stdout("\(values.reduce(0, +))\n")
        return .success
    }
}

private struct RequireNameCommand: ParsableBashCommand {
    static let configuration = CommandConfiguration(commandName: "require")

    @Argument(help: "Required name.")
    var name: String

    mutating func execute(shell: Shell) async throws -> ExitStatus {
        shell.stdout("got \(name)\n")
        return .success
    }
}

/// A command without an explicit commandName — falls back on type name.
private struct Nameless: ParsableBashCommand {
    static let configuration = CommandConfiguration()
    @Argument var word: String = "default"
    mutating func execute(shell: Shell) async throws -> ExitStatus {
        shell.stdout("\(word)\n")
        return .success
    }
}

// MARK: Tests

@Suite struct ParsableBashCommandTests {

    // MARK: Basic wiring

    @Test func defaultArgumentsRunExecute() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet")
        #expect(cap.stdout == "hello world\n")
    }

    @Test func positionalArgumentIsPassedThrough() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet oliver")
        #expect(cap.stdout == "hello oliver\n")
    }

    @Test func longFlag() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet --loud oliver")
        #expect(cap.stdout == "HELLO OLIVER\n")
    }

    @Test func shortFlag() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet -l oliver")
        #expect(cap.stdout == "HELLO OLIVER\n")
    }

    @Test func typedOption() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet --count 3 oliver")
        #expect(cap.stdout == "hello oliver\nhello oliver\nhello oliver\n")
    }

    // MARK: Registry plumbing

    @Test func commandNameFromConfiguration() {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        #expect(cap.shell.commands["greet"] != nil)
    }

    @Test func fallbackNameFromSwiftType() async throws {
        let cap = CapturingShell()
        cap.shell.register(Nameless.self)
        #expect(cap.shell.commands["nameless"] != nil)
        try await cap.shell.run("nameless hi")
        #expect(cap.stdout == "hi\n")
    }

    // MARK: Help / version

    @Test func helpFlagPrintsUsageAndExitsSuccess() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --help")
        #expect(status == .success)
        // The exact message formatting is ArgumentParser's concern; just
        // confirm it mentions the abstract and the flag names.
        #expect(cap.stdout.contains("Print a friendly hello"), "\(cap.stdout)")
        #expect(cap.stdout.contains("--loud"), "\(cap.stdout)")
        #expect(cap.stdout.contains("--count"), "\(cap.stdout)")
    }

    // MARK: Error paths

    @Test func unknownOptionExitsNonZeroAndWritesStderr() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --nope")
        #expect(!status.isSuccess, "exit should be non-zero")
        #expect(cap.stderr.contains("--nope") || cap.stderr.contains("Usage"),
                "stderr should contain a usage diagnostic:\n\(cap.stderr)")
        #expect(cap.stdout == "")
    }

    @Test func missingRequiredArgumentFailsGracefully() async throws {
        let cap = CapturingShell()
        cap.shell.register(RequireNameCommand.self)
        let status = try await cap.shell.run("require")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("name") || cap.stderr.contains("missing"),
                "\(cap.stderr)")
    }

    @Test func badOptionValueFailsGracefully() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --count notanumber oliver")
        #expect(!status.isSuccess)
    }

    // MARK: Repeated parsed arguments

    @Test func arrayArgumentCollectsAll() async throws {
        let cap = CapturingShell()
        cap.shell.register(SumCommand.self)
        try await cap.shell.run("sum 1 2 3 4 10")
        #expect(cap.stdout == "20\n")
    }

    // MARK: Integration with the interpreter

    @Test func registeredParsableCommandInAndChain() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet alice && greet bob")
        #expect(cap.stdout == "hello alice\nhello bob\n")
    }

    @Test func registeredParsableCommandInForLoop() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("for who in alice bob charlie; do greet $who; done")
        #expect(cap.stdout == "hello alice\nhello bob\nhello charlie\n")
    }

    @Test func parsableCommandCanMutateEnvironment() async throws {
        struct SetVar: ParsableBashCommand {
            static let configuration = CommandConfiguration(commandName: "setvar")
            @Argument var name: String
            @Argument var value: String
            mutating func execute(shell: Shell) async throws -> ExitStatus {
                shell.environment[name] = value
                return .success
            }
        }
        let cap = CapturingShell()
        cap.shell.register(SetVar.self)
        try await cap.shell.run("setvar GREETING howdy")
        #expect(cap.shell.environment["GREETING"] == "howdy")
    }
}
