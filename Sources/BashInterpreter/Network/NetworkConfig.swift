import Foundation

/// Top-level network policy attached to a ``Shell`` via
/// ``Shell/networkConfig``. **Default-deny:** when the shell's config
/// is `nil` (or the allow-list is empty), `curl` and any other
/// network-using command must report `Network access denied` and exit
/// with status `7` (matching curl's `CURLE_COULDNT_CONNECT`).
///
/// Mirrors just-bash's design: every network operation goes through a
/// ``SecureFetcher`` that consults this config; there is intentionally
/// no second path that could bypass the allow-list.
public struct NetworkConfig: Sendable {

    /// Allow-list entries. Each is a full URL prefix:
    ///
    /// - `"https://api.example.com"` — origin-only; any path under
    ///   that scheme+host is allowed.
    /// - `"https://api.example.com/v1/"` — origin + path prefix; only
    ///   paths matching at segment boundaries are allowed.
    ///
    /// An entry can carry header *transforms* that get injected at the
    /// fetch boundary — see ``AllowedURLEntry/transforms``.
    public var allowedURLPrefixes: [AllowedURLEntry]

    /// Methods scripts may use. Defaults to `[.GET, .HEAD]` so a script
    /// can read but not mutate without explicit opt-in.
    public var allowedMethods: Set<HTTPMethod>

    /// Bypass the allow-list entirely. Use only in trusted environments.
    /// Even when `true`, ``denyPrivateRanges`` still applies.
    public var dangerouslyAllowFullInternetAccess: Bool

    /// Reject any URL whose hostname is (or resolves to) a private /
    /// loopback / link-local IP. Defends against SSRF and DNS-rebinding
    /// attacks. Default `true` — flip to `false` only when calling
    /// genuinely localhost endpoints.
    public var denyPrivateRanges: Bool

    /// Max redirect hops to follow. Each hop is independently
    /// re-validated against the allow-list. Default 20.
    public var maxRedirects: Int

    /// Request timeout in seconds. Default 30.
    public var timeoutSeconds: TimeInterval

    /// Max response body size in bytes. Default 10 MiB. Larger
    /// responses fail with ``NetworkError/responseTooLarge(_:)``.
    public var maxResponseSize: Int

    public init(
        allowedURLPrefixes: [AllowedURLEntry] = [],
        allowedMethods: Set<HTTPMethod> = [.GET, .HEAD],
        dangerouslyAllowFullInternetAccess: Bool = false,
        denyPrivateRanges: Bool = true,
        maxRedirects: Int = 20,
        timeoutSeconds: TimeInterval = 30,
        maxResponseSize: Int = 10 * 1024 * 1024
    ) {
        self.allowedURLPrefixes = allowedURLPrefixes
        self.allowedMethods = allowedMethods
        self.dangerouslyAllowFullInternetAccess =
            dangerouslyAllowFullInternetAccess
        self.denyPrivateRanges = denyPrivateRanges
        self.maxRedirects = maxRedirects
        self.timeoutSeconds = timeoutSeconds
        self.maxResponseSize = maxResponseSize
    }
}

/// One entry in ``NetworkConfig/allowedURLPrefixes``. The `transforms`
/// array, when present, supplies headers that are *injected at the
/// fetch boundary* whenever this entry matches — so secrets live in
/// the host config, never in the script's environment.
public struct AllowedURLEntry: Sendable, Equatable {
    public var url: String
    public var transforms: [HeaderTransform]

    public init(url: String, transforms: [HeaderTransform] = []) {
        self.url = url
        self.transforms = transforms
    }

    /// Convenience — most entries have no transforms.
    public init(_ url: String) {
        self.url = url
        self.transforms = []
    }
}

/// Headers to *override or add* before a request leaves the sandbox.
/// Identical-name headers from the script are replaced.
public struct HeaderTransform: Sendable, Equatable {
    public var headers: [String: String]
    public init(headers: [String: String]) { self.headers = headers }
}

/// HTTP methods the network layer recognises. Other verbs (LINK,
/// UNLINK, …) are not currently supported.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS
}

// MARK: Result

/// What ``SecureFetcher/fetch(_:)`` returns. Body is raw bytes — never
/// pre-decoded — so curl can hand binary content to its caller.
public struct NetworkResponse: Sendable {
    public var status: Int
    public var statusText: String
    public var headers: [String: String]
    public var body: Data
    /// The final URL after all redirects; matches curl's `effective_url`.
    public var finalURL: URL

    public init(status: Int, statusText: String,
                headers: [String: String], body: Data,
                finalURL: URL)
    {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

// MARK: Errors

/// Errors thrown by the network layer. The `curl` command maps each to
/// its conventional CURLE_* exit code — see ``exitCode``.
public enum NetworkError: Error, CustomStringConvertible, Sendable, Equatable {
    /// URL not on the allow-list (or no allow-list configured).
    case accessDenied(url: String, reason: String)
    /// A redirect target is not on the allow-list.
    case redirectNotAllowed(url: String)
    /// Request method isn't in ``NetworkConfig/allowedMethods``.
    case methodNotAllowed(method: String, allowed: [String])
    /// Body exceeded ``NetworkConfig/maxResponseSize``.
    case responseTooLarge(maxBytes: Int)
    /// Followed `maxRedirects` hops without resolving.
    case tooManyRedirects(max: Int)
    /// Hostname is (or resolves to) a private/loopback IP.
    case privateAddress(url: String, reason: String)
    /// URL string couldn't be parsed.
    case invalidURL(String)
    /// Underlying transport failed (DNS, TLS, connection).
    case transport(message: String)
    /// Request timed out.
    case timedOut

    public var description: String {
        switch self {
        case .accessDenied(let url, let reason):
            return "Network access denied: \(reason): \(url)"
        case .redirectNotAllowed(let url):
            return "Redirect target not in allow-list: \(url)"
        case .methodNotAllowed(let method, let allowed):
            return "HTTP method '\(method)' not allowed. "
                + "Allowed methods: \(allowed.joined(separator: ", "))"
        case .responseTooLarge(let max):
            return "Response body too large (max: \(max) bytes)"
        case .tooManyRedirects(let max):
            return "Too many redirects (max: \(max))"
        case .privateAddress(let url, let reason):
            return "Network access denied: \(reason): \(url)"
        case .invalidURL(let s):
            return "Could not parse URL: \(s)"
        case .transport(let m):
            return m
        case .timedOut:
            return "Request timed out"
        }
    }

    /// Mapping to curl exit codes (`CURLE_*` in `<curl/curl.h>`).
    public var exitCode: Int32 {
        switch self {
        case .invalidURL:                     return 3   // URL_MALFORMAT
        case .methodNotAllowed:               return 3
        case .accessDenied, .redirectNotAllowed,
             .privateAddress, .transport:    return 7   // COULDNT_CONNECT
        case .tooManyRedirects:               return 47  // TOO_MANY_REDIRECTS
        case .responseTooLarge:               return 56  // RECV_ERROR
        case .timedOut:                       return 28  // OPERATION_TIMEDOUT
        }
    }
}
