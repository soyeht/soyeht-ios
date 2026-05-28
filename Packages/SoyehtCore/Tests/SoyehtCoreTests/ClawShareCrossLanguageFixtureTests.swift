import Foundation
import XCTest

@testable import SoyehtCore

/// Cross-language fixture: the Rust side
/// (`household_rs::claw_share::tests::cross_language_fixture_invite_hex`)
/// pins the same hex literal. A wire-shape change must update both
/// sides in lockstep — otherwise one of these tests fails first.
final class ClawShareCrossLanguageFixtureTests: XCTestCase {
    /// Canonical CBOR (lex-sorted keys, definite-length encoding) of
    /// the unsigned invite body. Derived once from the Rust fixture
    /// (see `Packages/SoyehtCore/Tests/SoyehtCoreTests/
    /// ClawShareCrossLanguageFixtureTests.swift` documentation).
    private static let expectedUnsignedHex =
        "ab617601646b696e6471636c61772d73686172652f696e766974656568685f6964783768685f6a707173797570796f747268676175343579376e6575336c3370346c65723678687537646e32783232337232716636616769727167636c61775f69646f636c61775f666978747572655f763167736c6f745f696450222222222222222222222222222222226a657870697265735f61741a6b49d2006a6f776e65725f705f69647836705f6a707173797570796f747268676175343579376e6575336c3370346c65723678687537646e3278323233723271663661676972716b6f776e65725f705f7075625821020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed6c636c61696d5f72656c617973826d7773733a2f2f72656c61792d616d7773733a2f2f72656c61792d626e7472616e73706f72745f68696e74a2646b696e64686c6f6f706261636b676368616e6e656c6a63682d66697874757265716f776e65725f656e67696e655f6e707562736e7075625f656e67696e655f66697874757265"

    private static let expectedUnsignedClaimHex =
        "a6617601646b696e6470636c61772d73686172652f636c61696d656e6f6e63655820444444444444444444444444444444444444444444444444444444444444444467736c6f745f696450222222222222222222222222222222226974696d657374616d701a6b49d3f47067756573745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"

    private static let expectedUnsignedCredentialHex =
        "aa617601646b696e64781b636c61772d73686172652f67756573742d63726564656e7469616c6568685f6964783768685f6a707173797570796f747268676175343579376e6575336c3370346c65723678687537646e32783232337232716636616769727167636c61775f69646f636c61775f666978747572655f763167736c6f745f69645022222222222222222222222222222222696973737565645f61741a6b49d3f46a657870697265735f61741a6b49fb046a6f776e65725f705f69647836705f6a707173797570796f747268676175343579376e6575336c3370346c65723678687537646e3278323233723271663661676972716b6f776e65725f705f7075625821020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed7067756573745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"

    /// Guest device key, derived once from P-256 secret scalar
    /// = [0x33; 32] — same input the Rust fixture uses.
    private static let guestDevicePubHex =
        "0351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"

    func testUnsignedClaimCBORMatchesRustFixture() throws {
        let slotId = Data(repeating: 0x22, count: 16)
        let guestPub = Data(hexString: Self.guestDevicePubHex)!
        let nonce = Data(repeating: 0x44, count: 32)

        let unsignedCBOR = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "kind": .text(ClawShareClaim.kind),
            "slot_id": .bytes(slotId),
            "guest_device_pub": .bytes(guestPub),
            "nonce": .bytes(nonce),
            "timestamp": .unsigned(1_800_000_500),
        ]))
        XCTAssertEqual(
            unsignedCBOR.hexEncodedString(),
            Self.expectedUnsignedClaimHex,
            "Swift claim CBOR drifted from the Rust fixture"
        )
    }

    func testUnsignedGuestCredentialCBORMatchesRustFixture() throws {
        let ownerPubHex = "020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"
        let ownerPub = Data(hexString: ownerPubHex)!
        let householdId = "hh_jpqsyupyotrhgau45y7neu3l3p4ler6xhu7dn2x223r2qf6agirq"
        let ownerPersonId = "p_jpqsyupyotrhgau45y7neu3l3p4ler6xhu7dn2x223r2qf6agirq"
        let slotId = Data(repeating: 0x22, count: 16)
        let guestPub = Data(hexString: Self.guestDevicePubHex)!

        let unsignedCBOR = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "kind": .text(GuestCredential.kind),
            "hh_id": .text(householdId),
            "owner_p_id": .text(ownerPersonId),
            "owner_p_pub": .bytes(ownerPub),
            "claw_id": .text("claw_fixture_v1"),
            "guest_device_pub": .bytes(guestPub),
            "slot_id": .bytes(slotId),
            "issued_at": .unsigned(1_800_000_500),
            "expires_at": .unsigned(1_800_010_500),
        ]))
        XCTAssertEqual(
            unsignedCBOR.hexEncodedString(),
            Self.expectedUnsignedCredentialHex,
            "Swift guest credential CBOR drifted from the Rust fixture"
        )
    }

    func testUnsignedInviteCBORMatchesRustFixture() throws {
        // Deterministic inputs — identical to the Rust fixture's
        // `cross_language_fixture_invite_hex`. The owner public key
        // bytes come from P-256 secret scalar = [0x11; 32]; we
        // hardcode the derived values because mirroring BLAKE3-base32
        // derivation in this test would duplicate library logic.
        let ownerPubHex = "020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"
        let ownerPub = Data(hexString: ownerPubHex)!
        let householdId = "hh_jpqsyupyotrhgau45y7neu3l3p4ler6xhu7dn2x223r2qf6agirq"
        let ownerPersonId = "p_jpqsyupyotrhgau45y7neu3l3p4ler6xhu7dn2x223r2qf6agirq"
        let slotId = Data(repeating: 0x22, count: 16)

        // Build the same CBOR shape the Rust `ClawShareInviteUnsigned`
        // serializes. Field set + ordering must match exactly; the
        // canonical encoder applies lex sort on map keys, so we list
        // them in their semantic order here for readability.
        let unsignedCBOR = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "kind": .text(ClawShareInvite.kind),
            "hh_id": .text(householdId),
            "owner_p_id": .text(ownerPersonId),
            "owner_p_pub": .bytes(ownerPub),
            "claw_id": .text("claw_fixture_v1"),
            "slot_id": .bytes(slotId),
            "transport_hint": .map([
                "kind": .text("loopback"),
                "channel": .text("ch-fixture"),
            ]),
            "expires_at": .unsigned(1_800_000_000),
            "owner_engine_npub": .text("npub_engine_fixture"),
            "claim_relays": .array([
                .text("wss://relay-a"),
                .text("wss://relay-b"),
            ]),
        ]))
        let hex = unsignedCBOR.hexEncodedString()
        XCTAssertEqual(
            hex,
            Self.expectedUnsignedHex,
            "Swift canonical CBOR drifted from the Rust fixture — wire shape change must update both sides"
        )
    }
}

// MARK: - Hex helpers (test-only)

private extension Data {
    init?(hexString: String) {
        let length = hexString.count
        guard length % 2 == 0 else { return nil }
        var data = Data(capacity: length / 2)
        var index = hexString.startIndex
        for _ in 0..<(length / 2) {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
