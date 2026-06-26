import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerWebauthnRegistrationDTOParityTests {
    struct Vectors: Decodable {
        let startResponses: [StartVector]
        let finishRequests: [FinishVector]
    }

    struct StartVector: Decodable {
        let id: String
        let input: StartInput
        let canonicalCborHex: String
    }

    struct FinishVector: Decodable {
        let id: String
        let input: FinishInput
        let canonicalCborHex: String
    }

    struct StartInput: Decodable {
        let v: UInt8
        let challengeId: String
        let options: CreationChallengeResponseInput
    }

    struct CreationChallengeResponseInput: Decodable {
        let publicKey: PublicKeyCredentialCreationOptionsInput
    }

    struct PublicKeyCredentialCreationOptionsInput: Decodable {
        let rp: RelyingPartyInput
        let user: UserInput
        let challenge: String
        let pubKeyCredParams: [PubKeyCredParamInput]
        let excludeCredentials: [PublicKeyCredentialDescriptorInput]?
    }

    struct RelyingPartyInput: Decodable {
        let id: String
        let name: String
    }

    struct UserInput: Decodable {
        let id: String
        let name: String
        let displayName: String
    }

    struct PubKeyCredParamInput: Decodable, Equatable {
        let type: String
        let alg: Int64
    }

    struct PublicKeyCredentialDescriptorInput: Decodable, Equatable {
        let id: String
        let type: String
        let transports: [String]?
    }

    struct FinishInput: Decodable {
        let v: UInt8
        let challengeId: String
        let credential: RegisterPublicKeyCredentialInput
    }

    struct RegisterPublicKeyCredentialInput: Decodable {
        let id: String
        let rawId: String
        let response: AuthenticatorAttestationResponseInput
        let type: String
        let extensions: RegistrationExtensionsClientOutputsInput
    }

    struct AuthenticatorAttestationResponseInput: Decodable {
        let attestationObject: String
        let clientDataJSON: String
        let transports: [String]?
    }

    struct RegistrationExtensionsClientOutputsInput: Decodable {
        let appid: Bool?
        let credProps: CredentialPropertiesOutputInput?
        let hmacSecret: Bool?
        let credProtect: String?
        let minPinLength: UInt32?
    }

    struct CredentialPropertiesOutputInput: Decodable {
        let rk: Bool?
    }

    enum FixtureError: Error { case missingFixture }

    static func loadVectors() throws -> Vectors {
        guard let url = Bundle.module.url(
            forResource: "owner_webauthn_registration_vectors",
            withExtension: "json"
        ) else {
            throw FixtureError.missingFixture
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: try Data(contentsOf: url))
    }

    @Test func startResponseDTOsDecodeRustVectors() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.startResponses.count == 3)

        for vector in vectors.startResponses {
            let cbor = try #require(Data(soyehtHex: vector.canonicalCborHex))
            let decoded = try HouseholdCBOR.decode(cbor)
            #expect(HouseholdCBOR.encode(decoded) == cbor)
            let response = try OwnerWebauthnRegistrationStartResponse(cbor: decoded)
            let expected = vector.input
            let publicKey = response.options.publicKey

            #expect(response.version == expected.v, "\(vector.id): version drifted")
            #expect(response.challengeID == expected.challengeId, "\(vector.id): challenge_id drifted")
            #expect(publicKey.rp == OwnerWebauthnRelyingParty(
                id: expected.options.publicKey.rp.id,
                name: expected.options.publicKey.rp.name
            ))
            #expect(publicKey.user == OwnerWebauthnUserEntity(
                id: expected.options.publicKey.user.id,
                name: expected.options.publicKey.user.name,
                displayName: expected.options.publicKey.user.displayName
            ))
            #expect(publicKey.challenge == expected.options.publicKey.challenge)
            #expect(try Self.base64RoundTrip(publicKey.challenge) == publicKey.challenge)
            #expect(try Self.base64RoundTrip(publicKey.user.id) == publicKey.user.id)
        }
    }

    @Test func finishRequestDTOsEncodeCanonicalRustVectors() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.finishRequests.count == 3)

        for vector in vectors.finishRequests {
            let request = try Self.finishRequest(from: vector.input)
            let encoded = request.canonicalBytes()
            #expect(
                encoded.soyehtHexEncodedString() == vector.canonicalCborHex,
                "\(vector.id): Swift typed DTO canonical CBOR drifted from Rust"
            )

            let top = try Self.map(HouseholdCBOR.decode(encoded), "\(vector.id).top")
            let credential = try Self.map(top["credential"], "\(vector.id).credential")
            let response = try Self.map(credential["response"], "\(vector.id).response")
            #expect(response.keys.contains("transports"), "\(vector.id): transports must be present")
            #expect(credential["extensions"] == .map([:]), "\(vector.id): default extensions must encode as {}")

            if vector.id.contains("null-transports") || vector.id.contains("zero-bytes") {
                #expect(response["transports"] == .null, "\(vector.id): nil transports must encode as null")
            }
            if vector.id == "finish-with-transports" {
                #expect(response["transports"] == .array([.text("internal"), .text("hybrid")]))
            }
        }
    }

    private static func finishRequest(from input: FinishInput) throws -> OwnerWebauthnRegistrationFinishRequest {
        let credential = OwnerWebauthnRegisterCredential(
            id: input.credential.id,
            rawId: input.credential.rawId,
            response: OwnerWebauthnAuthenticatorAttestationResponse(
                attestationObject: input.credential.response.attestationObject,
                clientDataJSON: input.credential.response.clientDataJSON,
                transports: input.credential.response.transports
            ),
            type: input.credential.type,
            extensions: OwnerWebauthnRegistrationClientExtensionOutputs(
                appid: input.credential.extensions.appid,
                credProps: input.credential.extensions.credProps.map {
                    OwnerWebauthnCredProps(rk: $0.rk)
                },
                hmacSecret: input.credential.extensions.hmacSecret,
                credProtect: input.credential.extensions.credProtect,
                minPinLength: input.credential.extensions.minPinLength
            )
        )

        let rawId = try #require(PairingCrypto.base64URLDecode(input.credential.rawId))
        let attestationObject = try #require(PairingCrypto.base64URLDecode(input.credential.response.attestationObject))
        let clientDataJSON = try #require(PairingCrypto.base64URLDecode(input.credential.response.clientDataJSON))
        let convenience = OwnerWebauthnRegisterCredential(
            credentialID: rawId,
            attestationObject: attestationObject,
            clientDataJSON: clientDataJSON,
            transports: input.credential.response.transports
        )
        #expect(convenience == credential)

        return OwnerWebauthnRegistrationFinishRequest(
            version: input.v,
            challengeID: input.challengeId,
            credential: credential
        )
    }

    private static func base64RoundTrip(_ value: String) throws -> String {
        PairingCrypto.base64URLEncode(try #require(PairingCrypto.base64URLDecode(value)))
    }

    private static func map(_ value: HouseholdCBORValue, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
    }

    private static func map(_ value: HouseholdCBORValue?, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
    }
}

private struct AssertionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
