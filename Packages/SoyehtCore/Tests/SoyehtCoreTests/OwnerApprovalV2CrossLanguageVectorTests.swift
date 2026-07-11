import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Swift half of the owner approval Protocol-v2 cross-language golden vectors.
/// Mobile vectors are vendored byte-for-byte from the authoritative theyos
/// `admin/contracts/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json`.
///
/// These drive the production ``OwnerApprovalContextV2`` encoder (not a test-local
/// copy) so the type that ships is the one proven byte-for-byte against Rust.
@Suite struct OwnerApprovalV2CrossLanguageVectorTests {
    private static let immutableMobileFixtureSHA256 =
        "c47ebb5d9f9a1309e45647dedcdcb20fd7abd47a46e6f31f5541d8f2711c316c"

    struct Vectors: Decodable {
        let ownerApprovalContextV2: [OwnerApprovalCase]
    }

    struct MobileVectors: Decodable {
        let mobileClawVpnDevE2EExecutionTupleV1: [MobileExecutionCase]
        let ownerApprovalContextV2: [OwnerApprovalCase]
    }

    struct MobileExecutionCase: Decodable {
        let id: String
        let input: MobileExecutionInput
        let canonicalCborHex: String
        let executionSha256Hex: String
    }

    struct MobileExecutionInput: Decodable {
        let v: UInt8
        let purpose: String
        let op: String
        let hhId: String
        let engineAudienceHex: String
        let memberId: String
        let attemptId: String
        let readinessRunId: String
        let sourceArtifactGitSha1Hex: String
        let executionManifestSha256Hex: String
        let deviceBindingHex: String
        let executionRunId: String
        let executionClaimSha256Hex: String
        let bundleId: String
        let deviceId: String
        let clawId: String
        let deviceAlias: String
        let clawAlias: String
        let issuedAt: UInt64
        let expiresAt: UInt64
        let serverNonceHex: String
    }

    struct OwnerApprovalCase: Decodable {
        let id: String
        let input: OwnerApprovalInput
        let canonicalCborHex: String
        let challengeSha256Hex: String
        let omittedFields: [String]?
    }

    struct OwnerApprovalInput: Decodable {
        var v: UInt64
        var purpose: String
        var op: String
        var hhId: String
        var ownerPId: String
        var cursor: UInt64?
        var mId: String?
        var addr: String?
        var transport: String?
        var ttlUnix: UInt64?
        var nonceHex: String?
        var joinRequestHashHex: String?
        var mobileClawVpnExecutionTupleId: String?
        var capabilities: [String]
        var issuedAt: UInt64
        var expiresAt: UInt64
        var replayNonceHex: String
    }

    enum VectorError: Error { case fixtureMissing }

    static func loadVectors() throws -> Vectors {
        guard let url = Bundle.module.url(forResource: "owner_approval_v2_vectors", withExtension: "json") else {
            throw VectorError.fixtureMissing
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: data)
    }

    static func loadMobileFixtureData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "owner_approval_v2_execution_vectors",
            withExtension: "json",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        ) else {
            throw VectorError.fixtureMissing
        }
        return try Data(contentsOf: url)
    }

    static func loadMobileVectors() throws -> MobileVectors {
        let data = try loadMobileFixtureData()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MobileVectors.self, from: data)
    }

    @Test func mobileFixtureV1HasImmutableFileDigest() throws {
        let digest = Data(SHA256.hash(data: try Self.loadMobileFixtureData()))
            .soyehtHexEncodedString()
        #expect(digest == Self.immutableMobileFixtureSHA256)
    }

    @Test func canonicalBytesAndChallengeDigestMatchRustFixture() throws {
        let vectors = try Self.loadVectors()
        let mobileVectors = try Self.loadMobileVectors()
        #expect(!vectors.ownerApprovalContextV2.isEmpty)
        #expect(!mobileVectors.ownerApprovalContextV2.isEmpty)
        for fixture in [
            (vectors.ownerApprovalContextV2, [MobileExecutionCase]()),
            (mobileVectors.ownerApprovalContextV2, mobileVectors.mobileClawVpnDevE2EExecutionTupleV1),
        ] {
            for vector in fixture.0 {
                let context = try Self.context(vector.input, executions: fixture.1)
                let canonicalBytes = try context.canonicalBytes()
                let canonicalHex = canonicalBytes.soyehtHexEncodedString()
                #expect(
                    canonicalHex == vector.canonicalCborHex,
                    "\(vector.id): DRIFT - Swift canonical CBOR != Rust. expected \(vector.canonicalCborHex) got \(canonicalHex)"
                )
                #expect(
                    try context.challengeDigest().soyehtHexEncodedString() == vector.challengeSha256Hex,
                    "\(vector.id): WebAuthn challenge digest drifted"
                )
            }
        }
    }

    @Test func executionTupleCanonicalBytesAndHashMatchRustFixture() throws {
        let vectors = try Self.loadMobileVectors()
        #expect(!vectors.mobileClawVpnDevE2EExecutionTupleV1.isEmpty)
        for vector in vectors.mobileClawVpnDevE2EExecutionTupleV1 {
            let execution = try Self.execution(vector.input)
            #expect(
                try execution.canonicalBytes().soyehtHexEncodedString() == vector.canonicalCborHex,
                "\(vector.id): Swift execution tuple CBOR != Rust"
            )
            #expect(
                try execution.executionHash().soyehtHexEncodedString() == vector.executionSha256Hex,
                "\(vector.id): Swift execution hash != Rust"
            )
            #expect(try MobileClawVPNDevE2EExecutionTupleV1(
                canonicalBytes: execution.canonicalBytes()
            ) == execution)
        }
    }

    @Test func executionHashChangesForEveryMutableTupleField() throws {
        let vectors = try Self.loadMobileVectors()
        let vector = try #require(vectors.mobileClawVpnDevE2EExecutionTupleV1.first)
        let baseline = try Self.execution(vector.input)
        let baselineBytes = try baseline.canonicalBytes()
        let baselineHash = try baseline.executionHash()
        let baselineContext = try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
            ownerPersonID: "p_owner-alpha",
            execution: baseline,
            replayNonce: Data(repeating: 0xf0, count: 32)
        )
        let baselineChallenge = try baselineContext.challengeDigest()
        var mutations: [(String, MobileClawVPNDevE2EExecutionTupleV1)] = []

        var value = baseline
        value.householdID = "hh_" + String(repeating: "c", count: 52)
        mutations.append(("hh_id", value))
        value = baseline
        value.engineAudience = Data(repeating: 0x91, count: 32)
        mutations.append(("engine_audience", value))
        value = baseline
        value.memberID = "member-beta"
        mutations.append(("member_id", value))
        value = baseline
        value.attemptID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        mutations.append(("attempt_id", value))
        value = baseline
        value.readinessRunID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        mutations.append(("readiness_run_id", value))
        value = baseline
        value.sourceArtifactGitSHA1 = Data(repeating: 0xa1, count: 20)
        mutations.append(("source_artifact_git_sha1", value))
        value = baseline
        value.executionManifestSHA256 = Data(repeating: 0xb1, count: 32)
        mutations.append(("execution_manifest_sha256", value))
        value = baseline
        value.deviceBinding = Data(repeating: 0xc1, count: 32)
        mutations.append(("device_binding", value))
        value = baseline
        value.executionRunID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        mutations.append(("execution_run_id", value))
        value = baseline
        value.executionClaimSHA256 = Data(repeating: 0xd1, count: 32)
        mutations.append(("execution_claim_sha256", value))
        value = baseline
        value.deviceID = "device-beta"
        mutations.append(("device_id", value))
        value = baseline
        value.clawID = "claw-beta"
        mutations.append(("claw_id", value))
        value = baseline
        value.clawAlias = "Claw-L"
        mutations.append(("claw_alias", value))
        value = baseline
        value.issuedAt = 1_001
        mutations.append(("issued_at", value))
        value = baseline
        value.expiresAt = 1_061
        mutations.append(("expires_at", value))
        value = baseline
        value.serverNonce = Data(repeating: 0xe1, count: 32)
        mutations.append(("server_nonce", value))

        for (field, mutation) in mutations {
            #expect(try mutation.canonicalBytes() != baselineBytes, "\(field): CBOR unchanged")
            #expect(try mutation.executionHash() != baselineHash, "\(field): digest unchanged")
            let mutatedContext = try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
                ownerPersonID: baselineContext.ownerPersonID,
                execution: mutation,
                replayNonce: baselineContext.replayNonce
            )
            #expect(
                try mutatedContext.challengeDigest() != baselineChallenge,
                "\(field): owner challenge unchanged"
            )
        }
    }

    @Test func executionTupleRejectsFixedFieldAndLengthDrift() throws {
        let vectors = try Self.loadMobileVectors()
        let vector = try #require(vectors.mobileClawVpnDevE2EExecutionTupleV1.first)
        let baseline = try Self.execution(vector.input)

        var invalid = baseline
        invalid.version = 2
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.purpose = "other"
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.op = .pairMachineApprove
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.bundleID = "com.soyeht.app"
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.deviceAlias = "Device-X"
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.householdID = "hh_test"
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.canonicalBytes()
        }
        invalid = baseline
        invalid.sourceArtifactGitSHA1 = Data(repeating: 0xaa, count: 19)
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
        invalid = baseline
        invalid.serverNonce = Data(repeating: 0xee, count: 33)
        #expect(throws: MobileClawVPNDevE2EExecutionTupleError.invalidShape) {
            try invalid.validateShape()
        }
    }

    @Test func executionHashIsDomainSeparatedAndLengthDelimited() throws {
        let vectors = try Self.loadMobileVectors()
        let vector = try #require(vectors.mobileClawVpnDevE2EExecutionTupleV1.first)
        let baseline = try Self.execution(vector.input)
        let canonical = try baseline.canonicalBytes()
        #expect(try baseline.executionHash() != Data(SHA256.hash(data: canonical)))

        var left = baseline
        left.memberID = "a"
        left.deviceID = "bc"
        var right = baseline
        right.memberID = "ab"
        right.deviceID = "c"
        #expect(try left.canonicalBytes() != right.canonicalBytes())
        #expect(try left.executionHash() != right.executionHash())
    }

    @Test func contextRequiresExactOperationSpecificExecutionHash() throws {
        let vectors = try Self.loadMobileVectors()
        let vector = try #require(vectors.mobileClawVpnDevE2EExecutionTupleV1.first)
        let execution = try Self.execution(vector.input)
        let context = try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
            ownerPersonID: "p_owner-alpha",
            execution: execution,
            replayNonce: Data(repeating: 0xf0, count: 32)
        )
        let expectedHash = try execution.executionHash()
        #expect(context.mobileClawVPNExecutionHash == expectedHash)

        let baselineChallenge = try context.challengeDigest()
        var changedHash = context
        changedHash.mobileClawVPNExecutionHash = Data(repeating: 0x45, count: 32)
        #expect(try changedHash.challengeDigest() != baselineChallenge)

        var changedHousehold = context
        changedHousehold.householdID = "hh_" + String(repeating: "d", count: 52)
        var changedOwner = context
        changedOwner.ownerPersonID = "p_owner-beta"
        var changedIssuedAt = context
        changedIssuedAt.issuedAt += 1
        var changedExpiresAt = context
        changedExpiresAt.expiresAt += 1
        var changedReplay = context
        changedReplay.replayNonce = Data(repeating: 0xf1, count: 32)

        for (field, mutation) in [
            ("mobile_claw_vpn_execution_hash", changedHash),
            ("hh_id", changedHousehold),
            ("owner_p_id", changedOwner),
            ("issued_at", changedIssuedAt),
            ("expires_at", changedExpiresAt),
            ("replay_nonce", changedReplay),
        ] {
            #expect(try mutation.challengeDigest() != baselineChallenge, "\(field): challenge unchanged")
        }

        guard case .map(let validMap) = try context.cborValue() else {
            Issue.record("context must encode as map")
            return
        }

        var invalid = context
        invalid.mobileClawVPNExecutionHash = nil
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalid.validateMobileClawVPNOperationShape()
        }
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalid.challengeDigest()
        }
        for length in [31, 33] {
            invalid = context
            invalid.mobileClawVPNExecutionHash = Data(repeating: 0x44, count: length)
            #expect(throws: OwnerApprovalV2DTOError.self) {
                try invalid.validateMobileClawVPNOperationShape()
            }
            #expect(throws: OwnerApprovalV2DTOError.self) {
                try invalid.challengeDigest()
            }
        }

        var zeroTTL = context
        zeroTTL.expiresAt = zeroTTL.issuedAt
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try zeroTTL.challengeDigest()
        }
        var excessiveTTL = context
        excessiveTTL.expiresAt = excessiveTTL.issuedAt + 121
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try excessiveTTL.challengeDigest()
        }
        var invalidHousehold = context
        invalidHousehold.householdID = "hh_test"
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalidHousehold.challengeDigest()
        }
        var invalidOwner = context
        invalidOwner.ownerPersonID = "owner-alpha"
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalidOwner.challengeDigest()
        }

        invalid = context
        invalid.op = .bootstrapTeardown
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalid.validateMobileClawVPNOperationShape()
        }
        #expect(throws: OwnerApprovalV2DTOError.self) {
            try invalid.challengeDigest()
        }

        var missingMap = validMap
        missingMap.removeValue(forKey: "mobile_claw_vpn_execution_hash")
        #expect(throws: OwnerApprovalV2DTOError.self) {
            _ = try OwnerApprovalContextV2(cbor: .map(missingMap))
        }

        for length in [31, 33] {
            var wrongLengthMap = validMap
            wrongLengthMap["mobile_claw_vpn_execution_hash"] = .bytes(
                Data(repeating: 0x44, count: length)
            )
            #expect(throws: OwnerApprovalV2DTOError.self) {
                _ = try OwnerApprovalContextV2(cbor: .map(wrongLengthMap))
            }
        }

        var crossOperationMap = validMap
        crossOperationMap["op"] = .text(OwnerApprovalOperation.bootstrapTeardown.rawValue)
        #expect(throws: OwnerApprovalV2DTOError.self) {
            _ = try OwnerApprovalContextV2(cbor: .map(crossOperationMap))
        }

        var map = validMap
        map["op"] = .text("future-owner-operation")
        #expect(throws: OwnerApprovalV2DTOError.self) {
            _ = try OwnerApprovalContextV2(cbor: .map(map))
        }

        map = validMap
        map["future_field"] = .text("must-not-be-ignored")
        #expect(throws: OwnerApprovalV2DTOError.self) {
            _ = try OwnerApprovalContextV2(cbor: .map(map))
        }
    }

    @Test func invalidMobileShapeCannotEncodeAtAnyEnvelopeLayer() throws {
        let vectors = try Self.loadMobileVectors()
        let vector = try #require(vectors.mobileClawVpnDevE2EExecutionTupleV1.first)
        let execution = try Self.execution(vector.input)
        var context = try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
            ownerPersonID: "p_owner-alpha",
            execution: execution,
            replayNonce: Data(repeating: 0xf0, count: 32)
        )
        context.mobileClawVPNExecutionHash = nil
        let approval = OwnerApprovalV2(
            context: context,
            credentialID: Data([0x01]),
            authenticatorData: Data([0x02]),
            clientDataJSON: Data([0x03]),
            signature: Data([0x04])
        )
        let finish = OwnerApprovalV2Finish(
            challengeID: "0123456789abcdef0123456789abcdef",
            approval: approval
        )

        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try context.cborValue() }
        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try context.canonicalBytes() }
        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try approval.cborValue() }
        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try approval.canonicalBytes() }
        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try finish.cborValue() }
        #expect(throws: OwnerApprovalV2DTOError.self) { _ = try finish.canonicalBytes() }
    }

    @Test func optionalFieldsAreOmittedNotNull() throws {
        let vectors = try Self.loadVectors()
        let mobileVectors = try Self.loadMobileVectors()
        for fixture in [
            (vectors.ownerApprovalContextV2, [MobileExecutionCase]()),
            (mobileVectors.ownerApprovalContextV2, mobileVectors.mobileClawVpnDevE2EExecutionTupleV1),
        ] {
            for vector in fixture.0 {
                let omittedFields = vector.omittedFields ?? []
                let canonical = try Self.context(
                    vector.input,
                    executions: fixture.1
                ).canonicalBytes()
                guard case .map(let map) = try HouseholdCBOR.decode(canonical) else {
                    Issue.record("\(vector.id): expected context to decode as map")
                    continue
                }
                for omitted in omittedFields {
                    #expect(map[omitted] == nil, "\(vector.id): optional field \(omitted) was encoded")
                }
                if vector.input.op != OwnerApprovalOperation.mobileClawVPNDevE2EExecute.rawValue {
                    #expect(map["mobile_claw_vpn_execution_hash"] == nil)
                }
            }
        }
    }

    @Test func challengeDigestChangesWhenBoundFieldsChange() throws {
        let vectors = try Self.loadVectors()
        let vector = try #require(vectors.ownerApprovalContextV2.first)
        let baseline = try Self.context(
            vector.input,
            executions: []
        ).challengeDigest()

        var changedOperation = try Self.context(
            vector.input,
            executions: []
        )
        changedOperation.op = .bootstrapTeardown
        #expect(try changedOperation.challengeDigest() != baseline)

        var changedAddress = try Self.context(
            vector.input,
            executions: []
        )
        changedAddress.addr = "198.51.100.10:8091"
        #expect(try changedAddress.challengeDigest() != baseline)

        var changedNonce = try Self.context(
            vector.input,
            executions: []
        )
        changedNonce.nonce = Data(repeating: 0x44, count: 16)
        #expect(try changedNonce.challengeDigest() != baseline)
    }

    /// Maps a golden-vector input row into the production ``OwnerApprovalContextV2``.
    private static func context(
        _ input: OwnerApprovalInput,
        executions: [MobileExecutionCase]
    ) throws -> OwnerApprovalContextV2 {
        let op = try #require(
            OwnerApprovalOperation(rawValue: input.op),
            "unknown op in fixture: \(input.op)"
        )
        if op == .mobileClawVPNDevE2EExecute {
            let tupleID = try #require(input.mobileClawVpnExecutionTupleId)
            let tupleCase = try #require(executions.first { $0.id == tupleID })
            let execution = try Self.execution(tupleCase.input)
            #expect(input.v == UInt64(OwnerApprovalContextV2.currentVersion))
            #expect(input.purpose == OwnerApprovalContextV2.purpose)
            #expect(input.hhId == execution.householdID)
            #expect(input.capabilities == [MobileClawVPNDevE2EExecutionTupleV1.capability])
            #expect(input.issuedAt == execution.issuedAt)
            #expect(input.expiresAt == execution.expiresAt)
            #expect(input.cursor == nil)
            #expect(input.mId == nil)
            #expect(input.addr == nil)
            #expect(input.transport == nil)
            #expect(input.ttlUnix == nil)
            #expect(input.nonceHex == nil)
            #expect(input.joinRequestHashHex == nil)
            return try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
                ownerPersonID: input.ownerPId,
                execution: execution,
                replayNonce: Self.hexDecode(input.replayNonceHex)
            )
        }

        return OwnerApprovalContextV2(
            version: UInt8(input.v),
            purpose: input.purpose,
            op: op,
            householdID: input.hhId,
            ownerPersonID: input.ownerPId,
            cursor: input.cursor,
            machineID: input.mId,
            addr: input.addr,
            transport: input.transport,
            ttlUnix: input.ttlUnix,
            nonce: input.nonceHex.map(Self.hexDecode),
            joinRequestHash: input.joinRequestHashHex.map(Self.hexDecode),
            capabilities: input.capabilities,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            replayNonce: Self.hexDecode(input.replayNonceHex)
        )
    }

    private static func execution(_ input: MobileExecutionInput) throws
        -> MobileClawVPNDevE2EExecutionTupleV1
    {
        #expect(input.v == MobileClawVPNDevE2EExecutionTupleV1.currentVersion)
        #expect(input.purpose == MobileClawVPNDevE2EExecutionTupleV1.purpose)
        #expect(input.op == MobileClawVPNDevE2EExecutionTupleV1.operation.rawValue)
        #expect(input.bundleId == MobileClawVPNDevE2EExecutionTupleV1.bundleID)
        let execution = MobileClawVPNDevE2EExecutionTupleV1(
            householdID: input.hhId,
            engineAudience: hexDecode(input.engineAudienceHex),
            memberID: input.memberId,
            attemptID: input.attemptId,
            readinessRunID: input.readinessRunId,
            sourceArtifactGitSHA1: hexDecode(input.sourceArtifactGitSha1Hex),
            executionManifestSHA256: hexDecode(input.executionManifestSha256Hex),
            deviceBinding: hexDecode(input.deviceBindingHex),
            executionRunID: input.executionRunId,
            executionClaimSHA256: hexDecode(input.executionClaimSha256Hex),
            deviceID: input.deviceId,
            clawID: input.clawId,
            deviceAlias: input.deviceAlias,
            clawAlias: input.clawAlias,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            serverNonce: hexDecode(input.serverNonceHex)
        )
        try execution.validateShape()
        return execution
    }

    private static func hexDecode(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
