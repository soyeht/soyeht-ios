import Foundation

/// Result returned by the owner passkey first-enrollment finish endpoint.
public struct OwnerPasskeyEnrollmentResult: Equatable, Sendable {
    public let credentialID: Data
    public let activeCredentialCount: UInt64

    public init(credentialID: Data, activeCredentialCount: UInt64) {
        self.credentialID = credentialID
        self.activeCredentialCount = activeCredentialCount
    }
}

/// Headless HTTP adapter for owner passkey first enrollment.
///
/// This client only performs the authenticated CBOR start/finish calls and
/// maps between the wire DTOs and `PasskeyProvider` inputs/outputs. It does not
/// present platform UI, call `PasskeyProvider.register(_:)`, expose backup
/// enrollment, or enable owner-approval enforcement.
public struct OwnerPasskeyEnrollmentClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let startPath = "/api/v1/household/owner-webauthn/registration/start"
    static let finishPath = "/api/v1/household/owner-webauthn/registration/finish"

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = { req in
            try await BootstrapInitializeClient.defaultSession.data(for: req)
        }
    ) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = transport
    }

    /// Starts first passkey enrollment and returns server-generated WebAuthn
    /// creation options. The returned challenge is opaque and must be passed to
    /// the platform authenticator unchanged.
    public func start() async throws -> OwnerWebauthnRegistrationStartResponse {
        let body = OwnerWebauthnRegistrationStartRequest().canonicalBytes()
        let data = try await post(path: Self.startPath, body: body)
        return try OwnerWebauthnRegistrationStartResponse(cbor: BootstrapWire.decodeCanonical(data))
    }

    /// Finishes first passkey enrollment with the platform attestation.
    public func finish(
        challengeID: String,
        credential: OwnerWebauthnRegisterCredential
    ) async throws -> OwnerPasskeyEnrollmentResult {
        let request = OwnerWebauthnRegistrationFinishRequest(
            version: OwnerWebauthnRegistrationStartRequest.currentVersion,
            challengeID: challengeID,
            credential: credential
        )
        let data = try await post(path: Self.finishPath, body: request.canonicalBytes())
        let response = try OwnerWebauthnRegistrationFinishResponse(cbor: BootstrapWire.decodeCanonical(data))
        return OwnerPasskeyEnrollmentResult(
            credentialID: response.credentialID,
            activeCredentialCount: response.activeCredentialCount
        )
    }

    /// Maps the server start response into the platform passkey registration
    /// request. Fails closed if a base64url field is malformed.
    public static func registrationRequest(
        from response: OwnerWebauthnRegistrationStartResponse
    ) throws -> OwnerPasskeyRegistrationRequest {
        let publicKey = response.options.publicKey
        guard let challenge = publicKey.challengeData else {
            throw OwnerWebauthnRegistrationDTOError.malformedCBOR("publicKey.challenge: invalid base64url")
        }
        guard let userID = publicKey.user.idData else {
            throw OwnerWebauthnRegistrationDTOError.malformedCBOR("user.id: invalid base64url")
        }
        return OwnerPasskeyRegistrationRequest(
            relyingPartyIdentifier: publicKey.rp.id,
            challenge: challenge,
            userID: userID,
            userName: publicKey.user.name,
            userDisplayName: publicKey.user.displayName
        )
    }

    /// Maps platform attestation bytes into the canonical WebAuthn finish DTO.
    public static func credential(
        from attestation: OwnerPasskeyAttestation,
        transports: [String]? = nil
    ) -> OwnerWebauthnRegisterCredential {
        OwnerWebauthnRegisterCredential(
            credentialID: attestation.credentialID,
            attestationObject: attestation.attestationObject,
            clientDataJSON: attestation.clientDataJSON,
            transports: transports
        )
    }

    private func post(path: String, body: Data) async throws -> Data {
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: path)
        let authorization = try popSigner
            .authorization(method: "POST", pathAndQuery: pathAndQuery, body: body)
            .authorizationHeader
        return try await BootstrapWire.send(
            method: "POST",
            url: url,
            body: body,
            authorization: authorization,
            perform: perform
        )
    }
}
