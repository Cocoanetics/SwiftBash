import XCTest
@testable import BashInterpreter

/// End-to-end tests that exercise `((…))` and `$((…))` through a `Shell`.
final class ArithShellIntegrationTests: XCTestCase {

    // MARK: $((…)) in word expansion

    func testEchoArithmeticLiteral() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $((1 + 2))")
        XCTAssertEqual(cap.stdout, "3\n")
    }

    func testEchoArithmeticWithPrecedence() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $((1 + 2 * 3))")
        XCTAssertEqual(cap.stdout, "7\n")
    }

    func testEchoArithmeticWithVariable() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "10"
        try cap.shell.run("echo $((X * 2))")
        XCTAssertEqual(cap.stdout, "20\n")
    }

    func testEchoArithmeticWithUnsetVariableIsZero() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $((UNDEFINED + 1))")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testEchoArithmeticInsideDoubleQuotes() throws {
        let cap = CapturingShell()
        try cap.shell.run(#"echo "result=$((2 + 3)) done""#)
        XCTAssertEqual(cap.stdout, "result=5 done\n")
    }

    func testArithmeticExpressionWithHexAndOctal() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $((0xff + 010))")
        XCTAssertEqual(cap.stdout, "263\n")
    }

    // MARK: ((…)) as a command

    func testArithCommandSuccessOnNonZero() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("(( 1 + 1 ))")
        XCTAssertEqual(status, .success)
    }

    func testArithCommandFailureOnZero() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("(( 0 ))")
        XCTAssertEqual(status, .failure)
    }

    func testArithCommandAssignment() throws {
        let cap = CapturingShell()
        try cap.shell.run("(( x = 5 + 3 ))")
        XCTAssertEqual(cap.shell.environment["x"], "8")
    }

    func testArithCommandIncrement() throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "5"
        try cap.shell.run("(( i++ ))")
        XCTAssertEqual(cap.shell.environment["i"], "6")
    }

    func testArithCommandWithComparison() throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "10"
        XCTAssertEqual(try cap.shell.run("(( n > 5 ))"), .success)
        XCTAssertEqual(try cap.shell.run("(( n < 5 ))"), .failure)
    }

    func testArithCommandInAndChain() throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "7"
        try cap.shell.run("(( n > 5 )) && echo big")
        XCTAssertEqual(cap.stdout, "big\n")
    }

    func testArithCommandInOrChain() throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "3"
        try cap.shell.run("(( n > 5 )) || echo small")
        XCTAssertEqual(cap.stdout, "small\n")
    }

    // MARK: Dollar-question after arithmetic

    func testExitStatusOfArithCommand() throws {
        let cap = CapturingShell()
        try cap.shell.run("(( 0 ))")
        XCTAssertEqual(cap.shell.lastExitStatus, .failure)
        try cap.shell.run("(( 42 ))")
        XCTAssertEqual(cap.shell.lastExitStatus, .success)
    }

    // MARK: Combining arithmetic substitution with other features

    func testArithSubWithCommandSubstitution() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "4"
        try cap.shell.run(#"echo $(echo $((X * X)))"#)
        XCTAssertEqual(cap.stdout, "16\n")
    }

    func testArithSubExportAndReuse() throws {
        let cap = CapturingShell()
        try cap.shell.run("export N=10")
        try cap.shell.run("echo $((N + N))")
        XCTAssertEqual(cap.stdout, "20\n")
    }

    // MARK: Error propagation

    func testDivisionByZeroPropagatesAsError() {
        let cap = CapturingShell()
        XCTAssertThrowsError(try cap.shell.run("echo $((1/0))")) { err in
            XCTAssertTrue(err is ArithError || err is BashInterpreterError,
                          "got \(err)")
        }
    }

    func testSyntaxErrorInArithmetic() {
        let cap = CapturingShell()
        XCTAssertThrowsError(try cap.shell.run("echo $((1 +))"))
    }
}
