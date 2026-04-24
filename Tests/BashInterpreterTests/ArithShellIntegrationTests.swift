import XCTest
@testable import BashInterpreter

/// End-to-end tests that exercise `((…))` and `$((…))` through a `Shell`.
final class ArithShellIntegrationTests: XCTestCase {

    // MARK: $((…)) in word expansion

    func testEchoArithmeticLiteral() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((1 + 2))")
        XCTAssertEqual(cap.stdout, "3\n")
    }

    func testEchoArithmeticWithPrecedence() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((1 + 2 * 3))")
        XCTAssertEqual(cap.stdout, "7\n")
    }

    func testEchoArithmeticWithVariable() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "10"
        try await cap.shell.run("echo $((X * 2))")
        XCTAssertEqual(cap.stdout, "20\n")
    }

    func testEchoArithmeticWithUnsetVariableIsZero() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((UNDEFINED + 1))")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testEchoArithmeticInsideDoubleQuotes() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "result=$((2 + 3)) done""#)
        XCTAssertEqual(cap.stdout, "result=5 done\n")
    }

    func testArithmeticExpressionWithHexAndOctal() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((0xff + 010))")
        XCTAssertEqual(cap.stdout, "263\n")
    }

    // MARK: ((…)) as a command

    func testArithCommandSuccessOnNonZero() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("(( 1 + 1 ))")
        XCTAssertEqual(status, .success)
    }

    func testArithCommandFailureOnZero() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("(( 0 ))")
        XCTAssertEqual(status, .failure)
    }

    func testArithCommandAssignment() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(( x = 5 + 3 ))")
        XCTAssertEqual(cap.shell.environment["x"], "8")
    }

    func testArithCommandIncrement() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "5"
        try await cap.shell.run("(( i++ ))")
        XCTAssertEqual(cap.shell.environment["i"], "6")
    }

    func testArithCommandWithComparison() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "10"
        let a = try await cap.shell.run("(( n > 5 ))")
        XCTAssertEqual(a, .success)
        let b = try await cap.shell.run("(( n < 5 ))")
        XCTAssertEqual(b, .failure)
    }

    func testArithCommandInAndChain() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "7"
        try await cap.shell.run("(( n > 5 )) && echo big")
        XCTAssertEqual(cap.stdout, "big\n")
    }

    func testArithCommandInOrChain() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "3"
        try await cap.shell.run("(( n > 5 )) || echo small")
        XCTAssertEqual(cap.stdout, "small\n")
    }

    // MARK: Dollar-question after arithmetic

    func testExitStatusOfArithCommand() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(( 0 ))")
        XCTAssertEqual(cap.shell.lastExitStatus, .failure)
        try await cap.shell.run("(( 42 ))")
        XCTAssertEqual(cap.shell.lastExitStatus, .success)
    }

    // MARK: Combining arithmetic substitution with other features

    func testArithSubWithCommandSubstitution() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "4"
        try await cap.shell.run(#"echo $(echo $((X * X)))"#)
        XCTAssertEqual(cap.stdout, "16\n")
    }

    func testArithSubExportAndReuse() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export N=10")
        try await cap.shell.run("echo $((N + N))")
        XCTAssertEqual(cap.stdout, "20\n")
    }

    // MARK: Error propagation

    func testDivisionByZeroPropagatesAsError() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run("echo $((1/0))")) { err in
            XCTAssertTrue(err is ArithError || err is BashInterpreterError,
                          "got \(err)")
        }
    }

    func testSyntaxErrorInArithmetic() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run("echo $((1 +))"))
    }
}
