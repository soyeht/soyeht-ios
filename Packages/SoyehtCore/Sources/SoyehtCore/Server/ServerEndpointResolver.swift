import Foundation

public enum ServerEndpointResolver {
    public static var defaultBootstrapPort: Int {
        EndpointPolicy.defaultBootstrapPort()
    }

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
        EndpointPolicy.resolveServerEndpoint(
            bareHost: bareHost,
            localLabels: localLabels,
            magicDNSLabels: magicDNSLabels,
            localNetworkActive: localNetworkActive,
            tailnetActive: tailnetActive,
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
        EndpointPolicy.orderedHosts(
            bareHost: bareHost,
            localLabels: localLabels,
            magicDNSLabels: magicDNSLabels,
            localNetworkActive: localNetworkActive,
            tailnetActive: tailnetActive
        )
    }

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        EndpointPolicy.isLocalNetworkHost(host)
    }

    /// Normalizes caller-supplied network labels while preserving caller-defined
    /// source priority. User-facing aliases should stay out of this list unless
    /// the caller knows they also represent resolvable DNS labels.
    public static func hostLabelCandidates(from rawCandidates: [String]) -> [String] {
        EndpointPolicy.hostLabelCandidates(from: rawCandidates)
    }

    public static func normalizedHostLabel(from raw: String) -> String? {
        EndpointPolicy.normalizedHostLabel(from: raw)
    }

    public static func isIPAddressLiteral(_ host: String) -> Bool {
        EndpointPolicy.isIPAddressLiteral(host)
    }
}
