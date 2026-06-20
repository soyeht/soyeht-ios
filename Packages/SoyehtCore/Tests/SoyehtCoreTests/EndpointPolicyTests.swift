import Foundation
import Testing
@testable import SoyehtCore

@Suite struct EndpointPolicyTests {
    @Test("Host classifier covers loopback, Tailnet, LAN, public, and unknown")
    func hostClassMatrix() {
        #expect(EndpointPolicy.hostClass(for: "localhost") == .loopback)
        #expect(HostClassifier.classify("localhost") == .loopback)
        #expect(EndpointPolicy.hostClass(for: "127.0.0.1:8091") == .loopback)
        #expect(EndpointPolicy.hostClass(for: "[::1]:8091") == .loopback)

        #expect(EndpointPolicy.hostClass(for: "100.64.0.10") == .tailnet)
        #expect(HostClassifier.isTailnetIPv4("100.64.0.10"))
        #expect(EndpointPolicy.hostClass(for: "100.127.255.254:8101") == .tailnet)
        #expect(EndpointPolicy.hostClass(for: "mac-alpha.example.ts.net") == .tailnet)
        #expect(EndpointPolicy.hostClass(for: "fd7a:115c:a1e0::10") == .tailnet)

        #expect(EndpointPolicy.hostClass(for: "mac-alpha.local") == .lan)
        #expect(EndpointPolicy.hostClass(for: "192.168.1.10") == .lan)
        #expect(EndpointPolicy.hostClass(for: "10.0.0.5:8091") == .lan)
        #expect(EndpointPolicy.hostClass(for: "172.31.255.255") == .lan)
        #expect(EndpointPolicy.hostClass(for: "169.254.1.2") == .lan)
        #expect(EndpointPolicy.hostClass(for: "fd00::10") == .lan)
        #expect(EndpointPolicy.hostClass(for: "fe80::1%en0") == .lan)
        #expect(EndpointPolicy.hostClass(for: "::ffff:192.168.1.10") == .lan)
        #expect(EndpointPolicy.hostClass(for: "::ffff:100.64.0.10") == .tailnet)

        #expect(EndpointPolicy.hostClass(for: "203.0.113.10") == .publicHost)
        #expect(EndpointPolicy.hostClass(for: "api.example.com") == .publicHost)
        #expect(EndpointPolicy.hostClass(for: "   ") == .unknown)
    }

    @Test("Admin transport preserves local plaintext and upgrades remote or Tailnet")
    func adminSchemeMatrix() {
        #expect(EndpointPolicy.adminHTTPScheme(for: "localhost") == "http")
        #expect(EndpointPolicy.adminHTTPScheme(for: "mac-alpha.local") == "http")
        #expect(EndpointPolicy.adminHTTPScheme(for: "192.168.1.10") == "http")
        #expect(EndpointPolicy.adminHTTPScheme(for: "100.64.0.10") == "https")
        #expect(EndpointPolicy.adminHTTPScheme(for: "mac-alpha.example.ts.net") == "https")
        #expect(EndpointPolicy.adminHTTPScheme(for: "api.example.com") == "https")

        #expect(EndpointPolicy.adminWebSocketScheme(for: "localhost") == "ws")
        #expect(EndpointPolicy.adminWebSocketScheme(for: "mac-alpha.local") == "ws")
        #expect(EndpointPolicy.adminWebSocketScheme(for: "100.64.0.10") == "wss")
        #expect(EndpointPolicy.webSocketScheme(for: .adminAPI, host: "100.64.0.10") == "wss")
    }

    @Test("Admin URL builder preserves route-registry encoded path segments")
    func adminURLPreservesPercentEncodedPathSegments() throws {
        let url = try #require(EndpointPolicy.adminHTTPURL(
            host: "mac-alpha.local",
            path: "/api/v1/claws/hermes%2Fagent/install"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/api/v1/claws/hermes%2Fagent/install")
    }

    @Test("Household transport allows plaintext only on loopback or Tailnet")
    func householdSchemeMatrix() {
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "http", host: "localhost") == "http")
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "http", host: "100.64.0.10") == "http")
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "http", host: "fd7a:115c:a1e0::10") == "http")
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "http", host: "192.168.1.10") == "https")
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "https", host: "192.168.1.10") == "https")
        #expect(EndpointPolicy.householdHTTPScheme(inputScheme: "ftp", host: "localhost") == nil)

        #expect(EndpointPolicy.householdWebSocketScheme(inputScheme: "http", host: "100.64.0.10") == "ws")
        #expect(EndpointPolicy.householdWebSocketScheme(inputScheme: "ws", host: "fd7a:115c:a1e0::10") == "ws")
        #expect(EndpointPolicy.householdWebSocketScheme(inputScheme: "http", host: "192.168.1.10") == "wss")
        #expect(EndpointPolicy.householdWebSocketScheme(inputScheme: "https", host: "192.168.1.10") == "wss")
    }

    @Test("Mac-local control plane WebSocket policy preserves plain WS")
    func macLocalControlPlaneWebSocketPolicy() throws {
        #expect(EndpointPolicy.macLocalControlPlaneWebSocketScheme() == "ws")
        #expect(EndpointPolicy.webSocketScheme(for: .presence, host: "100.64.0.10") == "ws")
        #expect(EndpointPolicy.webSocketScheme(for: .macLocalControlPlane, host: "mac-alpha.local") == "ws")
        #expect(EndpointPolicy.webSocketScheme(for: .bootstrapStatus, host: "localhost") == nil)
        #expect(EndpointPolicy.acceptsMacLocalControlPlaneHost("fe80::1%en0"))
        #expect(EndpointPolicy.acceptsMacLocalControlPlaneHost("::ffff:192.168.1.10"))
        #expect(!EndpointPolicy.acceptsMacLocalControlPlaneHost("203.0.113.10"))

        let presence = try #require(EndpointPolicy.macLocalPresenceWebSocketURL(
            host: "fd7a:115c:a1e0::10",
            presencePort: 57414,
            macID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        ))
        #expect(presence.absoluteString == "ws://[fd7a:115c:a1e0::10]:57414/presence?mac_id=11111111-1111-1111-1111-111111111111")

        let linkLocal = try #require(EndpointPolicy.macLocalPaneAttachWebSocketURL(
            host: "fe80::1%en0",
            attachPort: 57415,
            paneID: "pane-alpha",
            nonce: "nonce-alpha"
        ))
        #expect(linkLocal.absoluteString == "ws://[fe80::1%25en0]:57415/panes/pane-alpha/attach?nonce=nonce-alpha")
    }

    @Test("Bootstrap status is profile-aware and never produces HTTPS on engine port")
    func bootstrapStatusProfileMatrix() throws {
        let release = try #require(EndpointPolicy.bootstrapStatusBaseURL(
            forHost: "mac-alpha.example.ts.net",
            installProfile: .release
        ))
        #expect(release.scheme == "http")
        #expect(release.port == 8091)

        let dev = try #require(EndpointPolicy.bootstrapStatusBaseURL(
            forHost: "mac-alpha.example.ts.net",
            installProfile: .dev
        ))
        #expect(dev.scheme == "http")
        #expect(dev.port == 8101)

        let realDomain = try #require(EndpointPolicy.bootstrapStatusBaseURL(
            forHost: "https://api.example.com",
            installProfile: .dev
        ))
        #expect(realDomain.scheme == "https")
        #expect(realDomain.port == nil)

        let bootstrapEndpoint = try #require(BootstrapStatusEndpoint.baseURL(
            forHost: "mac-alpha.example.ts.net",
            installProfile: .dev
        ))
        #expect(bootstrapEndpoint.scheme == "http")
        #expect(bootstrapEndpoint.port == 8101)

        let tailnetIPv6 = try #require(EndpointPolicy.bootstrapStatusBaseURL(
            forHost: "fd7a:115c:a1e0::10",
            installProfile: .dev
        ))
        #expect(tailnetIPv6.absoluteString == "http://[fd7a:115c:a1e0::10]:8101")

        let bracketedTailnetIPv6 = try #require(EndpointPolicy.bootstrapStatusBaseURL(
            forHost: "http://[fd7a:115c:a1e0::10]:8101/bootstrap/status",
            installProfile: .dev
        ))
        #expect(bracketedTailnetIPv6.absoluteString == "http://[fd7a:115c:a1e0::10]:8101")
    }

    @Test("Household endpoint parsing handles explicit URLs, ports, and IPv6")
    func householdEndpointParsing() throws {
        let explicit = try #require(EndpointPolicy.explicitHouseholdEndpoint(
            fromHost: "https://api.example.com/bootstrap/status",
            defaultPort: 8101
        ))
        #expect(explicit.absoluteString == "https://api.example.com:8101")

        let tailnetWithPort = try #require(EndpointPolicy.householdEndpoint(
            fromHost: "100.64.0.10:9173",
            defaultPort: 8101
        ))
        #expect(tailnetWithPort.absoluteString == "http://100.64.0.10:9173")

        let ipv6 = try #require(EndpointPolicy.householdEndpoint(
            fromHost: "fd7a:115c:a1e0::10",
            defaultPort: 8101
        ))
        #expect(ipv6.absoluteString == "http://[fd7a:115c:a1e0::10]:8101")
    }

    @Test("Selectable household endpoints reject automatic LAN plaintext")
    func selectableHouseholdEndpointPolicy() throws {
        let tailnet = try #require(EndpointPolicy.selectableHouseholdEndpoint(
            fromHost: "100.64.0.10",
            defaultPort: 8101
        ))
        #expect(tailnet.absoluteString == "http://100.64.0.10:8101")

        let loopback = try #require(EndpointPolicy.selectableHouseholdEndpoint(
            fromHost: "localhost",
            defaultPort: 8101
        ))
        #expect(loopback.absoluteString == "http://localhost:8101")

        #expect(EndpointPolicy.selectableHouseholdEndpoint(
            fromHost: "mac-alpha.local",
            defaultPort: 8101
        ) == nil)
        #expect(EndpointPolicy.selectableHouseholdEndpoint(
            fromHost: "192.168.1.10",
            defaultPort: 8101
        ) == nil)

        let explicitTLS = try #require(EndpointPolicy.selectableHouseholdEndpoint(
            URL(string: "https://mac-alpha.local:9443/bootstrap/status")!,
            defaultPort: 8101
        ))
        #expect(explicitTLS.absoluteString == "https://mac-alpha.local:9443")
    }

    @Test("Endpoint policy owns presence and fallback host candidate ordering")
    func connectionCandidateOrdering() {
        let hosts = EndpointPolicy.orderedHosts(
            bareHost: "100.64.0.10",
            localLabels: ["mac-alpha.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: false,
            tailnetActive: true
        )
        #expect(hosts == ["mac-alpha", "100.64.0.10", "mac-alpha.local"])

        let resolved = EndpointPolicy.resolveServerEndpoint(
            bareHost: "mac-alpha.local:57414",
            localLabels: ["mac-alpha-nearby.local"],
            magicDNSLabels: ["mac-alpha"],
            localNetworkActive: true,
            tailnetActive: true,
            presencePort: 57414,
            attachPort: 57415,
            bootstrapPort: 8101
        )
        #expect(resolved.orderedHosts == ["mac-alpha.local", "mac-alpha-nearby.local", "mac-alpha"])
        #expect(resolved.presencePort == 57414)
        #expect(resolved.attachPort == 57415)
        #expect(resolved.bootstrapPort == 8101)
    }

    @Test("Bonjour endpoint policy covers profile ports, host acceptance, and IPv4 rank")
    func bonjourEndpointPolicy() throws {
        let releaseURL = try #require(EndpointPolicy.bonjourEngineEndpointURL(
            host: "mac-alpha.local",
            defaultPort: EndpointPolicy.defaultBootstrapPort(for: .release)
        ))
        #expect(releaseURL.absoluteString == "http://mac-alpha.local:8091")

        let devURL = try #require(EndpointPolicy.bonjourEngineEndpointURL(
            host: "mac-alpha.local",
            defaultPort: EndpointPolicy.defaultBootstrapPort(for: .dev)
        ))
        #expect(devURL.absoluteString == "http://mac-alpha.local:8101")

        #expect(EndpointPolicy.acceptsBonjourEngineHost("mac-alpha.local"))
        #expect(EndpointPolicy.acceptsBonjourEngineHost("mac-alpha"))
        #expect(!EndpointPolicy.acceptsBonjourEngineHost("api.example.com"))

        #expect(EndpointPolicy.bonjourIPv4EndpointRank("100.64.0.10") == 0)
        #expect(EndpointPolicy.bonjourIPv4EndpointRank("10.0.0.10") == 1)
        #expect(EndpointPolicy.bonjourIPv4EndpointRank("203.0.113.10") == 2)
        #expect(EndpointPolicy.bonjourIPv4EndpointRank("127.0.0.1") == nil)
        #expect(EndpointPolicy.bonjourIPv4EndpointRank("169.254.1.2") == nil)
        #expect(HostClassifier.localInterfaceIPv4Rank("100.64.0.10") == 0)
        #expect(HostClassifier.localInterfaceIPv4Rank("192.168.1.10") == 1)
        #expect(HostClassifier.localInterfaceIPv4Rank("203.0.113.10") == 3)
        #expect(HostClassifier.localInterfaceIPv4Rank("169.254.1.2") == nil)
    }

    @Test("Endpoint policy owns host classification in migrated endpoint files")
    func migratedFilesDoNotReintroduceLocalClassifiers() throws {
        let root = try workspaceRoot()
        let migratedFiles = [
            "Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient+Claws.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapStatusEndpoint.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Networking/HouseholdBonjourBrowser.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/TailnetAddressResolver.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerEndpointResolver.swift",
            "TerminalApp/Soyeht/ClawStore/ClawInstallTargetResolver.swift",
            "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            "TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift",
            "TerminalApp/Soyeht/Home/AwaitingNewMacView.swift",
            "TerminalApp/Soyeht/Pairing/MacPresenceClient.swift",
            "TerminalApp/Soyeht/Pairing/PairedMacRegistry.swift",
            "TerminalApp/Soyeht/SSHLoginView.swift",
            "TerminalApp/Soyeht/SoyehtAPIClient.swift",
            "TerminalApp/SoyehtMac/Pairing/PairingPresenceServer.swift",
            "TerminalApp/SoyehtMac/PreferencesDevicesViewController.swift",
            "TerminalApp/SoyehtMac/QRHandoff/LocalTerminalHandoffManager.swift",
            "TerminalApp/SoyehtMac/Welcome/SetupInvitationListener/SetupInvitationListener.swift",
            "TerminalApp/SoyehtMac/Welcome/TheyOSEnvironment.swift",
        ]

        for relativePath in migratedFiles {
            let fileURL = root.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let codeOnly = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            #expect(!codeOnly.contains("hasSuffix(\".ts.net\")"), "\(relativePath) must not classify MagicDNS directly")
            #expect(!codeOnly.contains("100.64.0.0/10"), "\(relativePath) must not own Tailnet range policy")
            #expect(!codeOnly.contains("fd7a:115c:a1e0::/48"), "\(relativePath) must not own Tailnet IPv6 policy")
            #expect(!codeOnly.contains("isPrivate172"), "\(relativePath) must not keep a private LAN helper")
            #expect(!codeOnly.contains("inet_pton"), "\(relativePath) must not parse IP literals directly")
        }
    }

    @Test("Production source slices do not reintroduce endpoint policy logic")
    func productionSourceSlicesDoNotReintroduceEndpointPolicyLogic() throws {
        let root = try workspaceRoot()
        let files = try productionSwiftFiles(root: root)
        let policyFile = "Packages/SoyehtCore/Sources/SoyehtCore/Networking/EndpointPolicy.swift"
        let profileFile = "Packages/SoyehtCore/Sources/SoyehtCore/Install/SoyehtInstallProfile.swift"
        let allowlist: [String: Set<String>] = [
            "hasSuffix(\".ts.net\")": [policyFile],
            "(64...127).contains": [policyFile],
            "fd7a:115c:a1e0": [policyFile],
            "isPrivate172": [policyFile],
            "inet_pton": [policyFile],
            "? \"http\" : \"https\"": [policyFile],
            "? \"ws\" : \"wss\"": [policyFile],
            "components.scheme = components.scheme ==": [policyFile],
            "static let scheme = \"ws\"": [],
            "ws://": [],
            "components.scheme = \"ws\"": [],
            "components.scheme = \"http\"": [policyFile],
            "URLComponents(string: \"http://": [policyFile],
            "return \"ws\"": [policyFile],
            "defaultPort: Int = 8091": [],
            "?? 8091": [],
            "\\(scheme)://": [],
            "bootstrapPort: 8091": [profileFile],
            "bootstrapPort: 8101": [profileFile],
        ]

        for relativePath in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let codeOnly = sourceCodeOnly(source)
            for (pattern, allowedPaths) in allowlist {
                guard codeOnly.contains(pattern),
                      !allowedPaths.contains(relativePath) else {
                    continue
                }
                Issue.record("\(relativePath) must not contain endpoint policy pattern \(pattern)")
            }
        }
    }

    private func workspaceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func productionSwiftFiles(root: URL) throws -> [String] {
        let roots = [
            "Packages/SoyehtCore/Sources",
            "TerminalApp/Soyeht",
            "TerminalApp/SoyehtMac",
        ]
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        var files: [String] = []
        for relativeRoot in roots {
            let url = root.appendingPathComponent(relativeRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let path = fileURL.path
                guard path.hasPrefix(rootPath) else { continue }
                files.append(String(path.dropFirst(rootPath.count)))
            }
        }
        return files.sorted()
    }

    private func sourceCodeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
            .joined(separator: "\n")
    }
}
