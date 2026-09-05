import Foundation
import SoyehtCore

/// Mac presentation uses the same policy as the phone with unknown phone
/// capability. The full offer must accompany the selected display address.
/// Listener facts come from the engine, not this process's interfaces.
enum MacEngineAdvertisedURL {
    static func resolve(offer: PairingAddressOffer, operation: PairingOperation,
                        installation: PairingInstallIdentity = .current) throws -> URL {
        try PairingAddressPolicy.choose(offer: offer, expectedInstallation: installation,
                                       phone: PhoneNetworkEvidence(hasTailnetAddress: nil),
                                       operation: operation).url
    }

    static func current(localEngineBaseURL: URL, operation: PairingOperation = .addDevice) async throws -> URL {
        let snapshot = try await BootstrapPairingAddressesClient(baseURL: localEngineBaseURL).fetch()
        return try resolve(offer: snapshot.offer, operation: operation)
    }
}
