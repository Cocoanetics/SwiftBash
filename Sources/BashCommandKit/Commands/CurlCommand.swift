import ArgumentParser
import BashInterpreter
import Foundation

/// `curl [OPTIONS] URL` — HTTP client.
///
/// Network access is **deny-by-default**: the shell's
/// ``Shell/networkConfig`` must contain a non-empty allow-list (or
/// ``NetworkConfig/dangerouslyAllowFullInternetAccess`` must be `true`)
/// before any URL will resolve.
///
/// ### Supported flags
///
/// | Flag | Effect |
/// |------|--------|
/// | `-X METHOD` / `--request` | HTTP method (default GET; POST when -d) |
/// | `-H 'K: V'` / `--header` | Add a request header (repeatable) |
/// | `-d STR` / `--data` / `--data-ascii` | URL-encoded request body |
/// | `--data-raw STR` | Body verbatim, no `@file` reading |
/// | `--data-binary STR` / `@file` | Body verbatim from string or file |
/// | `--data-urlencode KEY=VAL` | URL-encode VAL into a body field |
/// | `-F 'name=value'` | Multipart form field (basic) |
/// | `-G` / `--get` | Send `-d` data as URL query instead of body |
/// | `-o FILE` / `--output` | Write body to FILE instead of stdout |
/// | `-O` / `--remote-name` | Save to a file named after the URL |
/// | `-L` / `--location` | Follow redirects (always on for security) |
/// | `-s` / `--silent` | Suppress progress (currently no-op; we never print progress) |
/// | `-S` / `--show-error` | With -s, still show error messages |
/// | `-i` / `--include` | Include response headers in output |
/// | `-I` / `--head` | HEAD request, output headers |
/// | `-v` / `--verbose` | Trace request + response on stderr |
/// | `-f` / `--fail` | Exit 22 on HTTP 4xx/5xx, no body output |
/// | `-u USER:PASS` / `--user` | HTTP Basic auth |
/// | `-A AGENT` / `--user-agent` | Override `User-Agent` |
/// | `-e URL` / `--referer` | Set `Referer` |
/// | `-w FORMAT` / `--write-out` | Print FORMAT after the response |
/// | `--max-time SEC` | Override the configured timeout |
/// | `-k` / `--insecure` | Ignored — `URLSession` honours system trust |
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

    /// Test seam: same behaviour as ``execute(shell:)`` but lets
    /// callers inject a pre-built ``SecureFetcher`` (typically wrapping
    /// a mock ``NetworkFetcher``). When `injectedFetcher` is `nil`,
    /// curl builds one from `Shell.current.networkConfig` — production path.
    public static func run(argv: [String],
                           
                           fetcher injectedFetcher: SecureFetcher?
    ) async throws -> ExitStatus {
        let rawArgv = argv
        var opts = ParsedOptions()
        do {
            opts = try parse(rawArgv)
        } catch let CurlParseError.missingURL {
            Shell.current.stderr("curl: no URL specified\n")
            return ExitStatus(2)
        } catch let CurlParseError.unknownOption(o) {
            Shell.current.stderr("curl: option \(o): is unknown\n")
            return ExitStatus(2)
        } catch let CurlParseError.argumentRequired(o) {
            Shell.current.stderr("curl: option \(o): requires an argument\n")
            return ExitStatus(2)
        } catch {
            Shell.current.stderr("curl: \(error)\n")
            return ExitStatus(2)
        }

        // Configure: load body from --data-binary @file references.
        var body: Data? = nil
        var requestHeaders = opts.headers
        var method = opts.method ?? (opts.body != nil ? "POST" : "GET")
        if opts.headRequest {
            method = "HEAD"
        }

        if let raw = opts.body {
            switch raw {
            case .string(let s):
                body = Data(s.utf8)
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
                    body = try await Shell.current.readDataAtPath(path)
                } catch {
                    Shell.current.stderr("curl: can't read \(path)\n")
                    return ExitStatus(26) // CURLE_READ_ERROR
                }
            }
        }

        // Default headers.
        if requestHeaders["User-Agent"] == nil {
            requestHeaders["User-Agent"] = "swift-bash-curl/0.1"
        }
        if let ua = opts.userAgent { requestHeaders["User-Agent"] = ua }
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
            guard let netConfig = Shell.current.networkConfig else {
                Shell.current.stderr(
                    "curl: (7) Network access denied: no network configured: "
                    + "\(targetURL.absoluteString)\n")
                return ExitStatus(7)
            }
            var effectiveConfig = netConfig
            if let t = opts.maxTimeSeconds { effectiveConfig.timeoutSeconds = t }
            do {
                fetcher = try SecureFetcher(config: effectiveConfig)
            } catch let err as NetworkError {
                Shell.current.stderr("curl: (\(err.exitCode)) \(err.description)\n")
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
                Shell.current.stderr("curl: (\(err.exitCode)) \(err.description)\n")
            }
            return ExitStatus(err.exitCode)
        }

        if opts.verbose {
            traceResponse(response)
        }

        // -f: bail on 4xx/5xx without writing the body.
        if opts.failOnError, response.status >= 400 {
            if !opts.silent || opts.showError {
                Shell.current.stderr(
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
            for k in response.headers.keys.sorted() {
                output.append(Data("\(k): \(response.headers[k] ?? "")\r\n".utf8))
            }
            output.append(Data("\r\n".utf8))
        }
        if !opts.headRequest {
            output.append(response.body)
        }

        // Choose where to write the body.
        if let path = opts.outputPath {
            do {
                try await Shell.current.fileSystem.writeData(
                    output, to: Shell.current.resolvePath(path), append: false)
            } catch {
                Shell.current.stderr("curl: can't write \(path)\n")
                return ExitStatus(23) // CURLE_WRITE_ERROR
            }
        } else if opts.remoteName {
            let name = (targetURL.lastPathComponent.isEmpty
                        ? "index.html" : targetURL.lastPathComponent)
            do {
                try await Shell.current.fileSystem.writeData(
                    output, to: Shell.current.resolvePath(name), append: false)
            } catch {
                Shell.current.stderr("curl: can't write \(name)\n")
                return ExitStatus(23)
            }
        } else {
            Shell.current.stdout(output)
        }

        if let format = opts.writeOut {
            Shell.current.stdout(formatWriteOut(format, response: response))
        }

        return .success
    }
}

// MARK: - Parsing

private struct ParsedOptions {
    var url: URL = URL(string: "http://invalid.invalid")!
    var method: String? = nil
    var headers: [String: String] = [:]
    var body: CurlBody? = nil
    var outputPath: String? = nil
    var remoteName: Bool = false
    var includeHeaders: Bool = false
    var headRequest: Bool = false
    var verbose: Bool = false
    var silent: Bool = false
    var showError: Bool = false
    var failOnError: Bool = false
    var basicAuth: (user: String, password: String)? = nil
    var userAgent: String? = nil
    var referer: String? = nil
    var writeOut: String? = nil
    var maxTimeSeconds: TimeInterval? = nil
    var getMode: Bool = false
}

private enum CurlBody {
    case string(String)
    case urlEncodedFields([(String, String)])
    case multipart([MultipartPart])
    case fromFile(String)
}

private struct MultipartPart {
    var name: String
    var value: String          // for now, text-only `-F name=value`
    var filename: String?
    var contentType: String?
}

private enum CurlParseError: Error {
    case missingURL
    case unknownOption(String)
    case argumentRequired(String)
}

extension CurlCommand {

    fileprivate static func parse(_ argv: [String]) throws -> ParsedOptions
    {
        var opts = ParsedOptions()
        var sawURL = false
        var pendingFormFields: [(String, String)] = []
        var pendingMultipart: [MultipartPart] = []

        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                i += 1
                while i < argv.count {
                    if !sawURL, let u = URL(string: argv[i]) {
                        opts.url = u; sawURL = true
                    }
                    i += 1
                }
                break
            }
            switch a {
            case "-X", "--request":
                opts.method = try requireArg(argv, i, name: a)
                i += 2
            case "-H", "--header":
                let h = try requireArg(argv, i, name: a)
                if let (k, v) = splitHeader(h) {
                    opts.headers[k] = v
                }
                i += 2
            case "-d", "--data", "--data-ascii":
                let s = try requireArg(argv, i, name: a)
                appendBody(s, to: &opts.body, urlencode: false)
                i += 2
            case "--data-raw":
                let s = try requireArg(argv, i, name: a)
                opts.body = .string(s)
                i += 2
            case "--data-binary":
                let s = try requireArg(argv, i, name: a)
                if s.hasPrefix("@") {
                    opts.body = .fromFile(String(s.dropFirst()))
                } else {
                    opts.body = .string(s)
                }
                i += 2
            case "--data-urlencode":
                let s = try requireArg(argv, i, name: a)
                let (k, v) = splitFormField(s)
                pendingFormFields.append((k, v))
                opts.body = .urlEncodedFields(pendingFormFields)
                i += 2
            case "-F", "--form":
                let s = try requireArg(argv, i, name: a)
                let (k, v) = splitFormField(s)
                pendingMultipart.append(MultipartPart(
                    name: k, value: v, filename: nil, contentType: nil))
                opts.body = .multipart(pendingMultipart)
                i += 2
            case "-G", "--get":
                opts.getMode = true; i += 1
            case "-o", "--output":
                opts.outputPath = try requireArg(argv, i, name: a)
                i += 2
            case "-O", "--remote-name":
                opts.remoteName = true; i += 1
            case "-L", "--location":
                // Always on (security: each hop revalidated).
                i += 1
            case "-s", "--silent":
                opts.silent = true; i += 1
            case "-S", "--show-error":
                opts.showError = true; i += 1
            case "-i", "--include":
                opts.includeHeaders = true; i += 1
            case "-I", "--head":
                opts.headRequest = true; i += 1
            case "-v", "--verbose":
                opts.verbose = true; i += 1
            case "-f", "--fail":
                opts.failOnError = true; i += 1
            case "-u", "--user":
                let s = try requireArg(argv, i, name: a)
                let parts = s.split(separator: ":", maxSplits: 1)
                let user = String(parts.first ?? "")
                let pass = parts.count > 1 ? String(parts[1]) : ""
                opts.basicAuth = (user, pass)
                i += 2
            case "-A", "--user-agent":
                opts.userAgent = try requireArg(argv, i, name: a)
                i += 2
            case "-e", "--referer":
                opts.referer = try requireArg(argv, i, name: a)
                i += 2
            case "-w", "--write-out":
                opts.writeOut = try requireArg(argv, i, name: a)
                i += 2
            case "--max-time":
                let raw = try requireArg(argv, i, name: a)
                if let v = TimeInterval(raw) { opts.maxTimeSeconds = v }
                i += 2
            case "-k", "--insecure":
                // URLSession-backed; we don't expose cert pinning.
                i += 1
            case "-h", "--help":
                Shell.current.stdout(curlHelp)
                throw CurlParseError.missingURL // returns 2 from caller
            default:
                if a.hasPrefix("-"), a.count > 1, a != "-" {
                    throw CurlParseError.unknownOption(a)
                }
                // Positional URL.
                if let u = URL(string: a),
                   let scheme = u.scheme, !scheme.isEmpty
                {
                    opts.url = u
                    sawURL = true
                } else if let u = URL(string: "http://" + a),
                          let scheme = u.scheme, !scheme.isEmpty,
                          u.host != nil
                {
                    opts.url = u
                    sawURL = true
                }
                i += 1
            }
        }
        if !sawURL { throw CurlParseError.missingURL }
        return opts
    }

    fileprivate static func requireArg(_ argv: [String], _ i: Int,
                                       name: String) throws -> String
    {
        guard i + 1 < argv.count else {
            throw CurlParseError.argumentRequired(name)
        }
        return argv[i + 1]
    }
}

// MARK: - Body helpers

private func appendBody(_ s: String, to body: inout CurlBody?,
                        urlencode: Bool)
{
    // Multiple `-d` calls concatenate with `&`.
    let pair = splitFormField(s)
    let pairs: [(String, String)] = pair.0.isEmpty
        ? [("", s)] : [pair]

    if case .urlEncodedFields(let existing) = body {
        body = .urlEncodedFields(existing + pairs)
    } else if case .string(let existing) = body {
        body = .string(existing + "&" + s)
    } else {
        body = .urlEncodedFields(pairs)
    }
}

private func splitFormField(_ s: String) -> (String, String) {
    if let idx = s.firstIndex(of: "=") {
        let k = String(s[..<idx])
        let v = String(s[s.index(after: idx)...])
        return (k, v)
    }
    return ("", s)
}

private func splitHeader(_ s: String) -> (String, String)? {
    guard let idx = s.firstIndex(of: ":") else { return nil }
    let k = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
    let v = String(s[s.index(after: idx)...])
                    .trimmingCharacters(in: .whitespaces)
    return (k, v)
}

private func encodeForm(_ pair: (String, String)) -> String {
    let kEnc = pair.0.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed) ?? pair.0
    let vEnc = pair.1.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed) ?? pair.1
    return kEnc.isEmpty ? vEnc : "\(kEnc)=\(vEnc)"
}

private func bodyAsPairs(_ body: CurlBody?) -> [(String, String)]? {
    guard let body else { return nil }
    if case .urlEncodedFields(let pairs) = body { return pairs }
    if case .string(let s) = body, !s.isEmpty {
        return [(splitFormField(s).0, splitFormField(s).1)]
    }
    return nil
}

private func appendQuery(to url: URL,
                         pairs: [(String, String)]) -> URL?
{
    guard var comps = URLComponents(url: url,
                                    resolvingAgainstBaseURL: false)
    else { return nil }
    var items = comps.queryItems ?? []
    for (k, v) in pairs {
        items.append(URLQueryItem(name: k, value: v))
    }
    comps.queryItems = items
    return comps.url
}

private func encodeMultipart(parts: [MultipartPart],
                             boundary: String) -> Data
{
    var out = Data()
    for p in parts {
        out.append(Data("--\(boundary)\r\n".utf8))
        var headers = "Content-Disposition: form-data; name=\"\(p.name)\""
        if let fn = p.filename { headers += "; filename=\"\(fn)\"" }
        out.append(Data((headers + "\r\n").utf8))
        if let ct = p.contentType {
            out.append(Data("Content-Type: \(ct)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(Data(p.value.utf8))
        out.append(Data("\r\n".utf8))
    }
    out.append(Data("--\(boundary)--\r\n".utf8))
    return out
}

// MARK: - Verbose tracing

private func traceRequest(_ req: NetworkRequest) {
    Shell.current.stderr("> \(req.method) \(req.url.path.isEmpty ? "/" : req.url.path)"
                 + " HTTP/1.1\r\n")
    if let host = req.url.host { Shell.current.stderr("> Host: \(host)\r\n") }
    for k in req.headers.keys.sorted() {
        Shell.current.stderr("> \(k): \(req.headers[k] ?? "")\r\n")
    }
    Shell.current.stderr(">\r\n")
}

private func traceResponse(_ resp: NetworkResponse) {
    Shell.current.stderr("< HTTP/1.1 \(resp.status) \(resp.statusText)\r\n")
    for k in resp.headers.keys.sorted() {
        Shell.current.stderr("< \(k): \(resp.headers[k] ?? "")\r\n")
    }
    Shell.current.stderr("<\r\n")
}

// MARK: - --write-out

private func formatWriteOut(_ format: String,
                            response: NetworkResponse) -> String
{
    var out = ""
    var i = format.startIndex
    while i < format.endIndex {
        let c = format[i]
        if c == "%", format.index(after: i) < format.endIndex {
            let next = format[format.index(after: i)]
            if next == "{" {
                if let close = format[i...].firstIndex(of: "}") {
                    let name = String(
                        format[format.index(i, offsetBy: 2)..<close])
                    out += writeOutVariable(name, response: response)
                    i = format.index(after: close)
                    continue
                }
            }
            switch next {
            case "%": out.append("%")
            case "\n": out.append("\n")
            default:
                out += writeOutVariable(String(next), response: response)
            }
            i = format.index(i, offsetBy: 2)
            continue
        }
        if c == "\\", format.index(after: i) < format.endIndex {
            let n = format[format.index(after: i)]
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default: out.append(n)
            }
            i = format.index(i, offsetBy: 2)
            continue
        }
        out.append(c)
        i = format.index(after: i)
    }
    return out
}

private func writeOutVariable(_ name: String,
                              response: NetworkResponse) -> String
{
    switch name {
    case "http_code", "response_code": return String(response.status)
    case "size_download":             return String(response.body.count)
    case "url_effective":             return response.finalURL.absoluteString
    case "content_type":
        return response.headers["Content-Type"] ?? ""
    default:
        return ""
    }
}

// MARK: - Help

private let curlHelp = """
USAGE: curl [OPTIONS] URL

Network access is gated by the shell's networkConfig: an empty
allow-list rejects every URL with `Network access denied`.

  -X METHOD         HTTP method
  -H 'K: V'         Add a request header (repeatable)
  -d STR            URL-encoded request body
  --data-binary X   Body verbatim; @file reads from a file
  --data-urlencode  K=V → URL-encoded into the body
  -F 'name=value'   Multipart form field
  -G                Send -d as ?query instead of body
  -o FILE           Write body to FILE
  -O                Save to a file named after the URL
  -L                Follow redirects (each hop re-validated)
  -s                Silent
  -i                Include response headers in output
  -I                HEAD request
  -v                Trace request/response on stderr
  -f                Exit 22 on HTTP 4xx/5xx
  -u USER:PASS      Basic auth
  -A AGENT          User-Agent
  -e URL            Referer
  -w FORMAT         Print FORMAT after the response
  --max-time SEC    Override the configured timeout

Exit codes follow curl's CURLE_* convention (7 = denied, 22 = HTTP
error with -f, 28 = timeout, 47 = too many redirects, 56 = response
too large).
"""
