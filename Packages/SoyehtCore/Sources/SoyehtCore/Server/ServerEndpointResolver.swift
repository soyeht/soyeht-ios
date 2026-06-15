import Foundation

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

public enum ServerEndpointResolver {
    public static let defaultBootstrapPort = 8091

    /// Builds the ordered connection candidates for a server without doing any
    /// network probing. `bareHost` may include a simple `:port` suffix; labels
    /// such as Bonjour `.local` and MagicDNS names are precomputed by the
    /// caller because their source differs between pairing flows.
    public static func resolve(
        bareHost: String,
        localLabels: [String],
        magicDNSLabels: [String],
        localNetworkActive: Bool,
        tailnetActive: Bool,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        bootstrapPort: Int = defaultBootstrapPort
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
        let host = Self.bareHost(from: bareHost).trimmingCharacters(in: .whitespacesAndNewlines)
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

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        let bareHost = Self.bareHost(from: host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if bareHost.hasSuffix(".local") {
            return true
        }
        guard let octets = ipv4Octets(from: bareHost) else {
            return false
        }
        let b0 = octets[0]
        let b1 = octets[1]
        if b0 == 10 { return true }
        if b0 == 127 { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 169 && b1 == 254 { return true }
        return false
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

    private static func bareHost(from host: String) -> String {
        if let colon = host.lastIndex(of: ":"), !host.contains("::") {
            return String(host[..<colon])
        }
        return host
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
}
