import ArgumentParser
import BashInterpreter
import Foundation

/// `curl [OPTIONS] URL` — HTTP client. See README for supported flags.
///
/// Network access is **deny-by-default**: the shell's
/// ``Shell/networkConfig`` must contain a non-empty allow-list (or
/// ``NetworkConfig/dangerouslyAllowFullInternetAccess`` must be `true`)
/// before any URL will resolve.
public struct CurlCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "curl",
        abstract: "HTTP client (sandbox-aware)."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then URL.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        return try await Self.run(argv: rawArgv, fetcher: nil)
    }

    // Test seam: same behaviour as `execute(shell:)` but lets
    // callers inject a pre-built `SecureFetcher` (typically wrapping
    // a mock `NetworkFetcher`). When `injectedFetcher` is `nil`,
    // curl builds one from `Shell.bashCurrent.networkConfig` — production path.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func run(argv: [String],

                           fetcher injectedFetcher: SecureFetcher?
    ) async throws -> ExitStatus {
        let rawArgv = argv
        var opts = ParsedOptions()
        do {
            opts = try parse(rawArgv)
        } catch CurlParseError.missingURL {
            Shell.bashCurrent.stderr("curl: no URL specified\n")
            return ExitStatus(2)
        } catch let CurlParseError.unknownOption(opt) {
            Shell.bashCurrent.stderr("curl: option \(opt): is unknown\n")
            return ExitStatus(2)
        } catch let CurlParseError.argumentRequired(opt) {
            Shell.bashCurrent.stderr("curl: option \(opt): requires an argument\n")
            return ExitStatus(2)
        } catch {
            Shell.bashCurrent.stderr("curl: \(error)\n")
            return ExitStatus(2)
        }

        // Configure: load body from --data-binary @file references.
        var body: Data?
        var requestHeaders = opts.headers
        var method = opts.method ?? (opts.body != nil ? "POST" : "GET")
        if opts.headRequest {
            method = "HEAD"
        }

        if let raw = opts.body {
            switch raw {
            case .string(let str):
                body = Data(str.utf8)
            case .urlEncodedFields(let pairs):
                body = Data(pairs.map { encodeForm($0) }
                                  .joined(separator: "&").utf8)
                if requestHeaders["Content-Type"] == nil {
                    requestHeaders["Content-Type"] =
                        "application/x-www-form-urlencoded"
                }
            case .multipart(let parts):
                let boundary = "----SwiftBashFormBoundary\(UUID().uuidString)"
                body = encodeMultipart(parts: parts, boundary: boundary)
                requestHeaders["Content-Type"] =
                    "multipart/form-data; boundary=\(boundary)"
            case .fromFile(let path):
                do {
                    body = try await Shell.bashCurrent.readDataAtPath(path)
                } catch {
                    Shell.bashCurrent.stderr("curl: can't read \(path)\n")
                    return ExitStatus(26) // CURLE_READ_ERROR
                }
            }
        }

        // Default headers.
        if requestHeaders["User-Agent"] == nil {
            requestHeaders["User-Agent"] = "swift-bash-curl/0.1"
        }
        if let agent = opts.userAgent { requestHeaders["User-Agent"] = agent }
        if let ref = opts.referer { requestHeaders["Referer"] = ref }
        if let auth = opts.basicAuth {
            let raw = "\(auth.user):\(auth.password)"
            requestHeaders["Authorization"] =
                "Basic " + Data(raw.utf8).base64EncodedString()
        }

        // -G: convert body → query string and force GET (the whole
        // point of -G is to send what was -d as a URL query, not a body).
        var targetURL = opts.url
        if opts.getMode, let pairs = bodyAsPairs(opts.body) {
            targetURL = appendQuery(to: targetURL, pairs: pairs) ?? targetURL
            body = nil
            if opts.method == nil { method = "GET" }
        }

        // Build (or reuse) a SecureFetcher.
        let fetcher: SecureFetcher
        let effectiveTimeout: TimeInterval
        if let injected = injectedFetcher {
            fetcher = injected
            effectiveTimeout = opts.maxTimeSeconds
                ?? injected.config.timeoutSeconds
        } else {
            guard let netConfig = Shell.bashCurrent.networkConfig else {
                Shell.bashCurrent.stderr(
                    "curl: (7) Network access denied: no network configured: "
                    + "\(targetURL.absoluteString)\n")
                return ExitStatus(7)
            }
            var effectiveConfig = netConfig
            if let timeout = opts.maxTimeSeconds { effectiveConfig.timeoutSeconds = timeout }
            do {
                fetcher = try SecureFetcher(config: effectiveConfig)
            } catch let err as NetworkError {
                Shell.bashCurrent.stderr("curl: (\(err.exitCode)) \(err.description)\n")
                return ExitStatus(err.exitCode)
            }
            effectiveTimeout = effectiveConfig.timeoutSeconds
        }

        let req = NetworkRequest(
            url: targetURL,
            method: method,
            headers: requestHeaders,
            body: body,
            timeoutSeconds: effectiveTimeout)

        if opts.verbose {
            traceRequest(req)
        }

        let response: NetworkResponse
        do {
            response = try await fetcher.fetch(req)
        } catch let err as NetworkError {
            if !opts.silent || opts.showError {
                Shell.bashCurrent.stderr("curl: (\(err.exitCode)) \(err.description)\n")
            }
            return ExitStatus(err.exitCode)
        }

        if opts.verbose {
            traceResponse(response)
        }

        // -f: bail on 4xx/5xx without writing the body.
        if opts.failOnError, response.status >= 400 {
            if !opts.silent || opts.showError {
                Shell.bashCurrent.stderr(
                    "curl: (22) The requested URL returned error: "
                    + "\(response.status)\n")
            }
            return ExitStatus(22) // CURLE_HTTP_RETURNED_ERROR
        }

        // Write headers if -i / -I (HEAD request also implies headers).
        var output = Data()
        if opts.includeHeaders || opts.headRequest {
            output.append(Data(
                "HTTP/1.1 \(response.status) \(response.statusText)\r\n".utf8))
            for key in response.headers.keys.sorted() {
                output.append(Data("\(key): \(response.headers[key] ?? "")\r\n".utf8))
            }
            output.append(Data("\r\n".utf8))
        }
        if !opts.headRequest {
            output.append(response.body)
        }

        // Choose where to write the body.
        if let path = opts.outputPath {
            do {
                try await Shell.bashCurrent.fileSystem.writeData(
                    output, to: Shell.bashCurrent.resolvePath(path), append: false)
            } catch {
                Shell.bashCurrent.stderr("curl: can't write \(path)\n")
                return ExitStatus(23) // CURLE_WRITE_ERROR
            }
        } else if opts.remoteName {
            let name = (targetURL.lastPathComponent.isEmpty
                        ? "index.html" : targetURL.lastPathComponent)
            do {
                try await Shell.bashCurrent.fileSystem.writeData(
                    output, to: Shell.bashCurrent.resolvePath(name), append: false)
            } catch {
                Shell.bashCurrent.stderr("curl: can't write \(name)\n")
                return ExitStatus(23)
            }
        } else {
            Shell.bashCurrent.stdout(output)
        }

        if let format = opts.writeOut {
            Shell.bashCurrent.stdout(formatWriteOut(format, response: response))
        }

        return .success
    }
}

// MARK: - Parsing

private struct ParsedOptions {
    var url: URL = URL(string: "http://invalid.invalid")!
    var method: String?
    var headers: [String: String] = [:]
    var body: CurlBody?
    var outputPath: String?
    var remoteName: Bool = false
    var includeHeaders: Bool = false
    var headRequest: Bool = false
    var verbose: Bool = false
    var silent: Bool = false
    var showError: Bool = false
    var failOnError: Bool = false
    var basicAuth: (user: String, password: String)?
    var userAgent: String?
    var referer: String?
    var writeOut: String?
    var maxTimeSeconds: TimeInterval?
    var getMode: Bool = false
}

extension CurlCommand {

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    fileprivate static func parse(_ argv: [String]) throws -> ParsedOptions {
        var opts = ParsedOptions()
        var sawURL = false
        var pendingFormFields: [(String, String)] = []
        var pendingMultipart: [MultipartPart] = []

        // Real curl accepts combined boolean short-flag bundles like `-sS`.
        // Done in-loop (not as a pre-pass) so option arguments such as the
        // body in `curl -d -sS …` are not mistaken for flag bundles.
        var idx = 0
        while idx < argv.count {
            let arg = argv[idx]
            if expandBundle(arg, into: &opts) { idx += 1; continue }
            if arg == "--" {
                idx += 1
                while idx < argv.count {
                    if !sawURL, let parsed = URL(string: argv[idx]) {
                        opts.url = parsed; sawURL = true
                    }
                    idx += 1
                }
                break
            }
            switch arg {
            case "-X", "--request":
                opts.method = try requireArg(argv, idx, name: arg)
                idx += 2
            case "-H", "--header":
                let header = try requireArg(argv, idx, name: arg)
                if let (key, value) = splitHeader(header) {
                    opts.headers[key] = value
                }
                idx += 2
            case "-d", "--data", "--data-ascii":
                let str = try requireArg(argv, idx, name: arg)
                appendBody(str, to: &opts.body, urlencode: false)
                idx += 2
            case "--data-raw":
                let str = try requireArg(argv, idx, name: arg)
                opts.body = .string(str)
                idx += 2
            case "--data-binary":
                let str = try requireArg(argv, idx, name: arg)
                if str.hasPrefix("@") {
                    opts.body = .fromFile(String(str.dropFirst()))
                } else {
                    opts.body = .string(str)
                }
                idx += 2
            case "--data-urlencode":
                let str = try requireArg(argv, idx, name: arg)
                let (key, value) = splitFormField(str)
                pendingFormFields.append((key, value))
                opts.body = .urlEncodedFields(pendingFormFields)
                idx += 2
            case "-F", "--form":
                let str = try requireArg(argv, idx, name: arg)
                let (key, value) = splitFormField(str)
                pendingMultipart.append(MultipartPart(
                    name: key, value: value, filename: nil, contentType: nil))
                opts.body = .multipart(pendingMultipart)
                idx += 2
            case "-G", "--get":
                opts.getMode = true; idx += 1
            case "-o", "--output":
                opts.outputPath = try requireArg(argv, idx, name: arg)
                idx += 2
            case "-O", "--remote-name":
                opts.remoteName = true; idx += 1
            case "-L", "--location":
                // Always on (security: each hop revalidated).
                idx += 1
            case "-s", "--silent":
                opts.silent = true; idx += 1
            case "-S", "--show-error":
                opts.showError = true; idx += 1
            case "-i", "--include":
                opts.includeHeaders = true; idx += 1
            case "-I", "--head":
                opts.headRequest = true; idx += 1
            case "-v", "--verbose":
                opts.verbose = true; idx += 1
            case "-f", "--fail":
                opts.failOnError = true; idx += 1
            case "-u", "--user":
                let str = try requireArg(argv, idx, name: arg)
                let parts = str.split(separator: ":", maxSplits: 1)
                let user = String(parts.first ?? "")
                let pass = parts.count > 1 ? String(parts[1]) : ""
                opts.basicAuth = (user, pass)
                idx += 2
            case "-A", "--user-agent":
                opts.userAgent = try requireArg(argv, idx, name: arg)
                idx += 2
            case "-e", "--referer":
                opts.referer = try requireArg(argv, idx, name: arg)
                idx += 2
            case "-w", "--write-out":
                opts.writeOut = try requireArg(argv, idx, name: arg)
                idx += 2
            case "-m", "--max-time":
                let raw = try requireArg(argv, idx, name: arg)
                if let val = TimeInterval(raw) { opts.maxTimeSeconds = val }
                idx += 2
            case "-k", "--insecure":
                // URLSession-backed; we don't expose cert pinning.
                idx += 1
            case "-h", "--help":
                Shell.bashCurrent.stdout(curlHelp)
                throw CurlParseError.missingURL // returns 2 from caller
            default:
                if arg.hasPrefix("-"), arg.count > 1, arg != "-" {
                    throw CurlParseError.unknownOption(arg)
                }
                // Positional URL.
                if let parsed = URL(string: arg),
                   let scheme = parsed.scheme, !scheme.isEmpty {
                    opts.url = parsed
                    sawURL = true
                } else if let parsed = URL(string: "http://" + arg),
                          let scheme = parsed.scheme, !scheme.isEmpty,
                          parsed.host != nil {
                    opts.url = parsed
                    sawURL = true
                }
                idx += 1
            }
        }
        if !sawURL { throw CurlParseError.missingURL }
        return opts
    }

    fileprivate static func expandBundle(_ arg: String,
                                         into opts: inout ParsedOptions) -> Bool {
        // `L` and `k` are accepted-and-ignored, hence the optional value.
        let flags: [Character: WritableKeyPath<ParsedOptions, Bool>?] = [
            "s": \.silent, "S": \.showError, "G": \.getMode, "O": \.remoteName,
            "i": \.includeHeaders, "I": \.headRequest, "v": \.verbose,
            "f": \.failOnError, "L": nil, "k": nil
        ]
        guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else {
            return false
        }
        let chars = Array(arg.dropFirst())
        guard chars.allSatisfy({ flags[$0] != nil }) else { return false }
        for char in chars {
            if let keyPath = flags[char] ?? nil { opts[keyPath: keyPath] = true }
        }
        return true
    }

    fileprivate static func requireArg(_ argv: [String], _ idx: Int,
                                       name: String) throws -> String {
        guard idx + 1 < argv.count else {
            throw CurlParseError.argumentRequired(name)
        }
        return argv[idx + 1]
    }
}
