import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class EnvCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(EnvCommand.self)
        return cap
    }

    func testEmptyEnvPrintsNothing() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try await cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "")
    }

    func testPrintsAllSortedByName() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [
            "ZEBRA": "z", "ALPHA": "a", "BRAVO": "b"
        ]
        try await cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "ALPHA=a\nBRAVO=b\nZEBRA=z\n")
    }

    func testReflectsExportedVariables() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try await cap.shell.run("export FOO=bar")
        try await cap.shell.run("env")
        XCTAssertEqual(cap.stdout, "FOO=bar\n")
    }
}
