import Foundation

/// URL allow-list matching logic. Mirrors just-bash's design — see
/// ``matches(url:entry:)`` for the rules.
public enum URLAllowList {

    // MARK: Validation

    /// Validate every entry in `allowedURLPrefixes`. Returns the list
    /// of human-readable errors; empty means OK. Constructors that
    /// accept an allow-list should fail closed when this is non-empty.
    public static func validate(
        _ entries: [AllowedURLEntry]
    ) -> [String] {
        var errors: [String] = []
        for entry in entries {
            if let err = validateEntry(entry.url) {
                errors.append(err)
            }
        }
        return errors
    }

    private static func validateEntry(_ raw: String) -> String? {
        guard let comps = parseURL(raw) else {
            return "invalid URL: '\(raw)'"
        }
        // Must have a scheme and host.
        if comps.scheme.isEmpty {
            return "missing scheme: '\(raw)'"
        }
        if comps.scheme != "http" && comps.scheme != "https" {
            return "non-http(s) scheme not allowed: '\(raw)'"
        }
        if comps.host.isEmpty {
            return "missing host: '\(raw)'"
        }
        // Reject ambiguous encoded separators in the *entry* path so
        // attackers can't poison the allow-list itself.
        if hasAmbiguousPathSeparators(comps.rawPath) {
            return "ambiguous encoded separator in path: '\(raw)'"
        }
        return nil
    }

    // MARK: Matching

    /// Does `url` satisfy `entry`?
    ///
    /// Rules:
    /// 1. Origin (scheme+host[:port]) must match exactly.
    /// 2. If the entry has no path (or just `"/"`), all paths are
    ///    allowed.
    /// 3. If the entry has a path, it matches on **segment
    ///    boundaries**: `https://x/v1/` allows `/v1` and `/v1/users`
    ///    but rejects `/v10` and `/v1-admin`.
    /// 4. URLs containing `%2f` or `%5c` (encoded separators) in the
    ///    path are rejected for path-scoped entries — they can be
    ///    used to bypass segment-boundary matching.
    public static func matches(url: String, entry: String) -> Bool {
        guard let parsed = parseURL(url),
              let entryParsed = parseURL(entry)
        else { return false }

        if parsed.origin != entryParsed.origin { return false }

        let entryPath = entryParsed.path
        if entryPath.isEmpty || entryPath == "/" {
            return true
        }

        // Reject ambiguous separators in the URL when the entry is
        // path-scoped — they could let `/v1/%2f..%2fadmin` slip past.
        if hasAmbiguousPathSeparators(parsed.rawPath) {
            return false
        }

        // Segment-boundary check. Match if path == prefix, or
        // path == prefix-without-trailing-slash, or path starts with
        // prefix-with-trailing-slash.
        let normalizedPrefix = entryPath.hasSuffix("/")
            ? String(entryPath.dropLast()) : entryPath
        return parsed.path == normalizedPrefix
            || parsed.path.hasPrefix(normalizedPrefix + "/")
    }

    /// Does `url` match *any* entry?
    public static func isAllowed(_ url: String,
                                 entries: [AllowedURLEntry]) -> Bool
    {
        for entry in entries {
            if matches(url: url, entry: entry.url) {
                return true
            }
        }
        return false
    }

    /// Headers a matching transform-bearing entry would inject for
    /// this URL. Returns `nil` if no entry has transforms or no entry
    /// matches with transforms attached.
    public static func transformedHeaders(
        for url: String,
        entries: [AllowedURLEntry]
    ) -> [String: String]? {
        var merged: [String: String] = [:]
        var any = false
        for entry in entries where !entry.transforms.isEmpty {
            if matches(url: url, entry: entry.url) {
                any = true
                for t in entry.transforms {
                    for (k, v) in t.headers {
                        merged[k] = v
                    }
                }
            }
        }
        return any ? merged : nil
    }

    // MARK: URL parsing

    /// Minimal URL parser used by the allow-list. Returns `nil` for
    /// malformed input. Lowercases the scheme and host (per RFC 3986)
    /// for stable comparison; preserves the path verbatim.
    public static func parseURL(_ s: String) -> ParsedURL? {
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        // Use BOTH the percent-decoded path (for prefix matching) and
        // the raw percent-encoded path (so the ambiguous-separator
        // check can spot `%2f` / `%5c`, which `URL.path` would
        // already have decoded away).
        let path = url.path
        let rawPath = URLComponents(string: s)?.percentEncodedPath ?? path
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return ParsedURL(scheme: scheme, host: host, path: path,
                         rawPath: rawPath, port: url.port, origin: origin)
    }

    public struct ParsedURL: Sendable, Equatable {
        public var scheme: String
        public var host: String
        /// Percent-decoded path — for prefix matching.
        public var path: String
        /// Percent-encoded path — for the ambiguous-separator check.
        public var rawPath: String
        public var port: Int?
        public var origin: String
    }

    // MARK: Helpers

    private static func hasAmbiguousPathSeparators(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("%2f") || lower.contains("%5c")
            || lower.contains("\\")
    }
}
