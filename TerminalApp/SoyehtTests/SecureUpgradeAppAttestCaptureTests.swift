import CryptoKit
import Foundation
import SoyehtCore
import XCTest

#if os(iOS)
import DeviceCheck
import UIKit
#endif

final class SecureUpgradeAppAttestCaptureTests: XCTestCase {
    // Synthetic IDs from the public Secure/Upgrade vector shape. They are not
    // local household or person identifiers, but keep the Rust parser's format
    // constraints for the positive fixture.
    private static let fixtureHouseholdID =
        "hh_fnlwza7qi4rxuadflfmxocnx5rwdb3ef2meq6unnh7qqiosfyain"
    private static let fixtureOwnerPersonID =
        "p_ty3yfdchyn7nethoiefhrolfjxavzfe2bngb4tzzqy7cl3uqjfcq"

    func testCaptureRealIphoneAppAttestPositiveFixture() async throws {
        #if os(iOS)
        let env = ProcessInfo.processInfo.environment
        guard env["SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE"] == "1" else {
            throw XCTSkip("Secure/Upgrade App Attest capture is opt-in only")
        }
        try resetCaptureOutputDirectory()

        let captureRunID = try XCTUnwrap(
            env["SOYEHT_SECURE_UPGRADE_APP_ATTEST_CAPTURE_RUN_ID"]
        )
        guard !captureRunID.isEmpty else {
            XCTFail("Secure/Upgrade App Attest capture run id is required")
            return
        }

        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw XCTSkip("App Attest is not supported on this device")
        }

        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let expectedBundleID = env["SOYEHT_EXPECTED_BUNDLE_ID"] ?? "com.soyeht.app.dev"
        guard bundleID == expectedBundleID else {
            XCTFail("Secure/Upgrade App Attest capture must run under a Dev bundle")
            return
        }

        let teamID = env["SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID"] ?? "W7677A5BK2"
        let keyID = try await service.generateKey()
        let now = UInt64(Date().timeIntervalSince1970.rounded(.down))
        let userInterfaceIdiom = await MainActor.run { UIDevice.current.userInterfaceIdiom }
        let platform: SecureUpgradePlatform = userInterfaceIdiom == .pad
            ? .ipados
            : .ios

        let transcript = SecureUpgradeTranscript(
            householdID: Self.fixtureHouseholdID,
            ownerPersonID: Self.fixtureOwnerPersonID,
            ownerKeyID: "owner-key-example-capture",
            challengeID: "su-capture-\(captureRunID)",
            issuedAt: now,
            expiresAt: now + 300,
            appTeamID: teamID,
            appBundleID: bundleID,
            proofKeyID: keyID,
            proofEnvironment: .development,
            platform: platform
        )
        let canonicalTranscript = try transcript.canonicalBytes()
        let challengeDigest = SecureUpgradeTranscript.challengeDigest(
            canonicalTranscriptBytes: canonicalTranscript
        )
        let attestationObject = try await service.attestKey(
            keyID,
            clientDataHash: challengeDigest
        )

        let fixture = PositiveFixture(
            contract: "secure_upgrade_app_attest_positive_fixture_v1",
            captureRunID: captureRunID,
            environment: SecureUpgradeProofEnvironment.development.rawValue,
            canonicalTranscriptCborHex: Self.hex(canonicalTranscript),
            challengeSha256Hex: Self.hex(challengeDigest),
            appAttestKeyId: keyID,
            attestationObjectCborBase64: attestationObject.base64EncodedString(),
            verificationTimeUnix: now
        )
        try writeFixture(fixture)
        try writeResult(
            CaptureResult(
                status: "passed",
                reason: nil,
                captureRunID: captureRunID,
                environment: fixture.environment,
                challengeDigestMatchesTranscript: true,
                fixtureWritten: true
            )
        )
        #else
        throw XCTSkip("Secure/Upgrade App Attest capture requires iOS")
        #endif
    }

    private struct PositiveFixture: Encodable {
        var contract: String
        var captureRunID: String
        var environment: String
        var canonicalTranscriptCborHex: String
        var challengeSha256Hex: String
        var appAttestKeyId: String
        var attestationObjectCborBase64: String
        var verificationTimeUnix: UInt64

        enum CodingKeys: String, CodingKey {
            case contract
            case captureRunID = "capture_run_id"
            case environment
            case canonicalTranscriptCborHex = "canonical_transcript_cbor_hex"
            case challengeSha256Hex = "challenge_sha256_hex"
            case appAttestKeyId = "app_attest_key_id"
            case attestationObjectCborBase64 = "attestation_object_cbor_base64"
            case verificationTimeUnix = "verification_time_unix"
        }
    }

    private struct CaptureResult: Encodable {
        var status: String
        var reason: String?
        var captureRunID: String
        var environment: String
        var challengeDigestMatchesTranscript: Bool
        var fixtureWritten: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case reason
            case captureRunID = "capture_run_id"
            case environment
            case challengeDigestMatchesTranscript = "challenge_digest_matches_transcript"
            case fixtureWritten = "fixture_written"
        }
    }

    private func writeFixture(_ fixture: PositiveFixture) throws {
        let outputDirectory = try captureOutputDirectory()
        let outputURL = outputDirectory.appendingPathComponent("positive-fixture.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: outputURL, options: [.atomic, .completeFileProtection])
    }

    private func writeResult(_ result: CaptureResult) throws {
        let outputDirectory = try captureOutputDirectory()
        let outputURL = outputDirectory.appendingPathComponent("capture-result.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL, options: [.atomic, .completeFileProtection])
    }

    private func resetCaptureOutputDirectory() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let outputDirectory = documents.appendingPathComponent(
            "SecureUpgradeAppAttestCapture",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    private func captureOutputDirectory() throws -> URL {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let outputDirectory = documents.appendingPathComponent(
            "SecureUpgradeAppAttestCapture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        return outputDirectory
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
