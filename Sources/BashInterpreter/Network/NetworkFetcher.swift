import Foundation
#if canImport(FoundationNetworking)
// Linux Foundation splits networking out into a separate module so
// `URLSession`, `URLRequest`, `URLSessionTask`, `HTTPURLResponse`,
// and the matching delegates live there. Apple platforms re-export
// them from the umbrella `Foundation`.
import FoundationNetworking
#endif

/// Low-level fetch primitive — what the ``SecureFetcher`` calls into
/// after it has validated a request. Exposed as a protocol so tests
/// can inject a deterministic mock without touching the network.
public protocol NetworkFetcher: Sendable {

    /// Perform a single round-trip. The fetcher MUST NOT follow
    /// redirects on its own — ``SecureFetcher`` re-validates each hop
    /// itself so every redirect target gets gated.
    func performOnce(_ request: NetworkRequest) async throws -> NetworkResponse
}

/// What ``NetworkFetcher`` consumes. We reuse `URLRequest` semantics
/// but go through a Sendable struct so the fetcher protocol stays
/// independent of `URLRequest`'s evolving Foundation APIs.
public struct NetworkRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeoutSeconds: TimeInterval

    public init(url: URL,
                method: String,
                headers: [String: String] = [:],
                body: Data? = nil,
                timeoutSeconds: TimeInterval = 30)
    {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

/// `URLSession`-backed fetcher. The session is configured to NOT
/// follow redirects automatically (the secure layer handles them).
///
/// `@unchecked Sendable` because Linux's `URLSession` (in
/// `FoundationNetworking`) doesn't yet declare Sendable conformance.
/// `URLSession` itself is documented as thread-safe; the fetcher
/// holds it immutably and only calls `data(for:)` / configuration
/// readers — no cross-actor mutation.
public struct URLSessionFetcher: NetworkFetcher, @unchecked Sendable {

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Use a bare delegate to refuse redirects — `SecureFetcher`
        // performs its own redirect loop with per-hop validation.
        self.session = URLSession(
            configuration: config,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil)
    }

    public func performOnce(
        _ request: NetworkRequest
    ) async throws -> NetworkResponse {
        var urlReq = URLRequest(url: request.url,
                                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                timeoutInterval: request.timeoutSeconds)
        urlReq.httpMethod = request.method
        for (k, v) in request.headers { urlReq.setValue(v, forHTTPHeaderField: k) }
        if let body = request.body { urlReq.httpBody = body }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlReq)
        } catch let err as URLError where err.code == .timedOut {
            throw NetworkError.timedOut
        } catch let err as URLError {
            throw NetworkError.transport(message: err.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport(message: "non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                // Header names are case-insensitive in HTTP. Normalise to
                // canonical form (Title-Case-With-Hyphens) so callers can
                // look them up without guessing.
                headers[canonicalize(headerName: k)] = v
            }
        }
        return NetworkResponse(
            status: http.statusCode,
            statusText: HTTPURLResponse.localizedString(
                forStatusCode: http.statusCode),
            headers: headers,
            body: data,
            finalURL: http.url ?? request.url)
    }

    private func canonicalize(headerName: String) -> String {
        // "content-length" → "Content-Length"
        let parts = headerName.split(separator: "-",
                                     omittingEmptySubsequences: false)
        return parts.map { p -> String in
            guard let first = p.first else { return "" }
            return String(first).uppercased() + p.dropFirst().lowercased()
        }.joined(separator: "-")
    }

    private final class NoRedirectDelegate: NSObject,
        URLSessionTaskDelegate, @unchecked Sendable
    {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Block the redirect; we'll see the 3xx in the response and
            // make a fresh validated request.
            completionHandler(nil)
        }
    }
}
