import Foundation

/// Compatibility adapter for the two-address claim. Ranking belongs to
/// PairingAddressPolicy, including the services that persist the endpoint.
public enum ClaimEngineAddressChoice {
    public typealias Choice = PairingAddressDecision

    public static func choose(
        advertised: URL,
        localNetwork: URL?,
        phoneHasTailnetAddress: Bool,
        installation: PairingInstallIdentity = .current,
        operation: PairingOperation = .firstOwner
    ) throws -> Choice {
        var endpoints = [advertised]
        if let localNetwork, PairingAddressPolicy.transport(of: localNetwork) == .localNetwork {
            endpoints.append(localNetwork)
        }
        return try PairingAddressPolicy.choose(
            offer: PairingAddressPolicy.legacyOffer(endpoints: endpoints, installation: installation),
            expectedInstallation: installation,
            phone: PhoneNetworkEvidence(hasTailnetAddress: phoneHasTailnetAddress),
            operation: operation
        )
    }
}
