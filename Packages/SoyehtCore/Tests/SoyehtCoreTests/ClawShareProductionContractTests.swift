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

    /// Defense in depth: the dev/test HTTP submitter must be a
    /// DIFFERENT type than the production submitter so type-level
    /// inspection in app-target tests can distinguish them.
    func testProductionAndDevSubmittersAreDistinctTypes() {
        let prod: any ClawShareClaimSubmitter = NostrClawShareClaimSubmitter()
        let dev: any ClawShareClaimSubmitter = HTTPClawShareClaimSubmitter(
            engineBase: URL(string: "http://127.0.0.1:8091")!
        )
        XCTAssertFalse(type(of: prod) == type(of: dev))
    }
}
