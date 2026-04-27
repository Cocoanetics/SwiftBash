import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wraps a ``NetworkFetcher`` with full ``NetworkConfig`` enforcement:
/// allow-list match, method gating, header transforms, redirect loop
/// with per-hop validation, response-size cap, private-IP guard.
///
/// Construct one per ``Shell`` and call ``fetch(_:)``. Throws
/// ``NetworkError`` on policy violations; transport / timeout errors
/// also surface as `NetworkError`.
public struct SecureFetcher: Sendable {

    public let config: NetworkConfig
    private let inner: NetworkFetcher

    public init(config: NetworkConfig, fetcher: NetworkFetcher? = nil) throws {
        // Fail fast on bad allow-list entries — except when full
        // internet access is on (validation is moot).
        if !config.dangerouslyAllowFullInternetAccess {
            let errors = URLAllowList.validate(config.allowedURLPrefixes)
            if !errors.isEmpty {
                throw NetworkError.transport(
                    message: "Invalid network allow-list: "
                        + errors.joined(separator: "; "))
            }
        }
        self.config = config
        self.inner = fetcher ?? URLSessionFetcher()
    }

    /// Run `request`, following redirects up to `maxRedirects`, with
    /// every hop independently re-validated against the allow-list and
    /// the private-IP guard. Returns the *final* response.
    public func fetch(_ request: NetworkRequest) async throws -> NetworkResponse {
        // Method gate.
        if !config.dangerouslyAllowFullInternetAccess {
            let allowedNames = config.allowedMethods
                .map(\.rawValue).sorted()
            if !allowedNames.contains(request.method.uppercased()) {
                throw NetworkError.methodNotAllowed(
                    method: request.method,
                    allowed: allowedNames)
            }
        }

        var current = request
        try await checkAllowed(url: current.url)
        // Inject any header transforms attached to the matching entry.
        applyTransforms(to: &current)

        var hops = 0
        while true {
            let resp = try await inner.performOnce(current)

            // Cap response size *after* the body comes back; the
            // Foundation API doesn't stream chunks back, so we can only
            // validate post-hoc. Future improvement: stream.
            if resp.body.count > config.maxResponseSize {
                throw NetworkError.responseTooLarge(
                    maxBytes: config.maxResponseSize)
            }

            // Not a redirect → done.
            if !isRedirect(resp.status) { return resp }

            // Redirect hop. POST/PUT/etc. redirect rules: 301/302/303
            // → GET (RFC-incorrect but matches every real client);
            // 307/308 → preserve method.
            guard let location = resp.headers["Location"]
                ?? resp.headers["location"]
            else { return resp } // 3xx without Location: hand back as-is

            hops += 1
            if hops > config.maxRedirects {
                throw NetworkError.tooManyRedirects(max: config.maxRedirects)
            }

            // Resolve relative redirects against the current URL.
            guard let nextURL = URL(string: location, relativeTo: current.url)?
                    .absoluteURL
            else {
                throw NetworkError.invalidURL(location)
            }
            try await checkAllowed(url: nextURL,
                                   redirectError: true)

            var nextMethod = current.method
            var nextBody = current.body
            if resp.status == 301 || resp.status == 302 || resp.status == 303 {
                if !["GET", "HEAD"].contains(current.method.uppercased()) {
                    nextMethod = "GET"
                    nextBody = nil
                }
            }
            current = NetworkRequest(
                url: nextURL,
                method: nextMethod,
                headers: stripHopHeaders(current.headers),
                body: nextBody,
                timeoutSeconds: config.timeoutSeconds)
            applyTransforms(to: &current)
        }
    }

    // MARK: Validation

    private func checkAllowed(url: URL,
                              redirectError: Bool = false) async throws
    {
        let s = url.absoluteString
        if !config.dangerouslyAllowFullInternetAccess {
            if !URLAllowList.isAllowed(s, entries: config.allowedURLPrefixes) {
                if redirectError {
                    throw NetworkError.redirectNotAllowed(url: s)
                }
                throw NetworkError.accessDenied(
                    url: s, reason: "URL not in allow-list")
            }
        }
        // Private-range guard runs even with full internet access.
        if config.denyPrivateRanges {
            try await checkPrivateAddress(url: url)
        }
    }

    private func checkPrivateAddress(url: URL) async throws {
        guard let host = url.host, !host.isEmpty else { return }
        if PrivateIP.isPrivate(host: host) {
            throw NetworkError.privateAddress(
                url: url.absoluteString,
                reason: "private/loopback IP address blocked")
        }
        // Lexically-named host: resolve and check every answer. Catches
        // a domain that maps to a private IP.
        let isIPLiteral = (PrivateIP.parseIPv4(host) != nil)
            || (PrivateIP.parseIPv6(host) != nil)
        if isIPLiteral { return }
        let addresses = try await PrivateIP.resolve(host)
        for addr in addresses {
            if PrivateIP.isPrivate(host: addr) {
                throw NetworkError.privateAddress(
                    url: url.absoluteString,
                    reason: "hostname resolves to private/loopback IP address")
            }
        }
    }

    private func applyTransforms(to req: inout NetworkRequest) {
        guard let injected = URLAllowList.transformedHeaders(
            for: req.url.absoluteString,
            entries: config.allowedURLPrefixes)
        else { return }
        for (k, v) in injected {
            // Override script-supplied values for these names.
            req.headers[k] = v
        }
    }

    private func isRedirect(_ status: Int) -> Bool {
        return [301, 302, 303, 307, 308].contains(status)
    }

    /// Strip headers that don't make sense to forward across a hop.
    private func stripHopHeaders(_ h: [String: String]) -> [String: String] {
        let drop: Set<String> = [
            "Authorization", "Cookie", "Host", "Content-Length",
            "Content-Type", "Transfer-Encoding", "Connection",
        ]
        var out = h
        for k in drop where out[k] != nil { out.removeValue(forKey: k) }
        return out
    }
}
