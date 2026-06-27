import Foundation
import SoyehtCore

#if canImport(AuthenticationServices)
/// Builds an `OwnerPasskeyEnrollmentViewModel` for the just-paired owner from an
/// identity snapshot: loads the Secure Enclave owner key, wires the enrollment
/// orchestrator (engine endpoint + owner PoP) and the registration-status client,
/// and anchors the platform ceremony to the provided window.
///
/// Returns `nil` if the owner key cannot be loaded — the screen then degrades to a
/// "set up later" path so passkey enrollment never blocks onboarding.
enum OwnerPasskeyEnrollmentComposer {
    @MainActor
    static func makeViewModel(
        snapshot: SoyehtIdentitySnapshot,
        anchorProvider: PasskeyPresentationAnchorProviding
    ) -> OwnerPasskeyEnrollmentViewModel? {
        let raw = snapshot.underlying
        let keyProvider = SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
        guard let ownerIdentity = try? keyProvider.loadOwnerIdentity(
            keyReference: raw.signingKeyReference,
            publicKey: raw.signingPublicKey,
            personId: raw.ownerPersonId
        ) else {
            return nil
        }

        let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity)
        let enrollmentClient = OwnerPasskeyEnrollmentClient(baseURL: snapshot.endpoint, popSigner: popSigner)
        let statusClient = OwnerPasskeyRegistrationStatusClient(baseURL: snapshot.endpoint, popSigner: popSigner)
        let passkeyProvider = PasskeyProvider(anchorProvider: anchorProvider)
        let orchestrator = OwnerPasskeyEnrollmentOrchestrator(client: enrollmentClient, provider: passkeyProvider)
        return OwnerPasskeyEnrollmentViewModel(orchestrator: orchestrator, statusClient: statusClient)
    }
}
#endif
