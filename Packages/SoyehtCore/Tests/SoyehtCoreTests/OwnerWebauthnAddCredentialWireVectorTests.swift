import Foundation
import Testing

@testable import SoyehtCore

/// Swift half of the AddCredential composite wire vectors emitted by theyos.
/// The nested registration and approval blocks already have their own vector
/// suites; this pins the outer dual-ceremony wrappers byte-for-byte.
@Suite struct OwnerWebauthnAddCredentialWireVectorTests {
    struct WireVectors: Decodable {
        let addCredentialStartResponses: [StartCase]
        let addCredentialFinishRequests: [FinishCase]
    }

    struct StartCase: Decodable {
        let id: String
        let input: StartInput
        let canonicalCborHex: String
    }

    struct FinishCase: Decodable {
        let id: String
        let input: FinishInput
        let canonicalCborHex: String
    }

    struct StartInput: Decodable {
        let v: UInt64
        let registration: RegistrationStartInput
        let approval: ApprovalStartInput
        let context: ContextInput
    }

    struct FinishInput: Decodable {
        let v: UInt64
        let context: ContextInput
        let registration: RegistrationFinishInput
        let approval: ApprovalFinishInput
    }

    struct RegistrationStartInput: Decodable {
        let v: UInt64
        let challengeId: String
        let options: RegistrationOptionsInput
    }

    struct RegistrationOptionsInput: Decodable {
        let publicKey: RegistrationPublicKeyInput
    }

    struct RegistrationPublicKeyInput: Decodable {
        let challenge: String
    }

    struct ApprovalStartInput: Decodable {
        let v: UInt64
        let challengeId: String
        let context: ContextInput
        let options: ApprovalOptionsInput
    }

    struct ApprovalOptionsInput: Decodable {
        let publicKey: ApprovalPublicKeyInput
    }

    struct ApprovalPublicKeyInput: Decodable {
        let rpId: String
        let challenge: String
        let allowCredentials: [ApprovalAllowCredentialInput]?
        let userVerification: String?
    }

    struct ApprovalAllowCredentialInput: Decodable {
        let id: String
    }

    struct RegistrationFinishInput: Decodable {
        let v: UInt64
        let challengeId: String
        let credential: RegisterCredentialInput
    }

    struct RegisterCredentialInput: Decodable {
        let id: String
        let rawId: String
        let response: AttestationResponseInput
        let type: String
        let extensions: RegistrationExtensionsInput
    }

    struct AttestationResponseInput: Decodable {
        let attestationObject: String
        let clientDataJSON: String
        let transports: [String]?
    }

    struct RegistrationExtensionsInput: Decodable {}

    struct ApprovalFinishInput: Decodable {
        let v: UInt64
        let challengeId: String
        let approval: ApprovalInput
    }

    struct ApprovalInput: Decodable {
        let v: UInt64
        let context: ContextInput
        let credentialIdHex: String
        let authenticatorDataHex: String
        let clientDataJsonHex: String
        let signatureHex: String
        let userHandleHex: String?
    }

    struct ContextInput: Decodable {
        let v: UInt64
        let purpose: String
        let op: String
        let hhId: String
        let ownerPId: String
        let newCredentialBindingHashHex: String
        let authorityHeadSequence: UInt64
        let authorityHeadHashHex: String
        let preActiveCredentialCount: UInt64
        let capabilities: [String]
        let issuedAt: UInt64
        let expiresAt: UInt64
        let replayNonceHex: String
    }

    enum FixtureError: Error { case missingFixture }

    static func loadVectors() throws -> WireVectors {
        guard let url = Bundle.module.url(
            forResource: "owner_webauthn_add_credential_wire_vectors",
            withExtension: "json"
        ) else {
            throw FixtureError.missingFixture
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WireVectors.self, from: try Data(contentsOf: url))
    }

    @Test func addCredentialStartResponseDecodesCompositeRustVector() throws {
        let vectors = try Self.loadVectors()
        let vector = try #require(vectors.addCredentialStartResponses.first)
        let bytes = try #require(Data(soyehtHex: vector.canonicalCborHex))
        let cbor = try HouseholdCBOR.decode(bytes)
        #expect(HouseholdCBOR.encode(cbor) == bytes)

        let response = try OwnerWebauthnAddCredentialStartResponse(cbor: cbor)
        let expected = vector.input

        #expect(response.version == UInt8(expected.v))
        #expect(response.registration.challengeID == expected.registration.challengeId)
        #expect(response.registration.options.publicKey.challenge == expected.registration.options.publicKey.challenge)
        #expect(response.approval.challengeID == expected.approval.challengeId)
        #expect(response.approval.relyingPartyIdentifier == expected.approval.options.publicKey.rpId)
        #expect(response.approval.challenge == PairingCrypto.base64URLDecode(expected.approval.options.publicKey.challenge))
        #expect(response.approval.userVerification == expected.approval.options.publicKey.userVerification)
        let expectedApprovalIDs = (expected.approval.options.publicKey.allowCredentials ?? [])
            .map { PairingCrypto.base64URLDecode($0.id)! }
        #expect(response.approval.allowedCredentialIDs == expectedApprovalIDs)

        #expect(response.context == Self.context(expected.context))
        #expect(
            try response.approval.context.canonicalBytes()
                == response.context.canonicalBytes()
        )
        #expect(response.context.op == .addCredential)
        #expect(response.context.newCredentialBindingHash == Self.hexDecode(expected.context.newCredentialBindingHashHex))
        #expect(response.context.authorityHeadSequence == expected.context.authorityHeadSequence)
        #expect(response.context.authorityHeadHash == Self.hexDecode(expected.context.authorityHeadHashHex))
        #expect(response.context.preActiveCredentialCount == expected.context.preActiveCredentialCount)
    }

    @Test func addCredentialFinishRequestEncoderMatchesRustVector() throws {
        let vectors = try Self.loadVectors()
        let vector = try #require(vectors.addCredentialFinishRequests.first)
        let request = Self.finishRequest(vector.input)
        let encoded = try request.canonicalBytes()
        #expect(
            encoded.soyehtHexEncodedString() == vector.canonicalCborHex,
            "\(vector.id): Swift AddCredential finish wrapper canonical CBOR drifted from Rust"
        )

        let top = try Self.map(HouseholdCBOR.decode(encoded), "\(vector.id).top")
        let registration = try Self.map(top["registration"], "\(vector.id).registration")
        let credential = try Self.map(registration["credential"], "\(vector.id).registration.credential")
        #expect(credential["id"] == .text(vector.input.registration.credential.id))
        #expect(credential["rawId"] == .text(vector.input.registration.credential.rawId))

        let approvalFinish = try Self.map(top["approval"], "\(vector.id).approval")
        let approval = try Self.map(approvalFinish["approval"], "\(vector.id).approval.approval")
        #expect(approval["credential_id"] == .bytes(Self.hexDecode(vector.input.approval.approval.credentialIdHex)))
        #expect(approval["authenticator_data"] == .bytes(Self.hexDecode(vector.input.approval.approval.authenticatorDataHex)))
        #expect(approval["client_data_json"] == .bytes(Self.hexDecode(vector.input.approval.approval.clientDataJsonHex)))
        #expect(approval["signature"] == .bytes(Self.hexDecode(vector.input.approval.approval.signatureHex)))
        #expect(approval["user_handle"] == .bytes(Self.hexDecode(vector.input.approval.approval.userHandleHex!)))
    }

    private static func finishRequest(_ input: FinishInput) -> OwnerWebauthnAddCredentialFinishRequest {
        OwnerWebauthnAddCredentialFinishRequest(
            version: UInt8(input.v),
            context: context(input.context),
            registration: registrationFinish(input.registration),
            approval: approvalFinish(input.approval)
        )
    }

    private static func registrationFinish(_ input: RegistrationFinishInput) -> OwnerWebauthnRegistrationFinishRequest {
        OwnerWebauthnRegistrationFinishRequest(
            version: UInt8(input.v),
            challengeID: input.challengeId,
            credential: OwnerWebauthnRegisterCredential(
                id: input.credential.id,
                rawId: input.credential.rawId,
                response: OwnerWebauthnAuthenticatorAttestationResponse(
                    attestationObject: input.credential.response.attestationObject,
                    clientDataJSON: input.credential.response.clientDataJSON,
                    transports: input.credential.response.transports
                ),
                type: input.credential.type
            )
        )
    }

    private static func approvalFinish(_ input: ApprovalFinishInput) -> OwnerApprovalV2Finish {
        OwnerApprovalV2Finish(
            version: UInt8(input.v),
            challengeID: input.challengeId,
            approval: approval(input.approval)
        )
    }

    private static func approval(_ input: ApprovalInput) -> OwnerApprovalV2 {
        OwnerApprovalV2(
            version: UInt8(input.v),
            context: context(input.context),
            credentialID: hexDecode(input.credentialIdHex),
            authenticatorData: hexDecode(input.authenticatorDataHex),
            clientDataJSON: hexDecode(input.clientDataJsonHex),
            signature: hexDecode(input.signatureHex),
            userHandle: input.userHandleHex.map(hexDecode)
        )
    }

    private static func context(_ input: ContextInput) -> OwnerApprovalContextV2 {
        OwnerApprovalContextV2(
            version: UInt8(input.v),
            purpose: input.purpose,
            op: OwnerApprovalOperation(rawValue: input.op)!,
            householdID: input.hhId,
            ownerPersonID: input.ownerPId,
            newCredentialBindingHash: hexDecode(input.newCredentialBindingHashHex),
            authorityHeadSequence: input.authorityHeadSequence,
            authorityHeadHash: hexDecode(input.authorityHeadHashHex),
            preActiveCredentialCount: input.preActiveCredentialCount,
            capabilities: input.capabilities,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            replayNonce: hexDecode(input.replayNonceHex)
        )
    }

    private static func map(_ value: HouseholdCBORValue?, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
    }

    private static func map(_ value: HouseholdCBORValue, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
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

private struct AssertionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
