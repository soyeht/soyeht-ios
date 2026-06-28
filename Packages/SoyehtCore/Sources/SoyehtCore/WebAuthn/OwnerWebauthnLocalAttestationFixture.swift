import Foundation

public enum OwnerWebauthnLocalAttestationFixtureError: Error, Sendable, Equatable {
    case missingClientDataOrigin
}

/// Local, untracked fixture consumed by the theyos A3 manual evidence harness.
///
/// This type intentionally models only the JSON shape the Rust harness reads.
/// It may contain live attestation material and must only be written to an
/// explicitly supplied local path, never logged or checked in.
public struct OwnerWebauthnLocalAppleAttestationFixture: Encodable, Equatable, Sendable {
    public let rpID: String
    public let origin: String
    public let credential: Credential

    enum CodingKeys: String, CodingKey {
        case rpID = "rp_id"
        case origin
        case credential
    }

    public init(rpID: String, origin: String, credential: Credential) {
        self.rpID = rpID
        self.origin = origin
        self.credential = credential
    }

    public init(
        rpID: String,
        attestation: OwnerPasskeyAttestation
    ) throws {
        let clientData = try ClientDataJSON(originData: attestation.clientDataJSON)
        guard let origin = clientData.origin, !origin.isEmpty else {
            throw OwnerWebauthnLocalAttestationFixtureError.missingClientDataOrigin
        }
        self.init(
            rpID: rpID,
            origin: origin,
            credential: Credential(attestation: attestation)
        )
    }

    public func write(to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    public struct Credential: Encodable, Equatable, Sendable {
        public let id: String
        public let rawID: String
        public let response: Response
        public let type: String

        enum CodingKeys: String, CodingKey {
            case id
            case rawID = "rawId"
            case response
            case type
        }

        public init(id: String, rawID: String, response: Response, type: String = "public-key") {
            self.id = id
            self.rawID = rawID
            self.response = response
            self.type = type
        }

        init(attestation: OwnerPasskeyAttestation) {
            let encodedID = PairingCrypto.base64URLEncode(attestation.credentialID)
            self.init(
                id: encodedID,
                rawID: encodedID,
                response: Response(attestation: attestation)
            )
        }
    }

    public struct Response: Encodable, Equatable, Sendable {
        public let attestationObject: String
        public let clientDataJSON: String

        public init(attestationObject: String, clientDataJSON: String) {
            self.attestationObject = attestationObject
            self.clientDataJSON = clientDataJSON
        }

        init(attestation: OwnerPasskeyAttestation) {
            self.init(
                attestationObject: PairingCrypto.base64URLEncode(attestation.attestationObject),
                clientDataJSON: PairingCrypto.base64URLEncode(attestation.clientDataJSON)
            )
        }
    }

    private struct ClientDataJSON: Decodable {
        let origin: String?

        init(originData: Data) throws {
            self = try JSONDecoder().decode(Self.self, from: originData)
        }
    }
}
