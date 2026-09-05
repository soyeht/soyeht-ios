import Foundation

/// Which of the Mac's addresses the phone should dial, given what the claim
/// offered and what this phone can actually reach.
///
/// WHY THIS EXISTS. The Mac advertises ONE address and picks it by what the
/// MAC has: `MacEngineAdvertisedURL` returns the tailnet address whenever this
/// Mac has one, and a LAN address only as a fallback. That rule is right for
/// the phone it was written for — handing out a LAN address to a phone that
/// could have used the tailnet is how someone becomes unreachable the moment
/// they leave the house, silently, because it works at home.
///
/// It is wrong for the phone that has no Tailscale at all. MEASURED on the
/// owner's Mac 2026-09-04: the Mac holds a 100.64/10 address, so every claim
/// it sends says "dial me on the tailnet" — over a Wi-Fi socket, to a phone
/// that may have no route to 100.64/10 at all. The Add iPhone sheet now asks the engine to bind
/// the LAN (`POST /bootstrap/local-network-visibility/open`), and the phone
/// still has nowhere to go, because nothing ever told it the LAN address.
///
/// So the claim carries both and the PHONE chooses, which is the only side
/// that knows what it can reach:
///
///   - the advertised address is not a tailnet address → nothing to fix.
///   - this phone has a tailnet address of its own → take the tailnet one. It
///     is the address that keeps working away from home, and the phone stores
///     it for the life of the pairing.
///   - otherwise, and only if the claim carried a local-network address →
///     take that. Pairing over the Wi-Fi in the room beats not pairing.
public enum ClaimEngineAddressChoice {

    public enum Reason: String, Equatable, Sendable {
        /// The advertised address is dialable from anywhere this phone is.
        case advertised
        /// The phone is on the tailnet, so the durable address wins.
        case tailnetOnBothEnds
        /// No tailnet on this phone: the Wi-Fi address is the one that works.
        case localNetworkFallback
        /// A tailnet address this phone cannot reach, and the claim offered
        /// nothing else. The caller will fail — with a reason worth logging.
        case noReachableAddress
    }

    public struct Choice: Equatable, Sendable {
        public let url: URL
        public let reason: Reason

        public init(url: URL, reason: Reason) {
            self.url = url
            self.reason = reason
        }
    }

    /// - Parameters:
    ///   - advertised: `mac_engine_url` — what the Mac put in the claim.
    ///   - localNetwork: `mac_engine_lan_url` — this Mac's LAN address, absent
    ///     on a Mac with no LAN address and on any Mac built before this.
    ///   - phoneHasTailnetAddress: `TailnetAddressResolver.currentTailnetIPv4()
    ///     != nil` on the phone, taken rather than read so the rule is testable.
    public static func choose(
        advertised: URL,
        localNetwork: URL?,
        phoneHasTailnetAddress: Bool
    ) -> Choice {
        guard let host = advertised.host, HostClassifier.isTailnetIPv4(host) else {
            return Choice(url: advertised, reason: .advertised)
        }
        if phoneHasTailnetAddress {
            return Choice(url: advertised, reason: .tailnetOnBothEnds)
        }
        if let localNetwork,
           let lanHost = localNetwork.host,
           HostClassifier.bonjourIPv4EndpointRank(lanHost) != nil,
           !HostClassifier.isTailnetIPv4(lanHost) {
            return Choice(url: localNetwork, reason: .localNetworkFallback)
        }
        return Choice(url: advertised, reason: .noReachableAddress)
    }
}
