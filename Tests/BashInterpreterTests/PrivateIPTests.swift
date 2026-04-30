import Testing
@testable import BashInterpreter

@Suite struct PrivateIPTests {

    // MARK: Lexical IPv4 ranges

    @Test func localhostNameTreatedAsPrivate() {
        #expect(PrivateIP.isPrivate(host: "localhost"))
        #expect(PrivateIP.isPrivate(host: "myapp.localhost"))
        #expect(PrivateIP.isPrivate(host: "Localhost"))
    }

    @Test func loopbackIPv4Private() {
        #expect(PrivateIP.isPrivate(host: "127.0.0.1"))
        #expect(PrivateIP.isPrivate(host: "127.5.1.99"))
    }

    @Test func rfc1918Ranges() {
        #expect(PrivateIP.isPrivate(host: "10.0.0.1"))
        #expect(PrivateIP.isPrivate(host: "10.255.255.255"))
        #expect(PrivateIP.isPrivate(host: "172.16.0.1"))
        #expect(PrivateIP.isPrivate(host: "172.31.255.255"))
        #expect(PrivateIP.isPrivate(host: "192.168.1.1"))
    }

    @Test func linkLocalIPv4Private() {
        #expect(PrivateIP.isPrivate(host: "169.254.1.1"))
        #expect(PrivateIP.isPrivate(host: "169.254.169.254"),
                "AWS metadata endpoint must be blocked")
    }

    @Test func cgnatRangePrivate() {
        // 100.64.0.0/10 — used by carriers; commonly internal.
        #expect(PrivateIP.isPrivate(host: "100.64.0.1"))
        #expect(PrivateIP.isPrivate(host: "100.127.255.254"))
    }

    @Test func multicastAndReservedPrivate() {
        #expect(PrivateIP.isPrivate(host: "224.0.0.1"))
        #expect(PrivateIP.isPrivate(host: "255.255.255.255"))
    }

    @Test func zeroIPPrivate() {
        #expect(PrivateIP.isPrivate(host: "0.0.0.0"))
    }

    @Test func publicIPv4NotPrivate() {
        #expect(!PrivateIP.isPrivate(host: "8.8.8.8"))
        #expect(!PrivateIP.isPrivate(host: "1.1.1.1"))
        #expect(!PrivateIP.isPrivate(host: "198.51.100.5"))
    }

    @Test func adjacentRangesNotMisclassified() {
        // 11.x is public, 9.x is public — bracketing 10/8.
        #expect(!PrivateIP.isPrivate(host: "11.0.0.1"))
        #expect(!PrivateIP.isPrivate(host: "9.255.255.255"))
        // 172.15 and 172.32 are public — bracketing 172.16/12.
        #expect(!PrivateIP.isPrivate(host: "172.15.0.1"))
        #expect(!PrivateIP.isPrivate(host: "172.32.0.1"))
    }

    // MARK: IPv6

    #if !os(Windows)
    @Test func loopbackAndUnspecifiedIPv6() {
        #expect(PrivateIP.isPrivate(host: "::1"))
        #expect(PrivateIP.isPrivate(host: "::"))
    }
    #endif

    #if !os(Windows)
    @Test func ulaIPv6Private() {
        #expect(PrivateIP.isPrivate(host: "fc00::1"))
        #expect(PrivateIP.isPrivate(host: "fd12:3456:789a::1"))
    }
    #endif

    #if !os(Windows)
    @Test func linkLocalIPv6Private() {
        #expect(PrivateIP.isPrivate(host: "fe80::1"))
    }
    #endif

    #if !os(Windows)
    @Test func ipv4MappedPrivateAddress() {
        // ::ffff:127.0.0.1 — IPv4-mapped form of loopback.
        #expect(PrivateIP.isPrivate(host: "::ffff:127.0.0.1"))
        #expect(PrivateIP.isPrivate(host: "::ffff:10.0.0.1"))
    }
    #endif

    @Test func publicIPv6NotPrivate() {
        // Google DNS over IPv6.
        #expect(!PrivateIP.isPrivate(host: "2001:4860:4860::8888"))
    }

    // MARK: Hostnames not literal IPs

    @Test func bareHostnameIsNotLexicallyPrivate() {
        // This is a *lexical* check; resolution-time comes later.
        #expect(!PrivateIP.isPrivate(host: "example.com"))
        #expect(!PrivateIP.isPrivate(host: "internal.corp"),
                "lexical check can't know what corp resolves to")
    }
}
