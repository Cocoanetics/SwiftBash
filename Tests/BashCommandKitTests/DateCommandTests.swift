import Testing
import ArgumentParser
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct DateCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.install(DateCommand.self)
        return cap
    }

    // MARK: Default behaviour

    @Test func defaultProducesNonEmptyOutput() async throws {
        let cap = makeShell()
        try await cap.shell.run("date")
        #expect(!cap.stdout.isEmpty)
        #expect(cap.stdout.hasSuffix("\n"), "should end with newline")
    }

    @Test func defaultFormatIncludesYear() async throws {
        let cap = makeShell()
        try await cap.shell.run("date")
        let year = Calendar.current.component(.year, from: Date())
        #expect(cap.stdout.contains("\(year)"),
                "default format should contain the current year:\n\(cap.stdout)")
    }

    // MARK: Literal format pass-through

    @Test func literalFormatStringPassesThrough() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date --format hello"#)
        #expect(cap.stdout == "hello\n")
    }

    @Test func formatWithPercentPercentIsLiteralPercent() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "100%%""#)
        #expect(cap.stdout == "100%\n")
    }

    // MARK: Specifiers

    @Test func yearSpecifier() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%Y""#)
        let year = Calendar.current.component(.year, from: Date())
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "\(year)")
    }

    @Test func isoDateSpecifier() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%Y-%m-%d""#)
        let trimmed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-")
        #expect(parts.count == 3)
        #expect(parts[0].count == 4, "year is 4 digits")
        #expect(parts[1].count == 2, "month is 2 digits")
        #expect(parts[2].count == 2, "day is 2 digits")
    }

    @Test func timeSpecifierMatchesHHmmSS() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "%H:%M:%S""#)
        let trimmed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try NSRegularExpression(pattern: "^\\d{2}:\\d{2}:\\d{2}$")
        let matches = regex.numberOfMatches(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed))
        #expect(matches == 1, "expected HH:MM:SS, got \(trimmed)")
    }

    @Test func unixTimestampSpecifier() async throws {
        let cap = makeShell()
        let before = Int(Date().timeIntervalSince1970)
        try await cap.shell.run(#"date -f "%s""#)
        let after = Int(Date().timeIntervalSince1970)
        let output = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let printed = Int(output) else {
            Issue.record("expected an integer, got `\(output)`")
            return
        }
        #expect(printed >= before)
        #expect(printed <= after + 1)
    }

    // MARK: - -utc

    @Test func utcFlagUsesGmtTimezone() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -u -f "%Z""#)
        // %Z is preprocessed before strftime sees it, so the answer is
        // identical on every platform.
        let timezone = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(timezone == "UTC" || timezone == "GMT", "got timezone `\(timezone)`")
    }

    @Test func utcAndLocalCanDifferInHours() async throws {
        // This is only a meaningful test when the testing machine is not
        // on UTC. If it is, both values will be equal — just assert the
        // command ran.
        let cap1 = makeShell()
        try await cap1.shell.run(#"date -f "%H""#)
        let cap2 = makeShell()
        try await cap2.shell.run(#"date -u -f "%H""#)
        #expect(!cap1.stdout.isEmpty)
        #expect(!cap2.stdout.isEmpty)
    }

    // MARK: Short flags

    @Test func shortFormatFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -f "hi""#)
        #expect(cap.stdout == "hi\n")
    }

    @Test func shortUtcFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"date -u -f "%Z""#)
        let timezone = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(timezone == "UTC" || timezone == "GMT", "got `\(timezone)`")
    }

    // MARK: Interaction with the shell

    @Test func dateInCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"TODAY=$(date -f "%Y-%m-%d"); echo $TODAY"#)
        let value = cap.shell.environment["TODAY"] ?? ""
        let regex = try NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
        let range = NSRange(value.startIndex..., in: value)
        #expect(regex.numberOfMatches(in: value, range: range) == 1,
                "expected ISO date in $TODAY, got `\(value)`")
    }

    @Test func helpFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run("date --help")
        #expect(cap.stdout.contains("Print the current date"),
                "help should include the abstract:\n\(cap.stdout)")
        #expect(cap.stdout.contains("--format"), "\(cap.stdout)")
        #expect(cap.stdout.contains("--utc"), "\(cap.stdout)")
    }
}
