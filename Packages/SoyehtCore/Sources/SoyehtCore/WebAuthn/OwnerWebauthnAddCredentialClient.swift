import Foundation

/// Headless HTTP adapter for AddCredential owner WebAuthn flow.
///
/// This client only performs the authenticated CBOR start/finish calls and maps
/// between the composite AddCredential wire DTOs and `PasskeyProvider`
/// inputs/outputs. It does not present platform UI, drive the two passkey
/// ceremonies, add application UI, or enable the owner-auth v2 rollout.
public struct OwnerWebauthnAddCredentialClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let startPath = "/api/v1/household/owner-webauthn/add-credential/start"
    static let finishPath = "/api/v1/household/owner-webauthn/add-credential/finish"

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

    /// Starts the dual AddCredential ceremony. The response contains two
    /// independent WebAuthn challenges bound to the same top-level context.
    public func start() async throws -> OwnerWebauthnAddCredentialStartResponse {
        let body = OwnerWebauthnAddCredentialStartRequest().canonicalBytes()
        let data = try await post(path: Self.startPath, body: body)
        return try OwnerWebauthnAddCredentialStartResponse(cbor: BootstrapWire.decodeCanonical(data))
    }

    /// Finishes AddCredential by submitting both the new registration attestation
    /// and the active-owner approval assertion in the server-provided wrapper.
    public func finish(
        request: OwnerWebauthnAddCredentialFinishRequest
    ) async throws -> OwnerWebauthnAddCredentialResult {
        let data = try await post(path: Self.finishPath, body: request.canonicalBytes())
        let response = try OwnerWebauthnAddCredentialFinishResponse(cbor: BootstrapWire.decodeCanonical(data))
        return OwnerWebauthnAddCredentialResult(
            credentialID: response.credentialID,
            activeCredentialCount: response.activeCredentialCount
        )
    }

    /// Maps the registration block of the AddCredential start response into the
    /// platform passkey registration request.
    public static func registrationRequest(
        from response: OwnerWebauthnAddCredentialStartResponse
    ) throws -> OwnerPasskeyRegistrationRequest {
        try OwnerPasskeyEnrollmentClient.registrationRequest(from: response.registration)
    }

    /// Maps the approval block of the AddCredential start response into the
    /// platform passkey assertion request. The challenge is opaque and forwarded
    /// byte-for-byte.
    public static func assertionRequest(
        from response: OwnerWebauthnAddCredentialStartResponse
    ) -> OwnerPasskeyAssertionRequest {
        OwnerPasskeyAssertionRequest(
            relyingPartyIdentifier: response.approval.relyingPartyIdentifier,
            challenge: response.approval.challenge,
            allowedCredentialIDs: response.approval.allowedCredentialIDs,
            userVerification: response.approval.userVerification
        )
    }

    /// Builds the nested registration finish block from the platform attestation.
    public static func registrationFinish(
        from response: OwnerWebauthnAddCredentialStartResponse,
        attestation: OwnerPasskeyAttestation
    ) -> OwnerWebauthnRegistrationFinishRequest {
        OwnerWebauthnRegistrationFinishRequest(
            version: OwnerWebauthnRegistrationStartRequest.currentVersion,
            challengeID: response.registration.challengeID,
            credential: OwnerPasskeyEnrollmentClient.credential(from: attestation)
        )
    }

    /// Builds the nested approval finish block from the active-owner assertion.
    ///
    /// The approval envelope echoes the top-level AddCredential context, not a
    /// client-derived context. The start decoder has already enforced that the
    /// nested start mirror matches this authoritative context.
    public static func approvalFinish(
        from response: OwnerWebauthnAddCredentialStartResponse,
        assertion: OwnerPasskeyAssertion
    ) -> OwnerApprovalV2Finish {
        let approval = OwnerApprovalV2(
            context: response.context,
            credentialID: assertion.credentialID,
            authenticatorData: assertion.authenticatorData,
            clientDataJSON: assertion.clientDataJSON,
            signature: assertion.signature,
            userHandle: assertion.userHandle
        )
        return OwnerApprovalV2Finish(
            challengeID: response.approval.challengeID,
            approval: approval
        )
    }

    /// Builds the composite AddCredential finish body from both platform
    /// ceremony outputs.
    public static func finishRequest(
        from response: OwnerWebauthnAddCredentialStartResponse,
        attestation: OwnerPasskeyAttestation,
        assertion: OwnerPasskeyAssertion
    ) -> OwnerWebauthnAddCredentialFinishRequest {
        OwnerWebauthnAddCredentialFinishRequest(
            context: response.context,
            registration: registrationFinish(from: response, attestation: attestation),
            approval: approvalFinish(from: response, assertion: assertion)
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
