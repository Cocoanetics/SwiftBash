import XCTest
import ArgumentParser
@testable import BashInterpreter
@testable import BashCommandKit

/// Captures stdout/stderr written by a shell for assertion. Bytes are
/// UTF-8 decoded into the `stdout` / `stderr` strings.
final class CapturingShell {
    let shell: Shell

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            let s = String(decoding: data, as: UTF8.self)
            lock.lock(); defer { lock.unlock() }
            value.append(s)
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let _stdout = StringBox()
    private let _stderr = StringBox()

    var stdout: String { _stdout.read() }
    var stderr: String { _stderr.read() }

    init() {
        let stdoutSink = OutputSink(onWrite: { [weak _stdout] data in
            _stdout?.append(data)
        })
        let stderrSink = OutputSink(onWrite: { [weak _stderr] data in
            _stderr?.append(data)
        })
        self.shell = Shell(stdout: stdoutSink, stderr: stderrSink)
    }
}

/// Async-friendly variant of `XCTAssertThrowsError`.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "expected an error" : message(),
                file: file, line: line)
    } catch {
        handler(error)
    }
}

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

final class ParsableBashCommandTests: XCTestCase {

    // MARK: Basic wiring

    func testDefaultArgumentsRunExecute() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet")
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testPositionalArgumentIsPassedThrough() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet oliver")
        XCTAssertEqual(cap.stdout, "hello oliver\n")
    }

    func testLongFlag() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet --loud oliver")
        XCTAssertEqual(cap.stdout, "HELLO OLIVER\n")
    }

    func testShortFlag() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet -l oliver")
        XCTAssertEqual(cap.stdout, "HELLO OLIVER\n")
    }

    func testTypedOption() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet --count 3 oliver")
        XCTAssertEqual(cap.stdout, "hello oliver\nhello oliver\nhello oliver\n")
    }

    // MARK: Registry plumbing

    func testCommandNameFromConfiguration() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        XCTAssertNotNil(cap.shell.commands["greet"])
    }

    func testFallbackNameFromSwiftType() async throws {
        let cap = CapturingShell()
        cap.shell.register(Nameless.self)
        XCTAssertNotNil(cap.shell.commands["nameless"])
        try await cap.shell.run("nameless hi")
        XCTAssertEqual(cap.stdout, "hi\n")
    }

    // MARK: Help / version

    func testHelpFlagPrintsUsageAndExitsSuccess() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --help")
        XCTAssertEqual(status, .success)
        // The exact message formatting is ArgumentParser's concern; just
        // confirm it mentions the abstract and the flag names.
        XCTAssertTrue(cap.stdout.contains("Print a friendly hello"), cap.stdout)
        XCTAssertTrue(cap.stdout.contains("--loud"), cap.stdout)
        XCTAssertTrue(cap.stdout.contains("--count"), cap.stdout)
    }

    // MARK: Error paths

    func testUnknownOptionExitsNonZeroAndWritesStderr() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --nope")
        XCTAssertFalse(status.isSuccess, "exit should be non-zero")
        XCTAssertTrue(cap.stderr.contains("--nope") || cap.stderr.contains("Usage"),
                      "stderr should contain a usage diagnostic:\n\(cap.stderr)")
        XCTAssertEqual(cap.stdout, "")
    }

    func testMissingRequiredArgumentFailsGracefully() async throws {
        let cap = CapturingShell()
        cap.shell.register(RequireNameCommand.self)
        let status = try await cap.shell.run("require")
        XCTAssertFalse(status.isSuccess)
        XCTAssertTrue(cap.stderr.contains("name") || cap.stderr.contains("missing"),
                      cap.stderr)
    }

    func testBadOptionValueFailsGracefully() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        let status = try await cap.shell.run("greet --count notanumber oliver")
        XCTAssertFalse(status.isSuccess)
    }

    // MARK: Repeated parsed arguments

    func testArrayArgumentCollectsAll() async throws {
        let cap = CapturingShell()
        cap.shell.register(SumCommand.self)
        try await cap.shell.run("sum 1 2 3 4 10")
        XCTAssertEqual(cap.stdout, "20\n")
    }

    // MARK: Integration with the interpreter

    func testRegisteredParsableCommandInAndChain() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("greet alice && greet bob")
        XCTAssertEqual(cap.stdout, "hello alice\nhello bob\n")
    }

    func testRegisteredParsableCommandInForLoop() async throws {
        let cap = CapturingShell()
        cap.shell.register(GreetCommand.self)
        try await cap.shell.run("for who in alice bob charlie; do greet $who; done")
        XCTAssertEqual(cap.stdout, "hello alice\nhello bob\nhello charlie\n")
    }

    func testParsableCommandCanMutateEnvironment() async throws {
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
        XCTAssertEqual(cap.shell.environment["GREETING"], "howdy")
    }
}
