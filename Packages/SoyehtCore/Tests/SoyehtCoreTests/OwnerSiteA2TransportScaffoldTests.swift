import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Frozen corpus and no-effect guardrail for the A2-R1 transport work.
@Suite struct OwnerSiteA2TransportScaffoldTests {
    private static let frozenCorpusSHA256 =
        "dde67030a035928d0a859a19fc7dcf14ea8e8fa54643e9f66302652740548330"

    private enum FixtureError: Error {
        case missing
    }

    @Test func frozenCorpusRawBytesRemainPinned() throws {
        let bytes = try fixtureBytes()
        let digest = Data(SHA256.hash(data: bytes)).hexString

        #expect(digest == Self.frozenCorpusSHA256)
        #expect(digest == OwnerSiteA2TransportProfile.frozenCorpusSHA256)
    }

    @Test func scaffoldPinsOnlyTheFixedProfileVocabulary() {
        #expect(OwnerSiteA2TransportProfile.domain == "soyeht/owner-site/a2/v1")
        #expect(OwnerSiteA2TransportProfile.version == 1)
        #expect(OwnerSiteA2TransportProfile.recordVersion == "a2-record-v1")
        #expect(OwnerSiteA2TransportProfile.protocolName == "Noise_XXa2v1_25519_ChaChaPoly_SHA256")
        #expect(OwnerSiteA2TransportProfile.maximumCiphertextBytes == 16_384)
        #expect(OwnerSiteA2TransportProfile.maximumPlaintextBytes == 16_368)
        #expect(OwnerSiteA2TransportProfile.maximumEnvelopeBytes == 16_389)
        #expect(OwnerSiteA2RecordDirection.deviceToEngine.rawValue == 0)
        #expect(OwnerSiteA2RecordDirection.engineToDevice.rawValue == 1)
        #expect(OwnerSiteA2RecordKind.serverFinished.rawValue == 1)
        #expect(OwnerSiteA2RecordKind.clientFinishedAck.rawValue == 2)
        #expect(OwnerSiteA2RecordKind.sitePayload.rawValue == 3)
        #expect(OwnerSiteA2RecordKind.close.rawValue == 4)
    }

    @Test func corpusRemainsSyntheticAndPreEffect() throws {
        let root = try JSONSerialization.jsonObject(with: fixtureBytes()) as? [String: Any]
        #expect(root?["contract"] as? String == "soyeht-owner-site-a2-r1-semantic-corpus")
        #expect(root?["scope"] as? String == "synthetic-test-only-cross-language-witness")
        #expect(root?["authority_status"] as? String == "synthetic-test-only-non-authoritative")
        #expect(root?["version"] as? Int == 1)

        let cases = root?["semantic_cases"] as? [[String: Any]]
        let effects = cases?.first?["pre_c3_expected_effects"] as? [String: Bool]
        for key in ["dial", "mint", "proxy", "site_bytes", "verified_mesh_peer"] {
            #expect(effects?[key] == false, "\(key) must remain pre-effect false")
        }
    }

    @Test func localRecordStateHasNoRealEffectSurface() throws {
        let householdSources = try a2HouseholdSources()
        let source = householdSources.joined(separator: "\n")

        for forbiddenSurface in [
            "URLSession",
            "URLRequest",
            "URLSessionWebSocketTask",
            "NWConnection",
            "NetworkExtension",
            "packetFlow",
            "VerifiedMeshPeer",
            "DialPermit",
            "SoyehtAPIClient",
            "MachineReachability",
            "ServerRegistry",
            "UserDefaults",
            "SecItem",
            "FileManager",
        ] {
            #expect(
                !source.contains(forbiddenSurface),
                "local record state must not introduce \(forbiddenSurface)"
            )
        }

        #expect(!source.contains("func exporter"))
        #expect(!source.localizedCaseInsensitiveContains("rekey"))
        #expect(!source.contains("setReceivingNonce"))
        #expect(!source.contains("StatelessTransportState"))
        #expect(!source.contains("public struct OwnerSiteA2ValidatedPreFinished"))
        #expect(!source.contains("public actor OwnerSiteA2DeviceFinishedTransport"))
        #expect(source.contains("deviceToEngine = nil"))
        #expect(source.contains("engineToDevice = nil"))
        #expect(source.contains("close()"))
    }

    private func a2HouseholdSources() throws -> [String] {
        let householdDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/SoyehtCore/Household")
            .standardizedFileURL
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: householdDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { url in
            url.pathExtension == "swift" && url.lastPathComponent.hasPrefix("OwnerSiteA2")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(
            sourceURLs.map(\.lastPathComponent) == [
                "OwnerSiteA2DeviceFinishedTransport.swift",
                "OwnerSiteA2Transport.swift",
            ],
            "every OwnerSiteA2 source must be included in this no-effect source slice"
        )
        return try sourceURLs.map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private func fixtureBytes() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "owner_site_a2_r1_semantic_corpus_v1",
            withExtension: "json",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        ) else {
            throw FixtureError.missing
        }
        return try Data(contentsOf: url)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
