import Testing
@testable import SoyehtCore

@Suite struct ServerEndpointResolverTests {
    @Test("Wi-Fi LAN with local bareHost prefers bareHost first")
    func localNetworkLocalBareHostFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "192.168.1.50",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: true,
            tailnetActive: true
        )

        #expect(hosts == ["192.168.1.50", "macstudio.local", "macstudio"])
    }

    @Test("Wi-Fi LAN with tailnet bareHost prefers local labels first")
    func localNetworkRemoteBareHostPrefersLocalLabel() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.103.149.48",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: true,
            tailnetActive: true
        )

        #expect(hosts == ["macstudio.local", "100.103.149.48", "macstudio"])
    }

    @Test("Tailnet active without LAN prefers MagicDNS first")
    func tailnetOnlyPrefersMagicDNSFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.103.149.48",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: false,
            tailnetActive: true
        )

        #expect(hosts == ["macstudio", "100.103.149.48", "macstudio.local"])
    }

    @Test("No LAN or tailnet prefers bareHost first")
    func noNetworkSignalsPrefersBareHostFirst() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "100.103.149.48",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: false,
            tailnetActive: false
        )

        #expect(hosts == ["100.103.149.48", "macstudio.local", "macstudio"])
    }

    @Test("Host ordering dedupes while preserving first occurrence")
    func dedupesHosts() {
        let hosts = ServerEndpointResolver.orderedHosts(
            bareHost: "macstudio",
            localLabels: ["macstudio.local", "macstudio.local"],
            magicDNSLabels: ["macstudio", "macstudio-alt", "macstudio-alt"],
            localNetworkActive: false,
            tailnetActive: false
        )

        #expect(hosts == ["macstudio", "macstudio.local", "macstudio-alt"])
    }

    @Test("Resolved endpoint preserves ports and strips simple host port suffix")
    func resolvedEndpointCarriesPorts() {
        let endpoint = ServerEndpointResolver.resolve(
            bareHost: "192.168.1.50:57414",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: true,
            tailnetActive: true,
            presencePort: 57414,
            attachPort: 57415,
            bootstrapPort: 8092
        )

        #expect(endpoint.orderedHosts == ["192.168.1.50", "macstudio.local", "macstudio"])
        #expect(endpoint.presencePort == 57414)
        #expect(endpoint.attachPort == 57415)
        #expect(endpoint.bootstrapPort == 8092)
    }

    @Test("Resolver is stateless across different machines")
    func resolverIsPerMachine() {
        let macEndpoint = ServerEndpointResolver.resolve(
            bareHost: "100.103.149.48",
            localLabels: ["macstudio.local"],
            magicDNSLabels: ["macstudio"],
            localNetworkActive: false,
            tailnetActive: true
        )
        let linuxEndpoint = ServerEndpointResolver.resolve(
            bareHost: "100.88.10.20",
            localLabels: ["bignix.local"],
            magicDNSLabels: ["bignix"],
            localNetworkActive: false,
            tailnetActive: true
        )

        #expect(macEndpoint.orderedHosts == ["macstudio", "100.103.149.48", "macstudio.local"])
        #expect(linuxEndpoint.orderedHosts == ["bignix", "100.88.10.20", "bignix.local"])
    }

    @Test("Local network host classifier matches LAN and Bonjour ranges")
    func localNetworkHostClassifier() {
        #expect(ServerEndpointResolver.isLocalNetworkHost("10.0.0.5"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("172.16.0.1"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("172.31.255.255"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("192.168.1.10"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("127.0.0.1"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("169.254.1.20"))
        #expect(ServerEndpointResolver.isLocalNetworkHost("macstudio.local"))

        #expect(!ServerEndpointResolver.isLocalNetworkHost("8.8.8.8"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("172.15.0.1"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("172.32.0.1"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("100.103.149.48"))
        #expect(!ServerEndpointResolver.isLocalNetworkHost("example.com"))
    }
}
