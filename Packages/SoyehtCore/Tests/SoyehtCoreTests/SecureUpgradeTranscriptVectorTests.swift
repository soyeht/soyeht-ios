import Foundation
import Testing

@testable import SoyehtCore

@Suite("Secure/Upgrade transcript vectors")
struct SecureUpgradeTranscriptVectorTests {
    struct Fixture: Decodable {
        let contract: String
        let version: Int
        let commitmentModel: CommitmentModel
        let vectors: [Vector]
    }

    struct CommitmentModel: Decodable {
        let digest: String
        let appAttestClientDataHash: String
        let ownerSignatureInput: String
        let verifyOnly: Bool
    }

    struct Vector: Decodable {
        let id: String
        let input: Input
        let canonicalCborHex: String
        let challengeSha256Hex: String
        let commitments: Commitments
    }

    struct Commitments: Decodable {
        let appAttestClientDataHashHex: String
        let ownerSignatureInputHex: String
        let rawCborSha256Hex: String
    }

    struct Input: Decodable {
        let v: UInt8
        let purpose: String
        let op: String
        let hhId: String
        let ownerPId: String
        let ownerKeyId: String
        let challengeId: String
        let issuedAt: UInt64
        let expiresAt: UInt64
        let appTeamId: String
        let appBundleId: String
        let proofModel: String
        let proofKeyId: String
        let proofEnvironment: String
        let platform: String
        let targetProvenance: String
    }

    @Test func canonicalBytesAndDigestMatchRustFixture() throws {
        let fixture = try Self.loadFixture()
        #expect(fixture.contract == "secure_upgrade_transcript_v1")
        #expect(fixture.version == 1)
        #expect(fixture.commitmentModel.digest == "SHA256(soyeht-secure-upgrade-v1\\0 || canonical_transcript_cbor)")
        #expect(fixture.commitmentModel.appAttestClientDataHash == "challenge_digest")
        #expect(fixture.commitmentModel.ownerSignatureInput == "challenge_digest")
        #expect(fixture.commitmentModel.verifyOnly)
        #expect(fixture.vectors.count == 2)

        for vector in fixture.vectors {
            let transcript = try Self.transcript(vector.input)
            let storedCanonicalTranscript = try Self.hexDecode(vector.canonicalCborHex)
            let serverRecomputedDigest = SecureUpgradeTranscript.challengeDigest(
                canonicalTranscriptBytes: storedCanonicalTranscript
            )
            #expect(
                try transcript.canonicalBytes() == storedCanonicalTranscript,
                "\(vector.id): Swift canonical CBOR drifted from Rust"
            )
            #expect(
                try transcript.challengeDigest() == serverRecomputedDigest,
                "\(vector.id): challenge digest was not derived from stored canonical transcript"
            )
            #expect(
                serverRecomputedDigest.soyehtHexEncodedString() == vector.challengeSha256Hex,
                "\(vector.id): challenge digest drifted from Rust"
            )
            #expect(try transcript.appAttestClientDataHash() == serverRecomputedDigest)
            #expect(try transcript.ownerSignatureInput() == serverRecomputedDigest)
            #expect(vector.commitments.appAttestClientDataHashHex == vector.challengeSha256Hex)
            #expect(vector.commitments.ownerSignatureInputHex == vector.challengeSha256Hex)
        }
    }

    @Test func digestChangesWhenBoundFieldsChange() throws {
        let vector = try #require(Self.loadFixture().vectors.first)
        let baseline = try Self.transcript(vector.input)
        let baselineDigest = try baseline.challengeDigest()

        var changedChallenge = baseline
        changedChallenge.challengeID = "su-challenge-ios-alpha-rotated"
        #expect(try changedChallenge.challengeDigest() != baselineDigest)
        #expect(try changedChallenge.appAttestClientDataHash() != baselineDigest)
        #expect(try changedChallenge.ownerSignatureInput() != baselineDigest)

        var changedProofKey = baseline
        changedProofKey.proofKeyID = "appattest-key-ios-beta"
        #expect(try changedProofKey.challengeDigest() != baselineDigest)
        #expect(try changedProofKey.appAttestClientDataHash() != baselineDigest)
        #expect(try changedProofKey.ownerSignatureInput() != baselineDigest)

        var changedOwnerKey = baseline
        changedOwnerKey.ownerKeyID = "owner-key-ios-beta"
        #expect(try changedOwnerKey.challengeDigest() != baselineDigest)
        #expect(try changedOwnerKey.appAttestClientDataHash() != baselineDigest)
        #expect(try changedOwnerKey.ownerSignatureInput() != baselineDigest)
    }

    @Test func proofCommitmentsMustMatchServerRecomputedDigest() throws {
        let fixture = try Self.loadFixture()

        for vector in fixture.vectors {
            let storedCanonicalTranscript = try Self.hexDecode(vector.canonicalCborHex)
            let serverRecomputedDigest = SecureUpgradeTranscript.challengeDigest(
                canonicalTranscriptBytes: storedCanonicalTranscript
            )
            let commitments = SecureUpgradeProofCommitments(
                clientDataHash: try Self.hexDecode(vector.commitments.appAttestClientDataHashHex),
                ownerSignatureInput: try Self.hexDecode(vector.commitments.ownerSignatureInputHex)
            )

            let verification = try SecureUpgradeTranscript.verifyProofCommitments(
                canonicalTranscriptBytes: storedCanonicalTranscript,
                commitments: commitments
            )
            #expect(verification.challengeDigest == serverRecomputedDigest)
        }
    }

    @Test func boundFieldTamperBreaksBothCommitmentPaths() throws {
        let vector = try #require(Self.loadFixture().vectors.first)
        let baseline = try Self.transcript(vector.input)
        let baselineDigest = try baseline.challengeDigest()
        var changed = baseline
        changed.ownerKeyID = "owner-key-ios-beta"
        let changedCanonicalTranscript = try changed.canonicalBytes()
        let changedDigest = SecureUpgradeTranscript.challengeDigest(
            canonicalTranscriptBytes: changedCanonicalTranscript
        )
        #expect(changedDigest != baselineDigest)

        #expect(throws: SecureUpgradeCommitmentError.clientDataHashMismatch) {
            _ = try SecureUpgradeTranscript.verifyProofCommitments(
                canonicalTranscriptBytes: changedCanonicalTranscript,
                commitments: SecureUpgradeProofCommitments(
                    clientDataHash: baselineDigest,
                    ownerSignatureInput: changedDigest
                )
            )
        }
        #expect(throws: SecureUpgradeCommitmentError.ownerSignatureInputMismatch) {
            _ = try SecureUpgradeTranscript.verifyProofCommitments(
                canonicalTranscriptBytes: changedCanonicalTranscript,
                commitments: SecureUpgradeProofCommitments(
                    clientDataHash: changedDigest,
                    ownerSignatureInput: baselineDigest
                )
            )
        }
    }

    @Test func mixedChallengeProofsAreRejected() throws {
        let vectors = try Self.loadFixture().vectors
        let ios = try #require(vectors.first { $0.id == "ios_app_attest_production" })
        let ipados = try #require(vectors.first { $0.id == "ipados_app_attest_development" })
        let iosCanonicalTranscript = try Self.hexDecode(ios.canonicalCborHex)
        let iosDigest = try Self.hexDecode(ios.challengeSha256Hex)
        let ipadosDigest = try Self.hexDecode(ipados.challengeSha256Hex)
        #expect(iosDigest != ipadosDigest)

        #expect(throws: SecureUpgradeCommitmentError.ownerSignatureInputMismatch) {
            _ = try SecureUpgradeTranscript.verifyProofCommitments(
                canonicalTranscriptBytes: iosCanonicalTranscript,
                commitments: SecureUpgradeProofCommitments(
                    clientDataHash: iosDigest,
                    ownerSignatureInput: ipadosDigest
                )
            )
        }
        #expect(throws: SecureUpgradeCommitmentError.clientDataHashMismatch) {
            _ = try SecureUpgradeTranscript.verifyProofCommitments(
                canonicalTranscriptBytes: iosCanonicalTranscript,
                commitments: SecureUpgradeProofCommitments(
                    clientDataHash: ipadosDigest,
                    ownerSignatureInput: iosDigest
                )
            )
        }
    }

    @Test func rawCborWithoutDomainPrefixRejected() throws {
        for vector in try Self.loadFixture().vectors {
            let canonicalTranscript = try Self.hexDecode(vector.canonicalCborHex)
            let domainSeparatedDigest = SecureUpgradeTranscript.challengeDigest(
                canonicalTranscriptBytes: canonicalTranscript
            )
            let rawCborDigest = try Self.hexDecode(vector.commitments.rawCborSha256Hex)
            #expect(rawCborDigest != domainSeparatedDigest)

            #expect(throws: SecureUpgradeCommitmentError.clientDataHashMismatch) {
                _ = try SecureUpgradeTranscript.verifyProofCommitments(
                    canonicalTranscriptBytes: canonicalTranscript,
                    commitments: SecureUpgradeProofCommitments(
                        clientDataHash: rawCborDigest,
                        ownerSignatureInput: domainSeparatedDigest
                    )
                )
            }
            #expect(throws: SecureUpgradeCommitmentError.ownerSignatureInputMismatch) {
                _ = try SecureUpgradeTranscript.verifyProofCommitments(
                    canonicalTranscriptBytes: canonicalTranscript,
                    commitments: SecureUpgradeProofCommitments(
                        clientDataHash: domainSeparatedDigest,
                        ownerSignatureInput: rawCborDigest
                    )
                )
            }
            #expect(throws: SecureUpgradeCommitmentError.clientDataHashMismatch) {
                _ = try SecureUpgradeTranscript.verifyProofCommitments(
                    canonicalTranscriptBytes: canonicalTranscript,
                    commitments: SecureUpgradeProofCommitments(
                        clientDataHash: rawCborDigest,
                        ownerSignatureInput: rawCborDigest
                    )
                )
            }
        }
    }

    @Test func targetProvenanceMustMatchPlatform() throws {
        let vector = try #require(Self.loadFixture().vectors.first)
        var transcript = try Self.transcript(vector.input)
        transcript.targetProvenance = "ipados-app-attest-owner"
        #expect(throws: SecureUpgradeTranscriptError.self) {
            _ = try transcript.canonicalBytes()
        }
    }

    private static func loadFixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "secure_upgrade_transcript_vectors",
                withExtension: "json"
            )
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func hexDecode(_ string: String) throws -> Data {
        try #require(Data(soyehtHex: string))
    }

    private static func transcript(_ input: Input) throws -> SecureUpgradeTranscript {
        let operation = try #require(SecureUpgradeOperation(rawValue: input.op))
        let proofModel = try #require(SecureUpgradeProofModel(rawValue: input.proofModel))
        let proofEnvironment = try #require(SecureUpgradeProofEnvironment(rawValue: input.proofEnvironment))
        let platform = try #require(SecureUpgradePlatform(rawValue: input.platform))
        #expect(input.v == 1)
        #expect(input.purpose == SecureUpgradeTranscript.purpose)
        #expect(input.targetProvenance == platform.appAttestProvenance)
        return SecureUpgradeTranscript(
            version: input.v,
            purpose: input.purpose,
            operation: operation,
            householdID: input.hhId,
            ownerPersonID: input.ownerPId,
            ownerKeyID: input.ownerKeyId,
            challengeID: input.challengeId,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            appTeamID: input.appTeamId,
            appBundleID: input.appBundleId,
            proofModel: proofModel,
            proofKeyID: input.proofKeyId,
            proofEnvironment: proofEnvironment,
            platform: platform,
            targetProvenance: input.targetProvenance
        )
    }
}
