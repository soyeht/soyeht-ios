import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerWebauthnLocalAttestationFixtureTests {
    @Test func fixtureEncodesHarnessSchemaFromPlatformAttestation() throws {
        let clientData = Data(#"{"type":"webauthn.create","challenge":"abc","origin":"https://household.example"}"#.utf8)
        let attestation = OwnerPasskeyAttestation(
            credentialID: Data([0x01, 0x02, 0x03]),
            attestationObject: Data([0xa3, 0x01, 0x02]),
            clientDataJSON: clientData
        )

        let fixture = try OwnerWebauthnLocalAppleAttestationFixture(
            rpID: "household.example",
            attestation: attestation
        )
        let encoded = try JSONEncoder().encode(fixture)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let credential = try #require(object["credential"] as? [String: Any])
        let response = try #require(credential["response"] as? [String: Any])

        #expect(object["rp_id"] as? String == "household.example")
        #expect(object["origin"] as? String == "https://household.example")
        #expect(credential["id"] as? String == "AQID")
        #expect(credential["rawId"] as? String == "AQID")
        #expect(credential["type"] as? String == "public-key")
        #expect(response["attestationObject"] as? String == "owEC")
        #expect(response["clientDataJSON"] as? String == PairingCrypto.base64URLEncode(clientData))
        #expect(credential["extensions"] == nil)
        #expect(response["transports"] == nil)
    }

    @Test func writeCreatesExplicitLocalFixturePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-local-attestation-fixture-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = root.appendingPathComponent("fixture.json", isDirectory: false)
        let fixture = OwnerWebauthnLocalAppleAttestationFixture(
            rpID: "household.example",
            origin: "https://household.example",
            credential: .init(
                id: "AQ",
                rawID: "AQ",
                response: .init(attestationObject: "Ag", clientDataJSON: "Aw")
            )
        )

        try fixture.write(to: fixtureURL)

        #expect(FileManager.default.fileExists(atPath: fixtureURL.path))
        let data = try Data(contentsOf: fixtureURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rp_id"] as? String == "household.example")
    }

    @Test func fixtureRequiresClientDataOrigin() {
        let attestation = OwnerPasskeyAttestation(
            credentialID: Data([0x01]),
            attestationObject: Data([0x02]),
            clientDataJSON: Data(#"{"type":"webauthn.create"}"#.utf8)
        )

        #expect(throws: OwnerWebauthnLocalAttestationFixtureError.missingClientDataOrigin) {
            _ = try OwnerWebauthnLocalAppleAttestationFixture(
                rpID: "household.example",
                attestation: attestation
            )
        }
    }
}
