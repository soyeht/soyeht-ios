import Foundation

/// An existing household is an enrollment offer, never a successful bootstrap
/// claim. Both paths use the engine's current authority and listener snapshot.
public enum SetupInvitationCeremony {
    public static func operation(for house: SetupInvitationExistingHouse) throws -> PairingOperation {
        guard let url = URL(string: house.pairDeviceURI) else { throw PairingAddressError.invalidEndpoint }
        if (try? HouseholdDevicePairingLink(url: url)) != nil { return .addDevice }
        _ = try PairDeviceQR(url: url)
        return .firstOwner
    }

    public static func requireMatchingHouse(_ house: SetupInvitationExistingHouse,
                                           authority: PairingAuthority) throws {
        guard let url = URL(string: house.pairDeviceURI) else { throw PairingAddressError.invalidEndpoint }
        let householdID: String
        if let link = try? HouseholdDevicePairingLink(url: url) {
            householdID = link.householdId
            guard authority.ownerPersonID != nil else { throw PairingAddressError.operationUnavailable }
        } else {
            householdID = try PairDeviceQR(url: url).householdId
            guard authority.ownerPersonID == nil else { throw PairingAddressError.operationUnavailable }
        }
        guard householdID == authority.householdID else { throw PairingAddressError.staleDecision }
    }
}

extension SetupInvitationDirectClaim {
    /// The callback envelope provides candidates, not a second address policy.
    /// New automatic ceremonies require the versioned snapshot and profile.
    public func chooseAddress(phone: PhoneNetworkEvidence = .current(),
                              freshOperation: PairingOperation = .initialize,
                              expectedInstallation: PairingInstallIdentity = .current) throws -> PairingAddressDecision {
        guard let installation else { throw PairingAddressError.profileMissing }
        try installation.requireMatch(expectedInstallation)
        guard let addressOffer else { throw PairingAddressError.noAvailableEndpoint }
        let operation: PairingOperation
        switch event {
        case .bootstrapClaimAccepted:
            guard existingHouse == nil,
                  freshOperation == .initialize || freshOperation == .acceptHousehold else {
                throw PairingAddressError.operationUnavailable
            }
            operation = freshOperation
        case .existingHouseOffered:
            guard let existingHouse else { throw PairingAddressError.operationUnavailable }
            operation = try SetupInvitationCeremony.operation(for: existingHouse)
        case nil: throw PairingAddressError.unsupportedVersion
        }
        return try PairingAddressPolicy.choose(offer: addressOffer, expectedInstallation: expectedInstallation,
                                               phone: phone, operation: operation)
    }
}
