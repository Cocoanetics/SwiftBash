import BashInterpreter
import Foundation

// Body helpers, multipart encoding, trace formatters, and --write-out
// expansion live here so CurlCommand.swift can stay under file_length.

internal enum CurlBody {
    case string(String)
    case urlEncodedFields([(String, String)])
    case multipart([MultipartPart])
    case fromFile(String)
}

internal struct MultipartPart {
    var name: String
    var value: String          // for now, text-only `-F name=value`
    var filename: String?
    var contentType: String?
}

internal enum CurlParseError: Error {
    case missingURL
    case unknownOption(String)
    case argumentRequired(String)
}

internal func appendBody(_ str: String, to body: inout CurlBody?,
                         urlencode: Bool) {
    // Multiple `-d` calls concatenate with `&`.
    let pair = splitFormField(str)
    let pairs: [(String, String)] = pair.0.isEmpty
        ? [("", str)] : [pair]

    if case .urlEncodedFields(let existing) = body {
        body = .urlEncodedFields(existing + pairs)
    } else if case .string(let existing) = body {
        body = .string(existing + "&" + str)
    } else {
        body = .urlEncodedFields(pairs)
    }
}

internal func splitFormField(_ str: String) -> (String, String) {
    if let idx = str.firstIndex(of: "=") {
        let key = String(str[..<idx])
        let value = String(str[str.index(after: idx)...])
        return (key, value)
    }
    return ("", str)
}

internal func splitHeader(_ str: String) -> (String, String)? {
    guard let idx = str.firstIndex(of: ":") else { return nil }
    let key = String(str[..<idx]).trimmingCharacters(in: .whitespaces)
    let value = String(str[str.index(after: idx)...])
                    .trimmingCharacters(in: .whitespaces)
    return (key, value)
}

internal func encodeForm(_ pair: (String, String)) -> String {
    let keyEnc = pair.0.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed) ?? pair.0
    let valEnc = pair.1.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed) ?? pair.1
    return keyEnc.isEmpty ? valEnc : "\(keyEnc)=\(valEnc)"
}

internal func bodyAsPairs(_ body: CurlBody?) -> [(String, String)]? {
    guard let body else { return nil }
    if case .urlEncodedFields(let pairs) = body { return pairs }
    if case .string(let str) = body, !str.isEmpty {
        return [(splitFormField(str).0, splitFormField(str).1)]
    }
    return nil
}

internal func appendQuery(to url: URL,
                          pairs: [(String, String)]) -> URL? {
    guard var comps = URLComponents(url: url,
                                    resolvingAgainstBaseURL: false)
    else { return nil }
    var items = comps.queryItems ?? []
    for (key, value) in pairs {
        items.append(URLQueryItem(name: key, value: value))
    }
    comps.queryItems = items
    return comps.url
}

internal func encodeMultipart(parts: [MultipartPart],
                              boundary: String) -> Data {
    var out = Data()
    for part in parts {
        out.append(Data("--\(boundary)\r\n".utf8))
        var headers = "Content-Disposition: form-data; name=\"\(part.name)\""
        if let fname = part.filename { headers += "; filename=\"\(fname)\"" }
        out.append(Data((headers + "\r\n").utf8))
        if let ctype = part.contentType {
            out.append(Data("Content-Type: \(ctype)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(Data(part.value.utf8))
        out.append(Data("\r\n".utf8))
    }
    out.append(Data("--\(boundary)--\r\n".utf8))
    return out
}

// MARK: - Verbose tracing

internal func traceRequest(_ req: NetworkRequest) {
    Shell.bashCurrent.stderr("> \(req.method) \(req.url.path.isEmpty ? "/" : req.url.path)"
                 + " HTTP/1.1\r\n")
    if let host = req.url.host { Shell.bashCurrent.stderr("> Host: \(host)\r\n") }
    for key in req.headers.keys.sorted() {
        Shell.bashCurrent.stderr("> \(key): \(req.headers[key] ?? "")\r\n")
    }
    Shell.bashCurrent.stderr(">\r\n")
}

internal func traceResponse(_ resp: NetworkResponse) {
    Shell.bashCurrent.stderr("< HTTP/1.1 \(resp.status) \(resp.statusText)\r\n")
    for key in resp.headers.keys.sorted() {
        Shell.bashCurrent.stderr("< \(key): \(resp.headers[key] ?? "")\r\n")
    }
    Shell.bashCurrent.stderr("<\r\n")
}

// MARK: - --write-out

// swiftlint:disable:next cyclomatic_complexity
internal func formatWriteOut(_ format: String,
                             response: NetworkResponse) -> String {
    var out = ""
    var idx = format.startIndex
    while idx < format.endIndex {
        let char = format[idx]
        if char == "%", format.index(after: idx) < format.endIndex {
            let next = format[format.index(after: idx)]
            if next == "{" {
                if let close = format[idx...].firstIndex(of: "}") {
                    let name = String(
                        format[format.index(idx, offsetBy: 2)..<close])
                    out += writeOutVariable(name, response: response)
                    idx = format.index(after: close)
                    continue
                }
            }
            switch next {
            case "%": out.append("%")
            case "\n": out.append("\n")
            default:
                out += writeOutVariable(String(next), response: response)
            }
            idx = format.index(idx, offsetBy: 2)
            continue
        }
        if char == "\\", format.index(after: idx) < format.endIndex {
            let next = format[format.index(after: idx)]
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default: out.append(next)
            }
            idx = format.index(idx, offsetBy: 2)
            continue
        }
        out.append(char)
        idx = format.index(after: idx)
    }
    return out
}

internal func writeOutVariable(_ name: String,
                               response: NetworkResponse) -> String {
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

internal let curlHelp = """
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
