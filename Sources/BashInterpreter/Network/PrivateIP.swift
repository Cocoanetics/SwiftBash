import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

#if os(Windows)
/// One-shot Winsock initializer. WSAStartup is reference-counted by
/// the OS but we only ever call it once per process.
private let _wsaStartupOnce: Bool = {
    var data = WSAData()
    return WSAStartup(0x0202 /* MAKEWORD(2,2) */, &data) == 0
}()
#endif

/// Private / loopback / link-local IP detection — used to defend
/// against SSRF and DNS-rebinding attacks. The fetcher consults this
/// twice per request when ``NetworkConfig/denyPrivateRanges`` is on:
///
/// 1. **Lexical** — if the URL host parses as an IP literal, check
///    that literal against the private ranges.
/// 2. **Resolution-time** — for hostnames, run `getaddrinfo` and
///    check every returned address. Catches a domain that resolves
///    to `127.0.0.1` on second connection.
public enum PrivateIP {

    /// True if `host` is *literally* a private/loopback/link-local IP
    /// address, OR a name that should be treated as private regardless
    /// of resolution (`localhost`, `*.localhost`).
    public static func isPrivate(host: String) -> Bool {
        if host.isEmpty { return false }
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if let ipv4 = parseIPv4(host) {
            return isPrivateIPv4(ipv4)
        }
        // IPv6 literals in URLs are wrapped in `[...]`; URL.host strips
        // the brackets but leaves the address. `parseIPv6` is tolerant.
        if let ipv6 = parseIPv6(host) {
            return isPrivateIPv6(ipv6)
        }
        return false
    }

    /// Resolve `hostname` via `getaddrinfo` and return all answers.
    /// Throws `NetworkError.transport` on resolver errors other than
    /// `EAI_NONAME`/`EAI_NODATA` (which return `[]`, since "no such
    /// host" can't pose a rebinding risk).
    public static func resolve(_ hostname: String) async throws -> [String] {
        return try await Task.detached(priority: .utility) {
            try resolveSync(hostname)
        }.value
    }

    private static func resolveSync(_ hostname: String) throws -> [String] {
        #if os(Windows)
        _ = _wsaStartupOnce
        #endif
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        // Linux's Glibc imports SOCK_STREAM as the enum value
        // `__socket_type.SOCK_STREAM`; addrinfo.ai_socktype wants
        // Int32. Darwin / WinSDK / Android import it as a raw Int32
        // already.
        #if canImport(Glibc) && !canImport(Bionic) && !canImport(Android)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>? = nil
        let rc = hostname.withCString { name in
            getaddrinfo(name, nil, &hints, &info)
        }
        defer { if let info { freeaddrinfo(info) } }
        if rc != 0 {
            // EAI_NONAME / EAI_NODATA: nothing to check, no rebinding risk.
            // EAI_NODATA was removed from POSIX in 2008; Linux's headers
            // don't define it any more, so guard it on Darwin only.
            #if canImport(Darwin)
            if rc == EAI_NONAME || rc == EAI_NODATA { return [] }
            #else
            if rc == EAI_NONAME { return [] }
            #endif
            #if os(Windows)
            // Windows gai_strerror returns a wchar_t*. Easier to just
            // report the numeric code than bridge the wide string.
            throw NetworkError.transport(
                message: "DNS resolution failed (WSA \(rc))")
            #else
            let msg = String(cString: gai_strerror(rc))
            throw NetworkError.transport(message: "DNS resolution failed: \(msg)")
            #endif
        }

        var out: [String] = []
        var cur = info
        while let node = cur {
            if let saPtr = node.pointee.ai_addr {
                if let s = describeAddress(saPtr,
                                           length: Int(node.pointee.ai_addrlen))
                {
                    out.append(s)
                }
            }
            cur = node.pointee.ai_next
        }
        return out
    }

    /// Render a `sockaddr` as the textual address (no port).
    private static func describeAddress(
        _ sa: UnsafePointer<sockaddr>, length: Int
    ) -> String? {
        var buf = [Int8](repeating: 0, count: Int(NI_MAXHOST))
        // Windows' getnameinfo takes DWORD for the buffer-size args
        // (POSIX uses socklen_t). Bionic's getnameinfo uses size_t,
        // which Swift bridges to Int.
        #if os(Windows)
        let bufSize = DWORD(buf.count)
        #elseif canImport(Bionic) || canImport(Android)
        let bufSize = buf.count
        #else
        let bufSize = socklen_t(buf.count)
        #endif
        let rc = getnameinfo(sa, socklen_t(length),
                             &buf, bufSize,
                             nil, 0,
                             NI_NUMERICHOST)
        if rc != 0 { return nil }
        // Truncate at the trailing NUL and decode as UTF-8 (the
        // deprecated `String(cString: array)` initializer scans for
        // the NUL itself).
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: IPv4 ranges

    /// Returns the four octets of `s` if it parses as a dotted-decimal
    /// IPv4 literal; `nil` otherwise.
    static func parseIPv4(_ s: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard let n = UInt32(p), n <= 255 else { return nil }
            bytes.append(UInt8(n))
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// True if the v4 address is in any of the standard private/loopback/
    /// link-local/CGNAT/multicast/broadcast ranges.
    static func isPrivateIPv4(_ a: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (b0, b1, _, _) = a
        switch b0 {
        case 0:    return true                  // 0.0.0.0/8
        case 10:   return true                  // 10.0.0.0/8
        case 127:  return true                  // 127.0.0.0/8 loopback
        case 169 where b1 == 254: return true   // 169.254.0.0/16 link-local
        case 172 where (16...31).contains(b1): return true // 172.16/12
        case 192 where b1 == 168: return true   // 192.168/16
        case 192 where b1 == 0: return true     // 192.0.0/24 (IETF)
        case 100 where (64...127).contains(b1): return true // 100.64/10 CGNAT
        case 224...239: return true             // multicast
        case 240...255: return true             // reserved + 255.255.255.255
        default: return false
        }
    }

    // MARK: IPv6 ranges

    /// Parse an IPv6 literal (with optional `%zone`) into 16 bytes.
    /// Accepts the `::`-compressed and `::ffff:1.2.3.4` forms. Pure
    /// Swift — no platform sockets — so the SSRF lexical check works
    /// the same way on macOS / Linux / Windows.
    static func parseIPv6(_ raw: String) -> [UInt8]? {
        // Strip zone identifier `%...`.
        let s = raw.split(separator: "%").first.map(String.init) ?? raw
        if s.isEmpty { return nil }
        // At most one `::` allowed.
        let doubleColonRanges = s.ranges(of: "::")
        if doubleColonRanges.count > 1 { return nil }

        let head: [Substring]
        let tail: [Substring]
        if let dc = doubleColonRanges.first {
            let h = s[s.startIndex..<dc.lowerBound]
            let t = s[dc.upperBound..<s.endIndex]
            head = h.isEmpty ? [] : h.split(separator: ":", omittingEmptySubsequences: false)
            tail = t.isEmpty ? [] : t.split(separator: ":", omittingEmptySubsequences: false)
        } else {
            head = s.split(separator: ":", omittingEmptySubsequences: false)
            tail = []
        }

        // Helper: parse one segment (either a 1-4 hex group or, if
        // it's the very last segment and contains a dot, an embedded
        // IPv4 literal).
        func segmentBytes(_ seg: Substring, isLast: Bool) -> [UInt8]? {
            if isLast, seg.contains(".") {
                guard let v4 = parseIPv4(String(seg)) else { return nil }
                return [v4.0, v4.1, v4.2, v4.3]
            }
            guard !seg.isEmpty, seg.count <= 4,
                  seg.allSatisfy({ $0.isHexDigit }),
                  let v = UInt16(seg, radix: 16)
            else { return nil }
            return [UInt8(v >> 8), UInt8(v & 0xff)]
        }

        var headBytes: [UInt8] = []
        for (i, seg) in head.enumerated() {
            let isLast = doubleColonRanges.isEmpty
                && tail.isEmpty
                && i == head.count - 1
            guard let bs = segmentBytes(seg, isLast: isLast) else { return nil }
            headBytes.append(contentsOf: bs)
        }
        var tailBytes: [UInt8] = []
        for (i, seg) in tail.enumerated() {
            guard let bs = segmentBytes(seg, isLast: i == tail.count - 1)
            else { return nil }
            tailBytes.append(contentsOf: bs)
        }

        if doubleColonRanges.isEmpty {
            return headBytes.count == 16 ? headBytes : nil
        }
        // `::` present — zero-fill the middle.
        let total = headBytes.count + tailBytes.count
        if total > 16 { return nil }
        var out = headBytes
        out.append(contentsOf: [UInt8](repeating: 0, count: 16 - total))
        out.append(contentsOf: tailBytes)
        return out
    }

    /// Reject IPv6 ULAs (`fc00::/7`), link-local (`fe80::/10`),
    /// loopback (`::1`), unspecified (`::`), and IPv4-mapped private
    /// addresses.
    static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // Loopback: `::1`
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        // Unspecified: `::`
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        // ULA: `fc00::/7` — first byte is `1111110x`.
        if (bytes[0] & 0xfe) == 0xfc { return true }
        // Link-local: `fe80::/10`.
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
        // IPv4-mapped: `::ffff:a.b.c.d` — last 4 bytes are the v4 addr.
        let mappedPrefix: [UInt8] = [
            0,0,0,0, 0,0,0,0, 0,0, 0xff,0xff
        ]
        if Array(bytes[0..<12]) == mappedPrefix {
            let v4 = (bytes[12], bytes[13], bytes[14], bytes[15])
            return isPrivateIPv4(v4)
        }
        return false
    }
}
