import XCTest
@testable import BashInterpreter

final class EnvironmentTests: XCTestCase {

    func testInitWithDictionary() {
        let env = Environment(variables: ["FOO": "bar", "BAZ": "qux"])
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertEqual(env["BAZ"], "qux")
    }

    func testSubscriptAssignment() {
        var env = Environment()
        env["X"] = "y"
        XCTAssertEqual(env["X"], "y")
        env["X"] = nil
        XCTAssertNil(env["X"])
    }

    func testCurrentLoadsFromProcess() {
        let env = Environment.current()
        // PATH is essentially always present on macOS/Linux.
        XCTAssertNotNil(env["PATH"])
        XCTAssertFalse(env.workingDirectory.isEmpty)
    }

    func testShellReadsEnvironmentDictionary() throws {
        let cap = CapturingShell(environment:
            Environment(variables: ["PATH": "/usr/bin:/bin",
                                    "USER": "oliver"]))
        try cap.shell.run("echo $USER $PATH")
        XCTAssertEqual(cap.stdout, "oliver /usr/bin:/bin\n")
    }
}
