import Testing
import Foundation
@testable import BashInterpreter

@Suite struct URLAllowListTests {

    // MARK: Origin matching

    @Test func originOnlyEntryAllowsAllPaths() {
        let entry = "https://api.example.com"
        #expect(URLAllowList.matches(url: "https://api.example.com",
                                     entry: entry))
        #expect(URLAllowList.matches(url: "https://api.example.com/",
                                     entry: entry))
        #expect(URLAllowList.matches(url: "https://api.example.com/v1/users",
                                     entry: entry))
    }

    @Test func differentOriginRejected() {
        let entry = "https://api.example.com"
        #expect(!URLAllowList.matches(url: "https://api.example.org",
                                      entry: entry))
        #expect(!URLAllowList.matches(url: "http://api.example.com",
                                      entry: entry),
                "scheme mismatch")
        #expect(!URLAllowList.matches(url: "https://api.example.com:8080",
                                      entry: entry),
                "port differs")
    }

    @Test func portIsPartOfOrigin() {
        let entry = "https://api.example.com:8080"
        #expect(URLAllowList.matches(url: "https://api.example.com:8080/v1",
                                     entry: entry))
        #expect(!URLAllowList.matches(url: "https://api.example.com/v1",
                                      entry: entry))
    }

    // MARK: Path-prefix matching

    @Test func pathPrefixHonoursSegmentBoundaries() {
        let entry = "https://api.example.com/v1/"
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1", entry: entry))
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1/users", entry: entry))
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1/users/123", entry: entry))
        // These look similar but cross the segment boundary.
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v10", entry: entry))
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v10/users", entry: entry))
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v1-admin", entry: entry))
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v2/users", entry: entry))
    }

    @Test func pathPrefixWithoutTrailingSlashSameSemantics() {
        // `/v1` should behave like `/v1/` — bash users routinely write
        // either, and we mustn't allow `/v10` either way.
        let entry = "https://api.example.com/v1"
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1", entry: entry))
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1/users", entry: entry))
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v10", entry: entry))
    }

    // MARK: Encoded-separator defence

    @Test func encodedSlashInPathRejectedForPathScopedEntry() {
        let entry = "https://api.example.com/v1/"
        // `%2f` could let an attacker bypass segment-boundary checks
        // by encoding additional `/` characters that the server then
        // interprets as path separators. Reject the URL outright.
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v1/%2f..%2fadmin",
            entry: entry))
        #expect(!URLAllowList.matches(
            url: "https://api.example.com/v1/%5c..%5cadmin",
            entry: entry))
    }

    @Test func encodedSeparatorIgnoredForOriginOnlyEntry() {
        // No path scope, so segment-boundary worries don't apply.
        let entry = "https://api.example.com"
        #expect(URLAllowList.matches(
            url: "https://api.example.com/v1/%2f..%2fadmin",
            entry: entry))
    }

    // MARK: Validation

    @Test func validateAcceptsGoodEntries() {
        let errors = URLAllowList.validate([
            AllowedURLEntry("https://api.example.com"),
            AllowedURLEntry("https://api.example.com/v1/"),
            AllowedURLEntry("http://example.com:8080/path"),
        ])
        #expect(errors.isEmpty)
    }

    @Test func validateRejectsBadEntries() {
        let errors = URLAllowList.validate([
            AllowedURLEntry("not-a-url"),
            AllowedURLEntry("ftp://example.com/files"),
            AllowedURLEntry("https://example.com/%2fbypass"),
        ])
        #expect(errors.count == 3,
                "expected three errors, got: \(errors)")
    }

    // MARK: Multi-entry matching

    @Test func isAllowedMatchesAnyEntry() {
        let entries = [
            AllowedURLEntry("https://api.openai.com"),
            AllowedURLEntry("https://api.example.com/v1/"),
        ]
        #expect(URLAllowList.isAllowed(
            "https://api.openai.com/v1/chat", entries: entries))
        #expect(URLAllowList.isAllowed(
            "https://api.example.com/v1/users", entries: entries))
        #expect(!URLAllowList.isAllowed(
            "https://api.example.com/v2/users", entries: entries))
        #expect(!URLAllowList.isAllowed(
            "https://api.openai.org/v1/chat", entries: entries))
    }

    @Test func isAllowedFalseForEmptyList() {
        #expect(!URLAllowList.isAllowed("https://anywhere.com", entries: []))
    }

    // MARK: Header transforms

    @Test func transformedHeadersInjectFromMatchingEntry() {
        let entries = [
            AllowedURLEntry(url: "https://gateway.example.com",
                            transforms: [HeaderTransform(headers:
                                ["Authorization": "Bearer secret"])]),
            AllowedURLEntry("https://api.openai.com"),
        ]
        let h = URLAllowList.transformedHeaders(
            for: "https://gateway.example.com/v1/chat",
            entries: entries)
        #expect(h?["Authorization"] == "Bearer secret")
    }

    @Test func transformedHeadersNilWhenNothingMatches() {
        let entries = [
            AllowedURLEntry(url: "https://gateway.example.com",
                            transforms: [HeaderTransform(headers:
                                ["X-Token": "abc"])]),
        ]
        // Different origin → no transform.
        #expect(URLAllowList.transformedHeaders(
            for: "https://api.openai.com",
            entries: entries) == nil)
    }

    // MARK: Casing

    @Test func schemeAndHostNormalizedForMatch() {
        // RFC 3986: scheme+host are case-insensitive. Path is case-
        // sensitive (default).
        let entry = "https://API.Example.COM"
        #expect(URLAllowList.matches(
            url: "https://api.example.com/x", entry: entry))
    }
}
