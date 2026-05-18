import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct CurlCommandTests {

    /// Captures every request and replays canned responses by URL.
    final class MockNet: NetworkFetcher, @unchecked Sendable {
        var responses: [String: NetworkResponse] = [:]
        var requests: [NetworkRequest] = []
        private let lock = NSLock()

        private func record(_ request: NetworkRequest) -> NetworkResponse? {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return responses[request.url.absoluteString]
        }

        func performOnce(_ request: NetworkRequest) async throws
            -> NetworkResponse {
            if let recorded = record(request) { return recorded }
            return NetworkResponse(
                status: 200, statusText: "OK",
                headers: ["Content-Type": "text/plain"],
                body: Data("ok".utf8),
                finalURL: request.url)
        }
    }

    /// Build a CapturingShell whose curl is wired to a mock fetcher.
    /// Replaces the registered `curl` with a closure that invokes
    /// `CurlCommand.run(... fetcher: secureFetcher)`.
    private func makeShell(
        config: NetworkConfig?,
        mock: MockNet,
        fileSystem: FileSystem? = nil
    ) throws -> CapturingShell {
        let cap = CapturingShell()
        if let fileSystem { cap.shell.fileSystem = fileSystem }
        cap.shell.registerStandardCommands()
        cap.shell.networkConfig = config

        let fetcher: SecureFetcher? = try config.map {
            try SecureFetcher(config: $0, fetcher: mock)
        }
        cap.shell.installShellBuiltin(name: "curl") { argv in
            try await CurlCommand.run(argv: argv, fetcher: fetcher)
        }
        return cap
    }

    // MARK: Default-deny

    @Test func curlWithoutConfigDeniedAndExits7() async throws {
        let cap = try makeShell(config: nil, mock: MockNet())
        try await cap.shell.run("curl https://example.com")
        #expect(cap.shell.lastExitStatus.code == 7)
        #expect(cap.stderr.contains("Network access denied"))
    }

    // MARK: Parsing → request

    @Test func getWithHeadersReachesFetcher() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            #"curl -H "X-Test: yes" -H "X-Other: 42" https://api.example.com/v1"#)
        #expect(mock.requests.count == 1)
        #expect(mock.requests[0].method == "GET")
        #expect(mock.requests[0].headers["X-Test"] == "yes")
        #expect(mock.requests[0].headers["X-Other"] == "42")
    }

    @Test func dataPostMethodInferredAndContentType() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                allowedMethods: [.GET, .HEAD, .POST],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            #"curl -d "name=alice&age=30" https://api.example.com/users"#)
        #expect(mock.requests.first?.method == "POST")
        #expect(mock.requests.first?.headers["Content-Type"]
                == "application/x-www-form-urlencoded")
        // Test body bytes are deterministic UTF-8; decode-only suffices.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: mock.requests.first?.body ?? Data(),
                          as: UTF8.self)
        #expect(body.contains("name") && body.contains("alice"))
    }

    @Test func explicitMethodHonoured() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                allowedMethods: [.GET, .DELETE],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            "curl -X DELETE https://api.example.com/v1/users/42")
        #expect(mock.requests.first?.method == "DELETE")
    }

    @Test func methodNotAllowedExits3() async throws {
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: MockNet())
        try await cap.shell.run(
            "curl -X POST -d hi https://api.example.com/v1")
        #expect(cap.shell.lastExitStatus.code == 3)
        #expect(cap.stderr.contains("not allowed"))
    }

    // MARK: - o file

    @Test func dashOWritesBodyToFile() async throws {
        let mock = MockNet()
        mock.responses["https://api.example.com/data"] = NetworkResponse(
            status: 200, statusText: "OK", headers: [:],
            body: Data("payload".utf8),
            finalURL: URL(string: "https://api.example.com/data")!)
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock,
            fileSystem: InMemoryFileSystem())
        try await cap.shell.run(
            "curl -o /out.bin https://api.example.com/data")
        let data = try await cap.shell.fileSystem.readData("/out.bin")
        // Test payload is deterministic UTF-8; decode-only suffices.
        // swiftlint:disable:next optional_data_string_conversion
        #expect(String(decoding: data, as: UTF8.self) == "payload")
        #expect(cap.stdout.isEmpty,
                "body should NOT also go to stdout when -o is used")
    }

    // MARK: - i (include headers)

    @Test func includeHeadersPrependsResponseLine() async throws {
        let mock = MockNet()
        mock.responses["https://api.example.com/x"] = NetworkResponse(
            status: 201, statusText: "Created",
            headers: ["Location": "/foo", "Content-Length": "5"],
            body: Data("hello".utf8),
            finalURL: URL(string: "https://api.example.com/x")!)
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run("curl -i https://api.example.com/x")
        #expect(cap.stdout.contains("HTTP/1.1 201 Created"))
        #expect(cap.stdout.contains("Location: /foo"))
        #expect(cap.stdout.hasSuffix("hello"))
    }

    // MARK: - f

    @Test func failOnHTTPErrorExits22() async throws {
        let mock = MockNet()
        mock.responses["https://api.example.com/missing"] = NetworkResponse(
            status: 404, statusText: "Not Found", headers: [:],
            body: Data("nope".utf8),
            finalURL: URL(string: "https://api.example.com/missing")!)
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run("curl -f https://api.example.com/missing")
        #expect(cap.shell.lastExitStatus.code == 22)
        #expect(!cap.stdout.contains("nope"))
    }

    // MARK: - u

    @Test func basicAuthHeaderInjected() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            "curl -u alice:secret https://api.example.com/v1")
        // base64("alice:secret") == "YWxpY2U6c2VjcmV0"
        #expect(mock.requests.first?.headers["Authorization"]
                == "Basic YWxpY2U6c2VjcmV0")
    }

    // MARK: - A

    @Test func userAgentOverride() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            #"curl -A "MyAgent/1.0" https://api.example.com"#)
        #expect(mock.requests.first?.headers["User-Agent"] == "MyAgent/1.0")
    }

    // MARK: - G

    @Test func getModeMovesDataToQueryString() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                denyPrivateRanges: false),
            mock: mock)
        try await cap.shell.run(
            "curl -G -d q=hello https://api.example.com/search")
        let req = mock.requests.first
        #expect(req?.method == "GET")
        #expect(req?.body == nil)
        #expect(req?.url.absoluteString.contains("q=hello") == true)
    }

    // MARK: Combined short-flag bundles

    @Test func combinedShortFlagsAcceptedAndDoNotMangleArguments() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [AllowedURLEntry(
                    "https://api.example.com")],
                allowedMethods: [.GET, .POST],
                denyPrivateRanges: false),
            mock: mock)
        // `-sS` and `-sSL` are flag bundles; `-sS` after `-d` is a body value.
        try await cap.shell.run("curl -sS https://api.example.com/a")
        try await cap.shell.run("curl -sSL https://api.example.com/b")
        try await cap.shell.run("curl -d -sS https://api.example.com/c")
        #expect(cap.shell.lastExitStatus.code == 0)
        #expect(!cap.stderr.contains("unknown option"))
        #expect(mock.requests.count == 3)
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: mock.requests[2].body ?? Data(),
                          as: UTF8.self)
        #expect(body == "-sS")
    }

    // MARK: Header transform

    @Test func transformInjectsCredentialAtFetchBoundary() async throws {
        let mock = MockNet()
        let cap = try makeShell(
            config: NetworkConfig(
                allowedURLPrefixes: [
                    AllowedURLEntry(
                        url: "https://gateway.example.com",
                        transforms: [HeaderTransform(headers:
                            ["Authorization": "Bearer TOKEN"])])
                ],
                denyPrivateRanges: false),
            mock: mock)
        // Script doesn't see TOKEN — it's injected at the fetch boundary.
        try await cap.shell.run(
            "curl https://gateway.example.com/api/v1")
        #expect(mock.requests.first?.headers["Authorization"]
                == "Bearer TOKEN")
    }
}
