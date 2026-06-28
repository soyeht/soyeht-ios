import Foundation
import Testing

@testable import SoyehtCore

/// Swift structural guard for owner WebAuthn registration wire vectors.
///
/// The Rust half lives in theyos
/// `server-rs/tests/data/owner_webauthn_registration_vectors.json`.
/// Full DTO encode/decode parity lands with the S3b adapter; this guard pins the
/// traps that would make the adapter's canonical CBOR fail the server's
/// decode->re-encode byte-equality check.
@Suite struct OwnerWebauthnRegistrationCrossLanguageVectorTests {
    struct Vectors: Decodable {
        let contract: String
        let version: Int
        let startResponses: [VectorCase]
        let finishRequests: [VectorCase]
    }

    struct VectorCase: Decodable {
        let id: String
        let input: JSONValue
        let canonicalCborHex: String
    }

    enum JSONValue: Decodable, Equatable {
        case string(String)
        case number(Int64)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }
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

    @Test func startResponseVectorsDecodeAsCanonicalCBOR() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.contract == "soyeht-owner-webauthn-registration-cbor-cross-language")
        #expect(vectors.version == 1)
        #expect(vectors.startResponses.count == 4)

        for vector in vectors.startResponses {
            let cbor = try Self.decodePinnedCBOR(vector)
            let input = try Self.object(vector.input, "\(vector.id).input")
            try Self.assertCanonicalRoundTrip(cbor, expectedHex: vector.canonicalCborHex)
            #expect(cbor == Self.cborValue(from: .object(input)), "\(vector.id): fixture input must match pinned CBOR")

            let top = try Self.map(cbor, "\(vector.id).top")
            #expect(try Self.unsigned(top["v"], "\(vector.id).v") == 1)
            #expect(try Self.text(top["challenge_id"], "\(vector.id).challenge_id").count == 32)

            let options = try Self.map(top["options"], "\(vector.id).options")
            let publicKey = try Self.map(options["publicKey"], "\(vector.id).publicKey")
            #expect(options["public_key"] == nil, "\(vector.id): webauthn key must be publicKey, not public_key")

            let rp = try Self.map(publicKey["rp"], "\(vector.id).rp")
            #expect(try Self.text(rp["id"], "\(vector.id).rp.id") == "household.example.test")

            let user = try Self.map(publicKey["user"], "\(vector.id).user")
            _ = try Self.base64UrlText(user["id"], "\(vector.id).user.id")
            _ = try Self.base64UrlText(publicKey["challenge"], "\(vector.id).challenge")

            let params = try Self.array(publicKey["pubKeyCredParams"], "\(vector.id).pubKeyCredParams")
            #expect(try Self.negative(try Self.map(params[0], "\(vector.id).param0")["alg"], "\(vector.id).alg") == -7)

            if vector.id == "start-realistic-passkey" {
                let exclude = try Self.array(publicKey["excludeCredentials"], "\(vector.id).excludeCredentials")
                #expect(exclude.isEmpty)
            }
            if vector.id == "start-macos-local-attested-options" {
                #expect(try Self.text(publicKey["attestation"], "\(vector.id).attestation") == "direct")

                let formats = try Self.array(publicKey["attestationFormats"], "\(vector.id).attestationFormats")
                #expect(formats == [.text("apple")])

                let hints = try Self.array(publicKey["hints"], "\(vector.id).hints")
                #expect(hints == [.text("client-device")])

                let selection = try Self.map(
                    publicKey["authenticatorSelection"],
                    "\(vector.id).authenticatorSelection"
                )
                #expect(
                    try Self.text(
                        selection["authenticatorAttachment"],
                        "\(vector.id).authenticatorSelection.authenticatorAttachment"
                    ) == "platform"
                )
                #expect(
                    try Self.text(
                        selection["residentKey"],
                        "\(vector.id).authenticatorSelection.residentKey"
                    ) == "required"
                )
                #expect(
                    try Self.text(
                        selection["userVerification"],
                        "\(vector.id).authenticatorSelection.userVerification"
                    ) == "required"
                )
                #expect(
                    try Self.bool(
                        selection["requireResidentKey"],
                        "\(vector.id).authenticatorSelection.requireResidentKey"
                    )
                )

                let extensions = try Self.map(publicKey["extensions"], "\(vector.id).extensions")
                #expect(
                    try Self.text(
                        extensions["credentialProtectionPolicy"],
                        "\(vector.id).extensions.credentialProtectionPolicy"
                    ) == "userVerificationRequired"
                )
                #expect(
                    try Self.bool(
                        extensions["enforceCredentialProtectionPolicy"],
                        "\(vector.id).extensions.enforceCredentialProtectionPolicy"
                    )
                )
            }
        }
    }

    @Test func finishRequestVectorsDecodeAsCanonicalCBOR() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.finishRequests.count == 3)

        for vector in vectors.finishRequests {
            let cbor = try Self.decodePinnedCBOR(vector)
            let input = try Self.object(vector.input, "\(vector.id).input")
            try Self.assertCanonicalRoundTrip(cbor, expectedHex: vector.canonicalCborHex)
            #expect(cbor == Self.cborValue(from: .object(input)), "\(vector.id): fixture input must match pinned CBOR")

            let top = try Self.map(cbor, "\(vector.id).top")
            #expect(try Self.unsigned(top["v"], "\(vector.id).v") == 1)

            let credential = try Self.map(top["credential"], "\(vector.id).credential")
            let id = try Self.base64UrlText(credential["id"], "\(vector.id).credential.id")
            let rawId = try Self.base64UrlText(credential["rawId"], "\(vector.id).credential.rawId")
            #expect(id == rawId, "\(vector.id): credential.id must be base64url(rawId)")
            #expect(try Self.text(credential["type"], "\(vector.id).credential.type") == "public-key")

            let response = try Self.map(credential["response"], "\(vector.id).credential.response")
            _ = try Self.base64UrlText(response["attestationObject"], "\(vector.id).attestationObject")
            _ = try Self.base64UrlText(response["clientDataJSON"], "\(vector.id).clientDataJSON")
            #expect(response.keys.contains("transports"), "\(vector.id): transports must be present")

            let extensions = try Self.map(credential["extensions"], "\(vector.id).extensions")
            #expect(extensions.isEmpty, "\(vector.id): default extensions must encode as {}")

            if vector.id == "finish-minimal-null-transports-empty-extensions" {
                #expect(response["transports"] == .null, "\(vector.id): nil transports must encode as null")
            }
            if vector.id == "finish-with-transports" {
                let transports = try Self.array(response["transports"], "\(vector.id).transports")
                #expect(transports == [.text("internal"), .text("hybrid")])
            }
        }
    }

    private static func decodePinnedCBOR(_ vector: VectorCase) throws -> HouseholdCBORValue {
        let data = try #require(Data(soyehtHex: vector.canonicalCborHex))
        return try HouseholdCBOR.decode(data)
    }

    private static func assertCanonicalRoundTrip(
        _ value: HouseholdCBORValue,
        expectedHex: String
    ) throws {
        #expect(HouseholdCBOR.encode(value).soyehtHexEncodedString() == expectedHex)
    }

    private static func cborValue(from value: JSONValue) -> HouseholdCBORValue {
        switch value {
        case .string(let string): .text(string)
        case .number(let number):
            number >= 0 ? .unsigned(UInt64(number)) : .negative(number)
        case .bool(let bool): .bool(bool)
        case .null: .null
        case .array(let values): .array(values.map(cborValue))
        case .object(let object):
            .map(object.mapValues(cborValue))
        }
    }

    private static func object(_ value: JSONValue, _ label: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else {
            throw AssertionError("\(label) is not an object")
        }
        return object
    }

    private static func map(_ value: HouseholdCBORValue?, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
    }

    private static func array(_ value: HouseholdCBORValue?, _ label: String) throws -> [HouseholdCBORValue] {
        guard case .array(let array) = value else {
            throw AssertionError("\(label) is not an array")
        }
        return array
    }

    private static func text(_ value: HouseholdCBORValue?, _ label: String) throws -> String {
        guard case .text(let text) = value else {
            throw AssertionError("\(label) is not text")
        }
        return text
    }

    private static func unsigned(_ value: HouseholdCBORValue?, _ label: String) throws -> UInt64 {
        guard case .unsigned(let unsigned) = value else {
            throw AssertionError("\(label) is not unsigned")
        }
        return unsigned
    }

    private static func negative(_ value: HouseholdCBORValue?, _ label: String) throws -> Int64 {
        guard case .negative(let negative) = value else {
            throw AssertionError("\(label) is not negative")
        }
        return negative
    }

    private static func bool(_ value: HouseholdCBORValue?, _ label: String) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw AssertionError("\(label) is not bool")
        }
        return bool
    }

    private static func base64UrlText(_ value: HouseholdCBORValue?, _ label: String) throws -> String {
        let text = try text(value, label)
        #expect(!text.contains("="), "\(label) must use unpadded base64url")
        #expect(text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
        return text
    }
}

private struct AssertionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
