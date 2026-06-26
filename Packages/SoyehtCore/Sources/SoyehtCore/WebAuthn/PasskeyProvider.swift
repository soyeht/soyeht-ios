#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation

// MARK: - Standard WebAuthn registration options

/// Standard WebAuthn registration options for an owner passkey.
///
/// Mirrors the spec `PublicKeyCredentialCreationOptions` fields the platform
/// authenticator needs. Deliberately carries **no** theyos backend schema
/// (endpoint name, request/response body, capability, canonical CBOR) - the
/// wire shape lives in a separate enrollment adapter so this type never churns
/// as the S3a backend stabilizes.
public struct OwnerPasskeyRegistrationRequest: Sendable, Equatable {
    /// Relying-party identifier (`rp.id`).
    public let relyingPartyIdentifier: String
    /// Raw challenge bytes (already base64url-decoded at the call edge).
    public let challenge: Data
    /// Opaque user handle (`user.id`), e.g. the owner person-id bytes.
    public let userID: Data
    /// Account name (`user.name`) shown in the system sheet.
    public let userName: String
    /// Human-facing display name (`user.displayName`).
    ///
    /// Reserved: the iOS 16 / macOS 13 `createCredentialRegistrationRequest`
    /// API takes only `challenge`/`name`/`userID`, so this is not consumed by
    /// the ceremony itself - it is carried for the relying party / UX layer.
    public let userDisplayName: String

    public init(
        relyingPartyIdentifier: String,
        challenge: Data,
        userID: Data,
        userName: String,
        userDisplayName: String
    ) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.challenge = challenge
        self.userID = userID
        self.userName = userName
        self.userDisplayName = userDisplayName
    }
}

// MARK: - Raw attestation output

/// Raw output of a successful platform passkey registration ceremony.
///
/// Mirrors the spec `RegisterPublicKeyCredential` response as raw bytes. Wire
/// encoding (base64url / JSON / CBOR) and transport to the engine are the
/// enrollment adapter's job, kept out of this type on purpose.
public struct OwnerPasskeyAttestation: Sendable, Equatable {
    /// `rawId` - the newly created credential's id.
    public let credentialID: Data
    /// `response.attestationObject` (CBOR per WebAuthn).
    public let attestationObject: Data
    /// `response.clientDataJSON`.
    public let clientDataJSON: Data

    public init(credentialID: Data, attestationObject: Data, clientDataJSON: Data) {
        self.credentialID = credentialID
        self.attestationObject = attestationObject
        self.clientDataJSON = clientDataJSON
    }
}

// MARK: - Standard WebAuthn assertion options

/// Standard WebAuthn assertion (get) options for an owner approval.
///
/// Mirrors the spec `PublicKeyCredentialRequestOptions` fields the platform
/// authenticator needs for an assertion. Like the registration request, it
/// carries no theyos wire schema — the approval-v2 adapter builds the envelope.
public struct OwnerPasskeyAssertionRequest: Sendable, Equatable {
    /// Relying-party identifier (`rp.id`).
    public let relyingPartyIdentifier: String
    /// Raw challenge bytes. OPAQUE: the approval orchestrator passes the
    /// `OwnerApprovalContextV2.challengeDigest()`; forwarded to the platform
    /// unchanged and never re-encoded here.
    public let challenge: Data
    /// Allowed credential ids (`allowCredentials[].id`). Empty = no restriction.
    public let allowedCredentialIDs: [Data]
    /// User-verification preference (`userVerification`), raw spec string
    /// (`"required"` / `"preferred"` / `"discouraged"`). `nil` = platform default.
    public let userVerification: String?

    public init(
        relyingPartyIdentifier: String,
        challenge: Data,
        allowedCredentialIDs: [Data] = [],
        userVerification: String? = nil
    ) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.challenge = challenge
        self.allowedCredentialIDs = allowedCredentialIDs
        self.userVerification = userVerification
    }
}

// MARK: - Raw assertion output

/// Raw output of a successful platform passkey assertion ceremony.
///
/// Mirrors the spec `AuthenticatorAssertionResponse` as raw bytes. Wire encoding
/// and the approval-v2 envelope are the adapter's job, kept out of this type.
public struct OwnerPasskeyAssertion: Sendable, Equatable {
    /// `rawId` — the asserting credential's id.
    public let credentialID: Data
    /// `response.authenticatorData`.
    public let authenticatorData: Data
    /// `response.clientDataJSON`.
    public let clientDataJSON: Data
    /// `response.signature`.
    public let signature: Data
    /// `response.userHandle`, if the authenticator returned one.
    public let userHandle: Data?

    public init(
        credentialID: Data,
        authenticatorData: Data,
        clientDataJSON: Data,
        signature: Data,
        userHandle: Data? = nil
    ) {
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
        self.userHandle = userHandle
    }
}

// MARK: - Presentation anchor injection

/// Supplies the window the system passkey sheet anchors to.
///
/// Implemented by the app layer (returning a `UIWindow` / `NSWindow`) so
/// `SoyehtCore` stays free of any app target. The provider only depends on the
/// `ASPresentationAnchor` typealias from `AuthenticationServices`.
@MainActor
public protocol PasskeyPresentationAnchorProviding: AnyObject {
    func passkeyPresentationAnchor() -> ASPresentationAnchor
}

// MARK: - Errors

/// Errors surfaced by ``PasskeyProvider``.
public enum OwnerPasskeyRegistrationError: Error, Sendable, Equatable {
    /// The user dismissed the system passkey sheet.
    case canceled
    /// The request was not handled by the platform.
    case notHandled
    /// The authenticator returned a malformed or empty response.
    case invalidResponse
    /// The authorization returned a credential of an unexpected type.
    case unexpectedCredentialType
    /// A ceremony (registration or assertion) is already running on this instance.
    case alreadyInProgress
    /// The platform reported a failure.
    case failed(String)
    /// Any other / unrecognized error.
    case unknown(String)
}

// MARK: - Provider

/// Thin, app-target-free wrapper around the `AuthenticationServices` platform
/// passkey **registration** (creation) and **assertion** (get) ceremonies.
///
/// Pure WebAuthn: standard options in, raw attestation / assertion out. It
/// performs **no** network I/O and references no theyos endpoint/body, so it
/// does not depend on the backend and will not churn as that backend stabilizes.
///
/// Intended to be short-lived (one instance per ceremony). The caller must keep
/// the instance alive for the duration of ``register(_:)`` / ``authenticate(_:)``
/// - the system holds the controller's delegate weakly. A single ceremony runs
/// at a time: a second concurrent call (in either direction) throws
/// ``OwnerPasskeyRegistrationError/alreadyInProgress``.
@MainActor
public final class PasskeyProvider: NSObject {
    private let anchorProvider: PasskeyPresentationAnchorProviding
    /// Starts the platform request. Defaults to `performRequests()`; injectable so
    /// unit tests can hold the ceremony in flight (no UI / no real anchor) and
    /// exercise Task cancellation. Production callers use the default.
    private let performStart: @MainActor (ASAuthorizationController) -> Void
    /// The single in-flight ceremony's resolver. Type-erased over the result type
    /// (`OwnerPasskeyAttestation` for register, `OwnerPasskeyAssertion` for
    /// authenticate): the per-call closure maps the raw `ASAuthorization` and
    /// resumes its own typed continuation. `nil` ⇔ no ceremony in flight, which is
    /// also the `.alreadyInProgress` gate (covers both directions).
    private var activeCompletion: ((Result<ASAuthorization, Error>) -> Void)?
    private var activeController: ASAuthorizationController?

    /// Production initializer. Public surface is unchanged from the inert provider
    /// — no test knobs are exposed.
    public convenience init(anchorProvider: PasskeyPresentationAnchorProviding) {
        self.init(anchorProvider: anchorProvider, performStart: { $0.performRequests() })
    }

    /// Designated initializer. `performStart` is the injection seam used by tests
    /// (via `@testable import`) to hold the ceremony in flight without UI; it is
    /// intentionally `internal`, not part of the public API.
    init(
        anchorProvider: PasskeyPresentationAnchorProviding,
        performStart: @escaping @MainActor (ASAuthorizationController) -> Void
    ) {
        self.anchorProvider = anchorProvider
        self.performStart = performStart
        super.init()
    }

    /// Runs the platform passkey **creation** ceremony and returns the raw
    /// attestation. Presents the system sheet anchored to the injected window.
    ///
    /// - Throws: ``OwnerPasskeyRegistrationError`` on cancellation/failure, or
    ///   ``OwnerPasskeyRegistrationError/alreadyInProgress`` if a ceremony is
    ///   already running on this instance.
    public func register(
        _ request: OwnerPasskeyRegistrationRequest
    ) async throws -> OwnerPasskeyAttestation {
        try await runCeremony(request: Self.makeRegistrationRequest(request)) { authorization in
            guard
                let registration = authorization.credential
                    as? ASAuthorizationPlatformPublicKeyCredentialRegistration
            else {
                return .failure(.unexpectedCredentialType)
            }
            guard let attestationObject = registration.rawAttestationObject else {
                return .failure(.invalidResponse)
            }
            return .success(OwnerPasskeyAttestation(
                credentialID: registration.credentialID,
                attestationObject: attestationObject,
                clientDataJSON: registration.rawClientDataJSON
            ))
        }
    }

    /// Runs the platform passkey **assertion** ceremony and returns the raw
    /// assertion (the signature over the server-issued challenge). The challenge
    /// is forwarded opaquely; this type never interprets or re-encodes it.
    ///
    /// - Throws: ``OwnerPasskeyRegistrationError`` on cancellation/failure, or
    ///   ``OwnerPasskeyRegistrationError/alreadyInProgress`` if a ceremony is
    ///   already running on this instance.
    public func authenticate(
        _ request: OwnerPasskeyAssertionRequest
    ) async throws -> OwnerPasskeyAssertion {
        try await runCeremony(request: Self.makeAssertionRequest(request)) { authorization in
            guard
                let assertion = authorization.credential
                    as? ASAuthorizationPlatformPublicKeyCredentialAssertion
            else {
                return .failure(.unexpectedCredentialType)
            }
            guard
                let authenticatorData = assertion.rawAuthenticatorData,
                let signature = assertion.signature
            else {
                return .failure(.invalidResponse)
            }
            return .success(OwnerPasskeyAssertion(
                credentialID: assertion.credentialID,
                authenticatorData: authenticatorData,
                clientDataJSON: assertion.rawClientDataJSON,
                signature: signature,
                userHandle: assertion.userID
            ))
        }
    }

    /// Shared ceremony runner for both register and authenticate. Installs the
    /// single in-flight resolver, wires Task cancellation to cancel the platform
    /// controller (resolving with `.canceled`), and maps the raw authorization to
    /// the typed result via `extract`.
    ///
    /// One state machine, one cancel path: continuation installed → if the Task is
    /// already cancelled, resolve `.canceled` and never start → otherwise
    /// `performStart` → on Task cancel, hop to the main actor and cancel the
    /// controller. `finish` is resume-once.
    private func runCeremony<T: Sendable>(
        request: ASAuthorizationRequest,
        extract: @escaping (ASAuthorization) -> Result<T, OwnerPasskeyRegistrationError>
    ) async throws -> T {
        guard activeCompletion == nil else {
            throw OwnerPasskeyRegistrationError.alreadyInProgress
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        activeController = controller
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                activeCompletion = { result in
                    switch result {
                    case .success(let authorization):
                        continuation.resume(with: extract(authorization).mapError { $0 as Error })
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                // Close the cancel-before-start race: if the Task was already
                // cancelled (or cancelled while the continuation was being
                // installed), `onCancel` may have run as a no-op. Resolve here and
                // never start the ceremony (no system sheet for a dead request).
                if Task.isCancelled {
                    cancelActiveCeremony()
                    return
                }
                performStart(controller)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveCeremony()
            }
        }
    }

    /// Builds the platform registration request from standard WebAuthn options.
    ///
    /// Exposed `internal` for unit tests of field propagation without running a
    /// ceremony.
    nonisolated static func makeRegistrationRequest(
        _ request: OwnerPasskeyRegistrationRequest
    ) -> ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: request.relyingPartyIdentifier
        )
        return provider.createCredentialRegistrationRequest(
            challenge: request.challenge,
            name: request.userName,
            userID: request.userID
        )
    }

    /// Builds the platform assertion request from standard WebAuthn options.
    ///
    /// Exposed `internal` for unit tests of field propagation without running a
    /// ceremony.
    nonisolated static func makeAssertionRequest(
        _ request: OwnerPasskeyAssertionRequest
    ) -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: request.relyingPartyIdentifier
        )
        let assertionRequest = provider.createCredentialAssertionRequest(
            challenge: request.challenge
        )
        if !request.allowedCredentialIDs.isEmpty {
            assertionRequest.allowedCredentials = request.allowedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        if let userVerification = request.userVerification {
            assertionRequest.userVerificationPreference =
                ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: userVerification)
        }
        return assertionRequest
    }

    /// Maps an `AuthenticationServices` error into ``OwnerPasskeyRegistrationError``.
    ///
    /// Exposed `internal` for unit tests.
    nonisolated static func map(_ error: Error) -> OwnerPasskeyRegistrationError {
        guard let asError = error as? ASAuthorizationError else {
            return .unknown(error.localizedDescription)
        }
        switch asError.code {
        case .canceled: return .canceled
        case .notHandled: return .notHandled
        case .invalidResponse: return .invalidResponse
        case .failed: return .failed(asError.localizedDescription)
        default: return .unknown(asError.localizedDescription)
        }
    }

    /// Cancels an in-flight ceremony: cancels the platform controller and
    /// resolves the awaiting call with ``OwnerPasskeyRegistrationError/canceled``,
    /// clearing state so a subsequent ceremony is allowed. No-op when nothing is
    /// in flight (`finish` is resume-once).
    private func cancelActiveCeremony() {
        guard activeCompletion != nil else { return }
        activeController?.cancel()
        finish(.failure(OwnerPasskeyRegistrationError.canceled))
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let completion = activeCompletion
        activeCompletion = nil
        activeController = nil
        completion?(result)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyProvider: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(Self.map(error)))
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension PasskeyProvider: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        anchorProvider.passkeyPresentationAnchor()
    }
}
#endif
