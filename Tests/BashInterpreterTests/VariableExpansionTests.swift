import XCTest
@testable import BashInterpreter

final class VariableExpansionTests: XCTestCase {

    func testEchoPath() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/bin:/bin"
        try await cap.shell.run("echo $PATH")
        XCTAssertEqual(cap.stdout, "/usr/bin:/bin\n")
    }

    func testEchoUndefinedVariableYieldsEmpty() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $NOPE")
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testBracedExpansion() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run("echo ${NAME}")
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    func testExpansionInsideDoubleQuotes() async throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try await cap.shell.run(#"echo "hello $WHO""#)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testNoExpansionInsideSingleQuotes() async throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try await cap.shell.run("echo 'hello $WHO'")
        XCTAssertEqual(cap.stdout, "hello $WHO\n")
    }

    func testCommandSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $(echo inner)")
        XCTAssertEqual(cap.stdout, "inner\n")
    }

    func testNestedCommandSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $(echo $(echo deep))")
        XCTAssertEqual(cap.stdout, "deep\n")
    }

    func testCommandSubstitutionInsideString() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "hi $(echo $NAME)""#)
        XCTAssertEqual(cap.stdout, "hi oliver\n")
    }

    func testTildeExpandsToHome() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try await cap.shell.run("echo ~/docs")
        XCTAssertEqual(cap.stdout, "/Users/oliver/docs\n")
    }

    func testDollarQuestionIsLastExitStatus() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false; echo $?")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testAdjacentVarsConcatenate() async throws {
        let cap = CapturingShell()
        cap.shell.environment["A"] = "foo"
        cap.shell.environment["B"] = "bar"
        try await cap.shell.run("echo $A$B")
        XCTAssertEqual(cap.stdout, "foobar\n")
    }
}
