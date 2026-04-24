import XCTest
@testable import BashInterpreter

final class VariableExpansionTests: XCTestCase {

    func testEchoPath() throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/bin:/bin"
        try cap.shell.run("echo $PATH")
        XCTAssertEqual(cap.stdout, "/usr/bin:/bin\n")
    }

    func testEchoUndefinedVariableYieldsEmpty() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $NOPE")
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testBracedExpansion() throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try cap.shell.run("echo ${NAME}")
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    func testExpansionInsideDoubleQuotes() throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try cap.shell.run(#"echo "hello $WHO""#)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testNoExpansionInsideSingleQuotes() throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try cap.shell.run("echo 'hello $WHO'")
        XCTAssertEqual(cap.stdout, "hello $WHO\n")
    }

    func testCommandSubstitution() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $(echo inner)")
        XCTAssertEqual(cap.stdout, "inner\n")
    }

    func testNestedCommandSubstitution() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo $(echo $(echo deep))")
        XCTAssertEqual(cap.stdout, "deep\n")
    }

    func testCommandSubstitutionInsideString() throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try cap.shell.run(#"echo "hi $(echo $NAME)""#)
        XCTAssertEqual(cap.stdout, "hi oliver\n")
    }

    func testTildeExpandsToHome() throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try cap.shell.run("echo ~/docs")
        XCTAssertEqual(cap.stdout, "/Users/oliver/docs\n")
    }

    func testDollarQuestionIsLastExitStatus() throws {
        let cap = CapturingShell()
        try cap.shell.run("false; echo $?")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testAdjacentVarsConcatenate() throws {
        let cap = CapturingShell()
        cap.shell.environment["A"] = "foo"
        cap.shell.environment["B"] = "bar"
        try cap.shell.run("echo $A$B")
        XCTAssertEqual(cap.stdout, "foobar\n")
    }
}
