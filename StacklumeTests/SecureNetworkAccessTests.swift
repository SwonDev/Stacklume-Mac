import Testing

@Suite("Red externa — direcciones públicas")
struct SecureNetworkAccessTests {
    @Test("Acepta direcciones públicas IPv4 e IPv6")
    func acceptsPublicAddresses() {
        for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2a00:1450:4003:80d::200e"] {
            #expect(AssistantHostResolver.isPublicNumericAddress(address))
        }
    }

    @Test("Rechaza loopback, privadas, reservadas y IPv4 mapeada")
    func rejectsNonPublicAddresses() {
        let rejected = [
            "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1",
            "169.254.169.254", "172.16.0.1", "192.168.1.1", "203.0.113.5",
            "::", "::1", "::ffff:127.0.0.1", "::ffff:7f00:1",
            "fc00::1", "fe80::1", "ff02::1", "64:ff9b::7f00:1",
            "2001:db8::1", "2002:7f00:1::1", "no-es-una-ip",
        ]
        for address in rejected {
            #expect(!AssistantHostResolver.isPublicNumericAddress(address))
        }
    }
}
