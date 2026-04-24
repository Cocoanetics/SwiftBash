import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class EnvCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(EnvCommand.self)
        return cap
    }

    func testEmptyEnvPrintsNothing() throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "")
    }

    func testPrintsAllSortedByName() throws {
        let cap = makeShell()
        cap.shell.environment.variables = [
            "ZEBRA": "z", "ALPHA": "a", "BRAVO": "b"
        ]
        try cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "ALPHA=a\nBRAVO=b\nZEBRA=z\n")
    }

    func testReflectsExportedVariables() throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try cap.shell.run("export FOO=bar")
        try cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "FOO=bar\n")
    }
}
