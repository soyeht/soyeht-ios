import Foundation
import XCTest

@testable import SoyehtCore

/// Contract tests for the production claw-share wiring.
///
/// These do not depend on the app target — they assert at the
/// `SoyehtCore` boundary that:
///
/// 1. The Secure Enclave identity factory uses the canonical
///    device-identity tag (so two shares from the same device end up
///    with the same projected `foreign_contact` on the engine).
/// 2. The honest-stub claim submitter (`iOSRelayUnavailableClaimSubmitter`)
///    always fails with `.iosClaimRelayNotYetWired` — this is what
///    `ClawShareInviteCenter` uses in production, gating the flow on
///    the absence of a vetted Swift Nostr relay path.
final class ClawShareProductionContractTests: XCTestCase {
    func testDeviceIdentityFactoryUsesPersistentTag() {
        // The tag itself is the contract surface — if it ever changes,
        // existing shares' persistent SE keys are stranded under the
        // old tag and the next share will look like a new device.
        XCTAssertEqual(
            SecureEnclaveClawShareGuestIdentityProvider.deviceIdentityTag,
            "com.soyeht.claw-share.device-identity.v1"
        )
        // The factory MUST return a provider configured with this tag.
        let provider = SecureEnclaveClawShareGuestIdentityProvider.deviceIdentity()
        let mirror = Mirror(reflecting: provider)
        let stored = mirror.children.first { $0.label == "persistentTag" }?.value as? String
        XCTAssertEqual(stored, "com.soyeht.claw-share.device-identity.v1")
    }

    func testIosRelayUnavailableSubmitterFailsExplicitly() async {
        let submitter = iOSRelayUnavailableClaimSubmitter()
        let invite = ClawShareInvite(
            householdId: "hh_fixture",
            ownerPersonId: "p_fixture",
            ownerPublicKey: Data(repeating: 0x02, count: 33),
            clawId: "claw_test",
            slotId: Data(repeating: 0xAB, count: 16),
            transportHint: .loopback(channel: "ch-test"),
            expiresAt: 1_900_000_000,
            ownerEngineNpub: "npub_engine_fixture",
            claimRelays: ["wss://relay-a"],
            ownerSignature: Data(repeating: 0xEE, count: 64)
        )
        do {
            _ = try await submitter.submit(
                invite: invite,
                identityProvider: EphemeralClawShareGuestIdentityProvider()
            )
            XCTFail("production submitter must NEVER complete a claim")
        } catch let error as ClawShareError {
            XCTAssertEqual(
                error,
                .iosClaimRelayNotYetWired,
                "production submitter must surface the honest gate"
            )
        } catch {
            XCTFail("expected typed ClawShareError, got \(error)")
        }
    }

    /// Defense in depth: the dev/test HTTP submitter must be a
    /// DIFFERENT type than the production submitter so type-level
    /// inspection in app-target tests can distinguish them.
    func testProductionAndDevSubmittersAreDistinctTypes() {
        let prod: any ClawShareClaimSubmitter = iOSRelayUnavailableClaimSubmitter()
        let dev: any ClawShareClaimSubmitter = HTTPClawShareClaimSubmitter(
            engineBase: URL(string: "http://127.0.0.1:8091")!
        )
        XCTAssertFalse(type(of: prod) == type(of: dev))
    }
}
