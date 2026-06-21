import Darwin
import Foundation

/// Canonical host classification for Soyeht endpoint and transport decisions.
public enum EndpointHostClass: String, Sendable, Equatable {
    case loopback
    case tailnet
    case lan
    case publicHost = "public"
    case unknown
}

/// Endpoint purpose controls scheme decisions for the same host class.
public enum EndpointPurpose: Sendable, Equatable {
    case adminAPI
    case bootstrapStatus
    case householdAPI
    case householdTerminalWebSocket
    case presence
    case macLocalControlPlane
    case setupInvitation
}

public struct ResolvedServerEndpoint: Sendable, Equatable {
    public let orderedHosts: [String]
    public let presencePort: Int?
    public let attachPort: Int?
    public let bootstrapPort: Int

    public init(
        orderedHosts: [String],
        presencePort: Int?,
        attachPort: Int?,
        bootstrapPort: Int
    ) {
        self.orderedHosts = orderedHosts
        self.presencePort = presencePort
        self.attachPort = attachPort
        self.bootstrapPort = bootstrapPort
    }
}

/// Canonical classifier for host strings that may be bare hosts, URLs,
/// bracketed IPv6 literals, or `host:port` pairs.
public enum HostClassifier {
    public static func classify(_ rawHost: String) -> EndpointHostClass {
        guard let host = normalizedHost(from: rawHost) else { return .unknown }
        let lower = host.lowercased()
        if isLoopbackHost(lower) { return .loopback }
        if isTailnetHost(lower) { return .tailnet }
        if isLANHost(lower) { return .lan }
        return .publicHost
    }

    public static func normalizedHost(from rawHost: String) -> String? {
        parseHostParts(from: rawHost)?.host
    }

    public static func hostParts(from rawHost: String) -> (host: String, port: Int?)? {
        parseHostParts(from: rawHost)
    }

    public static func isTailnetHost(_ rawHost: String) -> Bool {
        guard let host = normalizedHost(from: rawHost)?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        if isTailnetIPv4(host) { return true }
        if isTailnetIPv6(host) { return true }
        return false
    }

    public static func isTailnetIPv4(_ rawHost: String) -> Bool {
        guard let host = normalizedHost(from: rawHost)?.lowercased(),
              let octets = ipv4Octets(from: host) else {
            return false
        }
        return isTailnetIPv4Octets(octets)
    }

    public static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        switch classify(rawHost) {
        case .loopback, .lan:
            return true
        case .tailnet, .publicHost, .unknown:
            return false
        }
    }

    public static func isIPAddressLiteral(_ rawHost: String) -> Bool {
        guard let host = normalizedHost(from: rawHost) else { return false }
        if host.contains(":") { return true }
        return ipv4Octets(from: host) != nil
    }

    /// Ranking used by Bonjour/DNS-SD adapters when multiple A records resolve.
    /// Tailnet is preferred, LAN is usable, public IPv4 is last, and loopback or
    /// link-local addresses are ignored for peer discovery.
    public static func bonjourIPv4EndpointRank(_ rawHost: String) -> Int? {
        guard let host = normalizedHost(from: rawHost),
              let octets = ipv4Octets(from: host) else {
            return nil
        }
        switch octets[0] {
        case 0, 127:
            return nil
        case 100 where isTailnetIPv4Octets(octets):
            return 0
        case 10:
            return 1
        case 172 where (16...31).contains(octets[1]):
            return 1
        case 192 where octets[1] == 168:
            return 1
        case 169 where octets[1] == 254:
            return nil
        default:
            return 2
        }
    }

    public static func localInterfaceIPv4Rank(_ rawHost: String) -> Int? {
        guard let host = normalizedHost(from: rawHost),
              let octets = ipv4Octets(from: host) else {
            return nil
        }
        if octets[0] == 0 || octets[0] == 127 { return nil }
        if isLinkLocalIPv4Octets(octets) { return nil }
        if isTailnetIPv4Octets(octets) { return 0 }
        if isPrivateIPv4Octets(octets) { return 1 }
        return 3
    }

    private static func parseHostParts(from rawHost: String) -> (host: String, port: Int?)? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           !scheme.isEmpty,
           let urlHost = url.host {
            return (
                urlHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                url.port
            )
        }

        var host = trimmed
        var port: Int?
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let suffix = trimmed[trimmed.index(after: end)...]
            if suffix.hasPrefix(":"),
               let parsed = Int(suffix.dropFirst()) {
                port = parsed
            }
        } else if let colon = trimmed.lastIndex(of: ":"),
                  trimmed[..<colon].contains(":") == false,
                  let parsedPort = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = parsedPort
        }

        host = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if let octets = ipv4MappedOctets(from: host) {
            return octets[0] == 127
        }
        return false
    }

    private static func isLANHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        if let octets = ipv4Octets(from: host) ?? ipv4MappedOctets(from: host) {
            return isPrivateIPv4Octets(octets) || isLinkLocalIPv4Octets(octets)
        }
        return isUniqueLocalIPv6(host) || isLinkLocalIPv6(host)
    }

    private static func ipv4Octets(from host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isTailnetIPv6(_ host: String) -> Bool {
        if let octets = ipv4MappedOctets(from: host) {
            return isTailnetIPv4Octets(octets)
        }
        guard let bytes = ipv6Bytes(from: host), bytes.count >= 6 else {
            return false
        }
        return bytes[0] == 0xfd
            && bytes[1] == 0x7a
            && bytes[2] == 0x11
            && bytes[3] == 0x5c
            && bytes[4] == 0xa1
            && bytes[5] == 0xe0
    }

    private static func isUniqueLocalIPv6(_ host: String) -> Bool {
        guard let bytes = ipv6Bytes(from: host), let first = bytes.first else {
            return false
        }
        return (first & 0xfe) == 0xfc
    }

    private static func isLinkLocalIPv6(_ host: String) -> Bool {
        guard let bytes = ipv6Bytes(from: host), bytes.count >= 2 else {
            return false
        }
        return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }

    private static func ipv4MappedOctets(from host: String) -> [UInt8]? {
        guard let bytes = ipv6Bytes(from: host), bytes.count == 16 else {
            return nil
        }
        guard bytes.prefix(10).allSatisfy({ $0 == 0 }),
              bytes[10] == 0xff,
              bytes[11] == 0xff else {
            return nil
        }
        return Array(bytes[12...15])
    }

    private static func isTailnetIPv4Octets(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isPrivateIPv4Octets(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let b0 = octets[0]
        let b1 = octets[1]
        if b0 == 10 { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        return false
    }

    private static func isLinkLocalIPv4Octets(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        return octets[0] == 169 && octets[1] == 254
    }

    private static func ipv6Bytes(from host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}

/// Single source of truth for host classification, profile-aware engine ports,
/// and scheme decisions used by Soyeht endpoint builders.
public enum EndpointPolicy {
    public static func defaultBootstrapPort(
        for profile: SoyehtInstallProfile = .current
    ) -> Int {
        profile.bootstrapPort
    }

    public static func hostClass(for rawHost: String) -> EndpointHostClass {
        HostClassifier.classify(rawHost)
    }

    public static func hostClassName(for rawHost: String) -> String {
        hostClass(for: rawHost).rawValue
    }

    public static func isTailnetHost(_ rawHost: String) -> Bool {
        HostClassifier.isTailnetHost(rawHost)
    }

    public static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        HostClassifier.isLocalNetworkHost(rawHost)
    }

    public static func acceptsMacLocalControlPlaneHost(_ rawHost: String) -> Bool {
        switch hostClass(for: rawHost) {
        case .loopback, .tailnet, .lan:
            return true
        case .publicHost, .unknown:
            return false
        }
    }

    public static func isHouseholdPlaintextAllowedHost(_ rawHost: String) -> Bool {
        switch hostClass(for: rawHost) {
        case .loopback, .tailnet:
            return true
        case .lan, .publicHost, .unknown:
            return false
        }
    }

    public static func adminHTTPScheme(for rawHost: String) -> String {
        isLocalNetworkHost(rawHost) ? "http" : "https"
    }

    public static func adminWebSocketScheme(for rawHost: String) -> String {
        webSocketScheme(for: .adminAPI, host: rawHost) ?? "wss"
    }

    public static func householdHTTPScheme(inputScheme: String, host: String) -> String? {
        switch inputScheme.lowercased() {
        case "http", "ws":
            return isHouseholdPlaintextAllowedHost(host) ? "http" : "https"
        case "https", "wss":
            return "https"
        default:
            return nil
        }
    }

    public static func householdWebSocketScheme(inputScheme: String, host: String) -> String? {
        webSocketScheme(
            for: .householdTerminalWebSocket,
            host: host,
            inputScheme: inputScheme
        )
    }

    /// WebSocket transport scheme authority for endpoint families that open a
    /// WS connection. The Mac-local control plane is intentionally fixed to
    /// plain WS: those listeners are paired-Mac local handoff/presence/attach
    /// sockets, not remote household/admin API transports.
    public static func webSocketScheme(
        for purpose: EndpointPurpose,
        host rawHost: String,
        inputScheme: String? = nil
    ) -> String? {
        switch purpose {
        case .adminAPI:
            return isLocalNetworkHost(rawHost) ? "ws" : "wss"
        case .householdAPI, .householdTerminalWebSocket:
            switch (inputScheme ?? "http").lowercased() {
            case "http", "ws":
                return isHouseholdPlaintextAllowedHost(rawHost) ? "ws" : "wss"
            case "https", "wss":
                return "wss"
            default:
                return nil
            }
        case .presence, .macLocalControlPlane:
            return "ws"
        case .bootstrapStatus, .setupInvitation:
            return nil
        }
    }

    public static func macLocalControlPlaneWebSocketScheme() -> String {
        webSocketScheme(for: .macLocalControlPlane, host: "localhost") ?? "ws"
    }

    public static func adminHTTPURL(
        host rawHost: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard let host = urlAuthorityHostParts(from: rawHost)?.host else { return nil }
        return endpointURL(
            scheme: adminHTTPScheme(for: host),
            host: rawHost,
            path: path,
            queryItems: queryItems
        )
    }

    public static func adminWebSocketURL(
        host rawHost: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard let host = urlAuthorityHostParts(from: rawHost)?.host else { return nil }
        return endpointURL(
            scheme: adminWebSocketScheme(for: host),
            host: rawHost,
            path: path,
            queryItems: queryItems
        )
    }

    public static func macLocalControlPlaneWebSocketURL(
        host rawHost: String,
        port: Int,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        macLocalControlPlaneURL(
            scheme: macLocalControlPlaneWebSocketScheme(),
            host: rawHost,
            port: port,
            path: path,
            queryItems: queryItems
        )
    }

    public static func macLocalControlPlaneHTTPURL(
        host rawHost: String,
        port: Int,
        path: String = "",
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        macLocalControlPlaneURL(
            scheme: "http",
            host: rawHost,
            port: port,
            path: path,
            queryItems: queryItems
        )
    }

    public static func setupInvitationHTTPURL(
        host rawHost: String,
        port: Int,
        path: String = "",
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        endpointURL(
            scheme: "http",
            host: rawHost,
            path: path,
            queryItems: queryItems,
            explicitPort: port
        )
    }

    /// Builds an intentionally-plain local HTTP endpoint from a bare authority
    /// (`host` or `host:port`). This is the shared path for QR/local-anchor
    /// protocols whose trust comes from a pairing secret or cert proof, not TLS.
    public static func localPlainHTTPURL(
        authority rawAuthority: String,
        path: String = "",
        defaultPort: Int? = nil
    ) -> URL? {
        guard let parts = strictAuthorityHostParts(from: rawAuthority) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = urlComponentsHost(parts.host)
        components.port = parts.port ?? defaultPort
        if !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        return components.url
    }

    public static func macLocalPresenceWebSocketURL(
        host rawHost: String,
        presencePort: Int,
        macID: UUID
    ) -> URL? {
        macLocalControlPlaneWebSocketURL(
            host: rawHost,
            port: presencePort,
            path: PresencePath.presence,
            queryItems: [
                URLQueryItem(name: PresenceQueryKey.macID, value: macID.uuidString),
            ]
        )
    }

    public static func macLocalPaneAttachWebSocketURL(
        host rawHost: String,
        attachPort: Int,
        paneID: String,
        nonce: String
    ) -> URL? {
        macLocalControlPlaneWebSocketURL(
            host: rawHost,
            port: attachPort,
            path: PresencePath.paneAttach(paneID: paneID),
            queryItems: [
                URLQueryItem(name: PresenceQueryKey.nonce, value: nonce),
            ]
        )
    }

    public static func bootstrapStatusBaseURL(
        forHost rawHost: String,
        installProfile: SoyehtInstallProfile = .current
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var scheme: String?
        var authority = urlAuthorityHostParts(from: trimmed)

        if let url = URL(string: trimmed),
           let parsedScheme = url.scheme?.lowercased(),
           parsedScheme == "http" || parsedScheme == "https",
           let parsedHost = url.host {
            scheme = parsedScheme
            authority = (host: parsedHost, port: url.port)
        }

        guard let (host, explicitPort) = authority else { return nil }
        guard !host.isEmpty else { return nil }

        let enginePort = defaultBootstrapPort(for: installProfile)
        if scheme == "https", !isTailnetHost(host), explicitPort != enginePort {
            var components = URLComponents()
            components.scheme = "https"
            components.host = urlComponentsHost(host)
            components.port = explicitPort
            return components.url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = urlComponentsHost(host)
        components.port = explicitPort ?? enginePort
        return components.url
    }

    public static func normalizedHouseholdEndpoint(
        _ endpoint: URL,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        if components?.scheme == nil {
            components?.scheme = "http"
        }
        if components?.port == nil {
            components?.port = defaultPort
        }
        return components?.url ?? endpoint
    }

    public static func isSelectableHouseholdEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host,
              let scheme = endpoint.scheme?.lowercased() else {
            return false
        }
        switch scheme {
        case "http", "ws":
            return isHouseholdPlaintextAllowedHost(host)
        case "https", "wss":
            return true
        default:
            return false
        }
    }

    public static func selectableHouseholdEndpoint(
        _ endpoint: URL,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        let normalized = normalizedHouseholdEndpoint(endpoint, defaultPort: defaultPort)
        return isSelectableHouseholdEndpoint(normalized) ? normalized : nil
    }

    public static func explicitHouseholdEndpoint(
        fromHost rawHost: String,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            return normalizedHouseholdEndpoint(url, defaultPort: defaultPort)
        }
        return nil
    }

    public static func householdHostParts(fromHost rawHost: String) -> (host: String, port: Int?)? {
        HostClassifier.hostParts(from: rawHost)
    }

    public static func householdEndpoint(
        fromHost rawHost: String,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        guard let parts = householdHostParts(fromHost: rawHost) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = urlComponentsHost(parts.host)
        components.port = parts.port ?? defaultPort
        return components.url
    }

    public static func selectableHouseholdEndpoint(
        fromHost rawHost: String,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        guard let endpoint = householdEndpoint(fromHost: rawHost, defaultPort: defaultPort) else {
            return nil
        }
        return isSelectableHouseholdEndpoint(endpoint) ? endpoint : nil
    }

    public static func firstSelectableHouseholdEndpoint(
        fromHosts rawHosts: [String],
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        for rawHost in rawHosts {
            if let endpoint = selectableHouseholdEndpoint(
                fromHost: rawHost,
                defaultPort: defaultPort
            ) {
                return endpoint
            }
        }
        return nil
    }

    public static func resolveServerEndpoint(
        bareHost: String,
        localLabels: [String],
        magicDNSLabels: [String],
        localNetworkActive: Bool,
        tailnetActive: Bool,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        bootstrapPort: Int = defaultBootstrapPort()
    ) -> ResolvedServerEndpoint {
        ResolvedServerEndpoint(
            orderedHosts: orderedHosts(
                bareHost: bareHost,
                localLabels: localLabels,
                magicDNSLabels: magicDNSLabels,
                localNetworkActive: localNetworkActive,
                tailnetActive: tailnetActive
            ),
            presencePort: presencePort,
            attachPort: attachPort,
            bootstrapPort: bootstrapPort
        )
    }

    public static func orderedHosts(
        bareHost: String,
        localLabels: [String],
        magicDNSLabels: [String],
        localNetworkActive: Bool,
        tailnetActive: Bool
    ) -> [String] {
        let host = normalizedHost(from: bareHost) ?? bareHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if localNetworkActive {
            if isLocalNetworkHost(host) {
                candidates.append(host)
                candidates.append(contentsOf: localLabels)
            } else {
                candidates.append(contentsOf: localLabels)
                candidates.append(host)
            }
            candidates.append(contentsOf: magicDNSLabels)
        } else if tailnetActive {
            candidates.append(contentsOf: magicDNSLabels)
            candidates.append(host)
            candidates.append(contentsOf: localLabels)
        } else {
            candidates.append(host)
            candidates.append(contentsOf: localLabels)
            candidates.append(contentsOf: magicDNSLabels)
        }

        return uniqueHosts(candidates)
    }

    /// Normalizes caller-supplied network labels while preserving caller-defined
    /// source priority. User-facing aliases should stay out of this list unless
    /// the caller knows they also represent resolvable DNS labels.
    public static func hostLabelCandidates(from rawCandidates: [String]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for raw in rawCandidates {
            guard let label = normalizedHostLabel(from: raw),
                  seen.insert(label).inserted else { continue }
            labels.append(label)
        }
        return labels
    }

    public static func normalizedHostLabel(from raw: String) -> String? {
        let host = (normalizedHost(from: raw) ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !HostClassifier.isIPAddressLiteral(host) else { return nil }

        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        let normalized = firstLabel.lowercased().filter { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-")
        }
        return normalized.isEmpty ? nil : normalized
    }

    public static func isIPAddressLiteral(_ rawHost: String) -> Bool {
        HostClassifier.isIPAddressLiteral(rawHost)
    }

    public static func bonjourEngineEndpointURL(
        host: String,
        scheme: String? = nil,
        port: Int? = nil,
        defaultPort: Int = defaultBootstrapPort()
    ) -> URL? {
        let resolvedScheme = (scheme?.isEmpty == false) ? scheme : "http"
        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = urlComponentsHost(host)
        components.port = port ?? defaultPort
        return components.url
    }

    public static func acceptsBonjourEngineHost(_ rawHost: String) -> Bool {
        guard let normalized = normalizedHost(from: rawHost) else { return false }
        if HostClassifier.bonjourIPv4EndpointRank(normalized) != nil { return true }
        let withoutTrailingDot = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        return withoutTrailingDot.hasSuffix(".local") || !withoutTrailingDot.contains(".")
    }

    public static func bonjourIPv4EndpointRank(_ rawHost: String) -> Int? {
        HostClassifier.bonjourIPv4EndpointRank(rawHost)
    }

    public static func normalizedHost(from rawHost: String) -> String? {
        HostClassifier.normalizedHost(from: rawHost)
    }

    private static func macLocalControlPlaneURL(
        scheme: String,
        host rawHost: String,
        port: Int,
        path: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        guard let host = urlAuthorityHostParts(from: rawHost)?.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = urlComponentsHost(host)
        components.port = port
        if !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    private static func endpointURL(
        scheme: String,
        host rawHost: String,
        path: String,
        queryItems: [URLQueryItem],
        explicitPort: Int? = nil
    ) -> URL? {
        guard let parts = urlAuthorityHostParts(from: rawHost) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = urlComponentsHost(parts.host)
        components.port = explicitPort ?? parts.port
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        // Route registries may already percent-encode dynamic segments. Preserve
        // that contract here instead of double-encoding `%` into `%25`.
        components.percentEncodedPath = normalizedPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    private static func urlComponentsHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private static func urlAuthorityHostParts(from rawHost: String) -> (host: String, port: Int?)? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           !scheme.isEmpty,
           let host = url.host {
            return (host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), url.port)
        }

        var host = trimmed
        var port: Int?
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let suffix = trimmed[trimmed.index(after: end)...]
            if suffix.hasPrefix(":"),
               let parsed = Int(suffix.dropFirst()) {
                port = parsed
            }
        } else if let colon = trimmed.lastIndex(of: ":"),
                  trimmed[..<colon].contains(":") == false,
                  let parsedPort = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = parsedPort
        }

        host = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    private static func strictAuthorityHostParts(from rawAuthority: String) -> (host: String, port: Int?)? {
        let trimmed = rawAuthority.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: "http://\(trimmed)") else { return nil }
        guard let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard isValidStrictAuthorityHost(normalized) else { return nil }
        return (normalized, components.port)
    }

    private static func isValidStrictAuthorityHost(_ host: String) -> Bool {
        if host.contains(":") {
            return host.unicodeScalars.allSatisfy { scalar in
                ("0"..."9").contains(scalar)
                    || ("a"..."f").contains(scalar)
                    || ("A"..."F").contains(scalar)
                    || scalar == ":"
                    || scalar == "."
            }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) < 256
        }
        if isIPv4 { return true }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return true
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { continue }
            let key = host.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(host)
        }
        return ordered
    }
}
