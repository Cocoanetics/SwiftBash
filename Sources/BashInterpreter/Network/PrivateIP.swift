import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>? = nil
        let rc = hostname.withCString { name in
            getaddrinfo(name, nil, &hints, &info)
        }
        defer { if let info { freeaddrinfo(info) } }
        if rc != 0 {
            // EAI_NONAME / EAI_NODATA: nothing to check, no rebinding risk.
            #if canImport(Darwin)
            if rc == EAI_NONAME || rc == EAI_NODATA { return [] }
            #else
            if rc == EAI_NONAME || rc == EAI_NODATA { return [] }
            #endif
            let msg = String(cString: gai_strerror(rc))
            throw NetworkError.transport(message: "DNS resolution failed: \(msg)")
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
        let rc = getnameinfo(sa, socklen_t(length),
                             &buf, socklen_t(buf.count),
                             nil, 0,
                             NI_NUMERICHOST)
        if rc != 0 { return nil }
        return String(cString: buf)
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
    /// Accepts the `::`-compressed and `::ffff:1.2.3.4` forms.
    static func parseIPv6(_ raw: String) -> [UInt8]? {
        // Strip zone identifier `%...`.
        let s = raw.split(separator: "%").first.map(String.init) ?? raw
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>? = nil
        let rc = s.withCString { getaddrinfo($0, nil, &hints, &info) }
        defer { if let info { freeaddrinfo(info) } }
        guard rc == 0, let info else { return nil }
        let sin6 = info.pointee.ai_addr.withMemoryRebound(
            to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        var addr = sin6.sin6_addr
        return withUnsafeBytes(of: &addr) { buf in
            Array(buf)
        }
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
