import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct SecureFetcherTests {

    // MARK: Mock fetcher

    /// Records every request it gets and returns canned responses by
    /// URL path. Uses an `NSLock` wrapped in a sync helper so we don't
    /// touch it from an `async` context directly.
    final class MockFetcher: NetworkFetcher, @unchecked Sendable {
        var responses: [String: NetworkResponse] = [:]
        var requests: [NetworkRequest] = []
        private let lock = NSLock()

        private func record(
            _ request: NetworkRequest
        ) -> NetworkResponse? {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return responses[request.url.absoluteString]
        }

        func performOnce(_ request: NetworkRequest) async throws
            -> NetworkResponse
        {
            if let r = record(request) { return r }
            // Default 200 with empty body so tests don't have to seed
            // every URL.
            return NetworkResponse(
                status: 200, statusText: "OK",
                headers: ["Content-Type": "text/plain"],
                body: Data(),
                finalURL: request.url)
        }
    }

    private func makeFetcher(
        _ config: NetworkConfig,
        mock: MockFetcher = .init()
    ) throws -> SecureFetcher {
        return try SecureFetcher(config: config, fetcher: mock)
    }

    private func req(_ url: String,
                     method: String = "GET",
                     headers: [String: String] = [:],
                     body: Data? = nil) -> NetworkRequest
    {
        NetworkRequest(url: URL(string: url)!,
                       method: method,
                       headers: headers,
                       body: body)
    }

    // MARK: Default-deny

    @Test func defaultEmptyAllowListBlocksEverything() async throws {
        let fetcher = try makeFetcher(NetworkConfig(
            denyPrivateRanges: false))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(req("https://api.example.com"))
        }
        if case .accessDenied = err { } else {
            Issue.record("expected accessDenied, got \(String(describing: err))")
        }
    }

    @Test func allowedURLPasses() async throws {
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false))
        let resp = try await fetcher.fetch(req("https://api.example.com/v1"))
        #expect(resp.status == 200)
    }

    @Test func pathOutsidePrefixDenied() async throws {
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [
                AllowedURLEntry("https://api.example.com/v1/")],
            denyPrivateRanges: false))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(
                req("https://api.example.com/v2/users"))
        }
        if case .accessDenied = err { } else {
            Issue.record("expected accessDenied, got \(String(describing: err))")
        }
    }

    // MARK: Method gate

    @Test func nonGetHeadDeniedByDefault() async throws {
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(req("https://api.example.com",
                                            method: "POST"))
        }
        if case .methodNotAllowed = err { } else {
            Issue.record("expected methodNotAllowed, got \(String(describing: err))")
        }
    }

    @Test func explicitlyAllowedMethodPasses() async throws {
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            allowedMethods: [.GET, .HEAD, .POST],
            denyPrivateRanges: false))
        let resp = try await fetcher.fetch(req(
            "https://api.example.com", method: "POST"))
        #expect(resp.status == 200)
    }

    // MARK: Header transforms

    @Test func transformInjectsHeaderAtFetchBoundary() async throws {
        let mock = MockFetcher()
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [
                AllowedURLEntry(
                    url: "https://gateway.example.com",
                    transforms: [HeaderTransform(headers:
                        ["Authorization": "Bearer secret"])])
            ],
            denyPrivateRanges: false), mock: mock)

        _ = try await fetcher.fetch(req("https://gateway.example.com/v1"))
        let observed = mock.requests.first?.headers["Authorization"]
        #expect(observed == "Bearer secret")
    }

    @Test func transformOverridesScriptSuppliedHeader() async throws {
        // Even if the script set its own Authorization, the transform
        // wins — that's the whole point: secrets stay outside the box.
        let mock = MockFetcher()
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [
                AllowedURLEntry(
                    url: "https://gateway.example.com",
                    transforms: [HeaderTransform(headers:
                        ["Authorization": "Bearer real"])])
            ],
            denyPrivateRanges: false), mock: mock)

        _ = try await fetcher.fetch(req(
            "https://gateway.example.com",
            headers: ["Authorization": "Bearer fake"]))
        #expect(mock.requests.first?.headers["Authorization"] == "Bearer real")
    }

    // MARK: Redirects

    @Test func redirectFollowsAllowedHop() async throws {
        let mock = MockFetcher()
        mock.responses["https://api.example.com/start"] = NetworkResponse(
            status: 302, statusText: "Found",
            headers: ["Location": "https://api.example.com/dest"],
            body: Data(),
            finalURL: URL(string: "https://api.example.com/start")!)
        mock.responses["https://api.example.com/dest"] = NetworkResponse(
            status: 200, statusText: "OK", headers: [:],
            body: Data("hello".utf8),
            finalURL: URL(string: "https://api.example.com/dest")!)

        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false), mock: mock)
        let resp = try await fetcher.fetch(req(
            "https://api.example.com/start"))
        #expect(resp.status == 200)
        #expect(String(decoding: resp.body, as: UTF8.self) == "hello")
        #expect(mock.requests.count == 2,
                "should have followed the 302")
    }

    @Test func redirectToDeniedTargetThrows() async throws {
        let mock = MockFetcher()
        mock.responses["https://api.example.com/start"] = NetworkResponse(
            status: 302, statusText: "Found",
            // Try to redirect *off* the allow-list — must be rejected.
            headers: ["Location": "https://attacker.example.org/leak"],
            body: Data(),
            finalURL: URL(string: "https://api.example.com/start")!)

        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false), mock: mock)
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(
                req("https://api.example.com/start"))
        }
        if case .redirectNotAllowed = err { } else {
            Issue.record("expected redirectNotAllowed, got \(String(describing: err))")
        }
    }

    @Test func tooManyRedirects() async throws {
        let mock = MockFetcher()
        // Each /n redirects to /n+1, ad infinitum.
        for n in 0..<50 {
            let url = "https://api.example.com/r\(n)"
            mock.responses[url] = NetworkResponse(
                status: 302, statusText: "Found",
                headers: ["Location":
                    "https://api.example.com/r\(n + 1)"],
                body: Data(),
                finalURL: URL(string: url)!)
        }
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false,
            maxRedirects: 5), mock: mock)

        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(
                req("https://api.example.com/r0"))
        }
        if case .tooManyRedirects(let max) = err {
            #expect(max == 5)
        } else {
            Issue.record("expected tooManyRedirects, got \(String(describing: err))")
        }
    }

    @Test func postRedirectedTo303BecomesGet() async throws {
        let mock = MockFetcher()
        mock.responses["https://api.example.com/post"] = NetworkResponse(
            status: 303, statusText: "See Other",
            headers: ["Location": "https://api.example.com/get"],
            body: Data(),
            finalURL: URL(string: "https://api.example.com/post")!)
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            allowedMethods: [.GET, .POST],
            denyPrivateRanges: false), mock: mock)
        _ = try await fetcher.fetch(req(
            "https://api.example.com/post",
            method: "POST",
            body: Data("payload".utf8)))
        // Second request: method downgraded, body stripped.
        #expect(mock.requests.count == 2)
        #expect(mock.requests.last?.method == "GET")
        #expect(mock.requests.last?.body == nil)
    }

    // MARK: Response size

    @Test func oversizedResponseRejected() async throws {
        let mock = MockFetcher()
        mock.responses["https://api.example.com/big"] = NetworkResponse(
            status: 200, statusText: "OK", headers: [:],
            body: Data(repeating: 0, count: 200),
            finalURL: URL(string: "https://api.example.com/big")!)
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://api.example.com")],
            denyPrivateRanges: false,
            maxResponseSize: 100), mock: mock)
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(
                req("https://api.example.com/big"))
        }
        if case .responseTooLarge = err { } else {
            Issue.record("expected responseTooLarge, got \(String(describing: err))")
        }
    }

    // MARK: Private-IP guard

    @Test func privateIPInURLBlocked() async throws {
        // Even when the allow-list permits this URL, the private-range
        // guard intervenes.
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("http://127.0.0.1:8080")],
            denyPrivateRanges: true))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(req("http://127.0.0.1:8080/x"))
        }
        if case .privateAddress = err { } else {
            Issue.record("expected privateAddress, got \(String(describing: err))")
        }
    }

    @Test func awsMetadataEndpointBlocked() async throws {
        // 169.254.169.254 — classic SSRF target. With private-range
        // guard on, this must not even reach the fetcher.
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [
                AllowedURLEntry("http://169.254.169.254")
            ],
            denyPrivateRanges: true))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(req(
                "http://169.254.169.254/latest/meta-data/"))
        }
        if case .privateAddress = err { } else {
            Issue.record("expected privateAddress, got \(String(describing: err))")
        }
    }

    // MARK: dangerouslyAllowFullInternetAccess escape hatch

    @Test func fullInternetAccessSkipsAllowList() async throws {
        let mock = MockFetcher()
        let fetcher = try makeFetcher(NetworkConfig(
            allowedURLPrefixes: [],
            dangerouslyAllowFullInternetAccess: true,
            denyPrivateRanges: false), mock: mock)
        _ = try await fetcher.fetch(req("https://anywhere.example.com"))
        #expect(mock.requests.count == 1)
    }

    @Test func fullInternetAccessStillEnforcesPrivateRange() async throws {
        // Even with the escape hatch, you cannot reach 127.0.0.1.
        let fetcher = try makeFetcher(NetworkConfig(
            dangerouslyAllowFullInternetAccess: true,
            denyPrivateRanges: true))
        let err = await #expect(throws: NetworkError.self) {
            _ = try await fetcher.fetch(req("http://127.0.0.1/admin"))
        }
        if case .privateAddress = err { } else {
            Issue.record("expected privateAddress, got \(String(describing: err))")
        }
    }
}
