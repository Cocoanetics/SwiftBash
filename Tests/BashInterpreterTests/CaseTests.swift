import XCTest
@testable import BashInterpreter

final class CaseTests: XCTestCase {

    // MARK: Basic matching

    func testLiteralMatch() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case apple in
              apple) echo fruit;;
              carrot) echo veg;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "fruit\n")
    }

    func testFallsThroughToSecondArm() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case carrot in
              apple) echo fruit;;
              carrot) echo veg;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "veg\n")
    }

    func testNoMatchProducesNoOutput() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case banana in
              apple) echo one;;
              carrot) echo two;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "")
    }

    // MARK: Glob patterns

    func testStarMatchesAnything() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case hello in
              hi) echo short;;
              *) echo anything;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "anything\n")
    }

    func testQuestionMatchesOneChar() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case ab in
              ?) echo one;;
              ??) echo two;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "two\n")
    }

    func testCharClassMatches() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case m in
              [a-f]) echo early;;
              [g-p]) echo middle;;
              [q-z]) echo late;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "middle\n")
    }

    func testMultipleAlternativesWithBar() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case green in
              red|orange|yellow) echo warm;;
              green|blue|purple) echo cool;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "cool\n")
    }

    func testSuffixGlob() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case script.sh in
              *.sh) echo shell;;
              *.py) echo python;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "shell\n")
    }

    // MARK: Fall-through terminators

    func testSemiAndFallsThrough() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case a in
              a) echo first ;&
              b) echo second;;
              c) echo third;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "first\nsecond\n")
    }

    func testSemiSemiAndContinuesTesting() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case abc in
              *b*) echo has-b ;;&
              a*) echo starts-a ;;
              x*) echo starts-x ;;
            esac
            """)
        // First arm matches (contains 'b'). `;;&` means "continue testing".
        // Second arm matches (starts with 'a'), runs, then `;;` stops.
        XCTAssertEqual(cap.stdout, "has-b\nstarts-a\n")
    }

    // MARK: Variable subject

    func testExpandsSubject() async throws {
        let cap = CapturingShell()
        cap.shell.environment["colour"] = "blue"
        try await cap.shell.run("""
            case $colour in
              red) echo stop;;
              green) echo go;;
              blue) echo cool;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "cool\n")
    }

    // MARK: Exit status

    func testCaseExitStatusIsLastBody() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case x in
              x) false;;
            esac
            """)
        XCTAssertEqual(status, .failure)
    }

    func testCaseWithNoMatchExitsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case z in
              a) false;;
            esac
            """)
        XCTAssertEqual(status, .success)
    }

    // MARK: Empty body

    func testArmWithNoBodyStillMatches() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case x in
              x) ;;
              *) echo default;;
            esac
            """)
        XCTAssertEqual(cap.stdout, "")
        XCTAssertEqual(status, .success)
    }
}
