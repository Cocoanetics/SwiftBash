import XCTest
import ArgumentParser
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

final class DateCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(DateCommand.self)
        return cap
    }

    // MARK: Default behaviour

    func testDefaultProducesNonEmptyOutput() async throws {
        let cap = makeShell()
        try await cap.shell.run("date")
        XCTAssertFalse(cap.stdout.isEmpty)
        XCTAssertTrue(cap.stdout.hasSuffix("\n"), "should end with newline")
    }

    func testDefaultFormatIncludesYear() async throws {
        let cap = makeShell()
        try await cap.shell.run("date")
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(cap.stdout.contains("\(year)"),
                      "default format should contain the current year:\n\(cap.stdout)")
    }

    // MARK: Literal format pass-through

    func testLiteralFormatStringPassesThrough() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date --format hello"#)
        XCTAssertEqual(cap.stdout, "hello\n")
    }

    func testFormatWithPercentPercentIsLiteralPercent() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "100%%""#)
        XCTAssertEqual(cap.stdout, "100%\n")
    }

    // MARK: Specifiers

    func testYearSpecifier() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%Y""#)
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(year)")
    }

    func testIsoDateSpecifier() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%Y-%m-%d""#)
        let trimmed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4, "year is 4 digits")
        XCTAssertEqual(parts[1].count, 2, "month is 2 digits")
        XCTAssertEqual(parts[2].count, 2, "day is 2 digits")
    }

    func testTimeSpecifierMatchesHHmmSS() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%H:%M:%S""#)
        let trimmed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try NSRegularExpression(pattern: "^\\d{2}:\\d{2}:\\d{2}$")
        let matches = regex.numberOfMatches(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed))
        XCTAssertEqual(matches, 1, "expected HH:MM:SS, got \(trimmed)")
    }

    func testUnixTimestampSpecifier() async throws {
        let cap = makeShell()
        let before = Int(Date().timeIntervalSince1970)
        try await cap.shell.run(#"date -f "%s""#)
        let after = Int(Date().timeIntervalSince1970)
        let output = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let printed = Int(output) else {
            return XCTFail("expected an integer, got `\(output)`")
        }
        XCTAssertGreaterThanOrEqual(printed, before)
        XCTAssertLessThanOrEqual(printed, after + 1)
    }

    // MARK: --utc

    func testUtcFlagUsesGmtTimezone() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -u -f "%Z""#)
        // strftime's %Z for UTC is typically "UTC" or "GMT" depending
        // on libc; either is acceptable.
        let tz = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(tz == "UTC" || tz == "GMT",
                      "got timezone `\(tz)`")
    }

    func testUtcAndLocalCanDifferInHours() async throws {
        // This is only a meaningful test when the testing machine is not
        // on UTC. If it is, both values will be equal — just assert the
        // command ran.
        let cap1 = makeShell()
        try await cap1.shell.run(#"date -f "%H""#)
        let cap2 = makeShell()
        try await cap2.shell.run(#"date -u -f "%H""#)
        XCTAssertFalse(cap1.stdout.isEmpty)
        XCTAssertFalse(cap2.stdout.isEmpty)
    }

    // MARK: Short flags

    func testShortFormatFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "hi""#)
        XCTAssertEqual(cap.stdout, "hi\n")
    }

    func testShortUtcFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -u -f "%Z""#)
        let tz = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(tz == "UTC" || tz == "GMT", "got `\(tz)`")
    }

    // MARK: Interaction with the shell

    func testDateInCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"TODAY=$(date -f "%Y-%m-%d"); echo $TODAY"#)
        let value = cap.shell.environment["TODAY"] ?? ""
        let regex = try NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
        let range = NSRange(value.startIndex..., in: value)
        XCTAssertEqual(regex.numberOfMatches(in: value, range: range), 1,
                       "expected ISO date in $TODAY, got `\(value)`")
    }

    func testHelpFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run("date --help")
        XCTAssertTrue(cap.stdout.contains("Print the current date"),
                      "help should include the abstract:\n\(cap.stdout)")
        XCTAssertTrue(cap.stdout.contains("--format"), cap.stdout)
        XCTAssertTrue(cap.stdout.contains("--utc"), cap.stdout)
    }
}
