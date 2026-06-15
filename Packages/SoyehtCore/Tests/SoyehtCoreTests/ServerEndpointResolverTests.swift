import Testing
@testable import SoyehtCore

@Suite struct ServerEndpointResolverTests {
    @Test("Wi-Fi LAN with local bareHost prefers bareHost first")
    func localNetworkLocalBareHostFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "192.168.1.50",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: true,
            tailnetActive: true
        )

        #expect(hosts == ["192.168.1.50", "mac-alpha.local", "mac-alpha"])
    }

    @Test("Wi-Fi LAN with tailnet bareHost prefers local labels first")
    func localNetworkRemoteBareHostPrefersLocalLabel() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.64.0.10",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: true,
            tailnetActive: true
        )

        #expect(hosts == ["mac-alpha.local", "100.64.0.10", "mac-alpha"])
    }

    @Test("Tailnet active without LAN prefers MagicDNS first")
    func tailnetOnlyPrefersMagicDNSFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.64.0.10",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: false,
            tailnetActive: true
        )

        #expect(hosts == ["mac-alpha", "100.64.0.10", "mac-alpha.local"])
    }

    @Test("No LAN or tailnet prefers bareHost first")
    func noNetworkSignalsPrefersBareHostFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.64.0.10",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: false,
            tailnetActive: false
        )

        #expect(hosts == ["100.64.0.10", "mac-alpha.local", "mac-alpha"])
    }

    @Test("Host ordering dedupes while preserving first occurrence")
    func dedupesHosts() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "mac-alpha",
            localLabels: ["mac-alpha.local", "mac-alpha.local"],
            magicDNSLabels: ["mac-alpha", "mac-alpha-alt", "mac-alpha-alt"],
            localNetworkActive: false,
            tailnetActive: false
        )

        #expect(hosts == ["mac-alpha", "mac-alpha.local", "mac-alpha-alt"])
    }

    @Test("Host labels normalize names and skip IP literals")
    func hostLabelCandidatesNormalizeAndSkipIPLiteralHosts() {
        let labels = ServerEndpointResolver.hostLabelCandidates(from: [
            "Mac Alpha",
            "mac-alpha.local",
            "100.64.0.10",
            "https://linux-alpha.test:8091/bootstrap/status",
            "[2001:db8::1]"
        ])

        #expect(labels == ["macalpha", "mac-alpha", "linux-alpha"])
    }

    @Test("Resolved endpoint preserves ports and strips simple host port suffix")
    func resolvedEndpointCarriesPorts() {
        let endpoint = ServerEndpointResolver.resolve(
            bareHost: "192.168.1.50:57414",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: true,
            tailnetActive: true,
            presencePort: 57414,
            attachPort: 57415,
            bootstrapPort: 8092
        )

        #expect(endpoint.orderedHosts == ["192.168.1.50", "mac-alpha.local", "mac-alpha"])
        #expect(endpoint.presencePort == 57414)
        #expect(endpoint.attachPort == 57415)
        #expect(endpoint.bootstrapPort == 8092)
    }

    @Test("Resolver is stateless across different machines")
    func resolverIsPerMachine() {
        let macEndpoint = ServerEndpointResolver.resolve(
            bareHost: "100.64.0.10",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: false,
            tailnetActive: true
        )
        let linuxEndpoint = ServerEndpointResolver.resolve(
            bareHost: "100.64.0.10",
            localLabels: ["linux-alpha.local"],
            magicDNSLabels: ["linux-alpha"],
            localNetworkActive: false,
            tailnetActive: true
        )

        #expect(macEndpoint.orderedHosts == ["mac-alpha", "100.64.0.10", "mac-alpha.local"])
        #expect(linuxEndpoint.orderedHosts == ["linux-alpha", "100.64.0.10", "linux-alpha.local"])
    }

    @Test("Local network host classifier matches LAN and Bonjour ranges")
    func localNetworkHostClassifier() {
        #expect(ServerEndpointResolver.isLocalNetworkHost("10.0.0.5"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("172.16.0.1"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("172.31.255.255"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("192.168.1.50"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("127.0.0.1"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("169.254.10.20"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("mac-alpha.local"))

        #expect(!ServerEndpointResolver.isLocalNetworkHost("192.0.2.10"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("198.51.100.10"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("203.0.113.10"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("100.64.0.10"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("example.com"))
    }
}
