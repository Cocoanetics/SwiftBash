import XCTest
@testable import BashInterpreter

final class EnvironmentTests: XCTestCase {

    func testInitWithDictionary() async {
        let env = Environment(variables: ["FOO": "bar", "BAZ": "qux"])
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertEqual(env["BAZ"], "qux")
    }

    func testSubscriptAssignment() async {
        var env = Environment()
        env["X"] = "y"
        XCTAssertEqual(env["X"], "y")
        env["X"] = nil
        XCTAssertNil(env["X"])
    }

    func testCurrentLoadsFromProcess() async {
        let env = Environment.current()
        // PATH is essentially always present on macOS/Linux.
        XCTAssertNotNil(env["PATH"])
        XCTAssertFalse(env.workingDirectory.isEmpty)
    }

    func testShellReadsEnvironmentDictionary() async throws {
        let cap = CapturingShell(environment:
            Environment(variables: ["PATH": "/usr/bin:/bin",
                                    "USER": "oliver"]))
        try await cap.shell.run("echo $USER $PATH")
        XCTAssertEqual(cap.stdout, "oliver /usr/bin:/bin\n")
    }
}
