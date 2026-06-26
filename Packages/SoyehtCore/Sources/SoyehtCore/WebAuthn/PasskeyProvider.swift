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
    /// The authorization returned a credential that was not a platform passkey registration.
    case unexpectedCredentialType
    /// A registration is already running on this provider instance.
    case alreadyInProgress
    /// The platform reported a failure.
    case failed(String)
    /// Any other / unrecognized error.
    case unknown(String)
}

// MARK: - Provider

/// Thin, app-target-free wrapper around the `AuthenticationServices` platform
/// passkey **registration** (creation) ceremony.
///
/// Pure WebAuthn: standard options in, raw attestation out. It performs **no**
/// network I/O and references no theyos endpoint/body, so it does not depend on
/// the S3a backend and will not churn as that backend stabilizes.
///
/// Intended to be short-lived (one instance per ceremony). The caller must keep
/// the instance alive for the duration of ``register(_:)`` - the system holds
/// the controller's delegate weakly.
@MainActor
public final class PasskeyProvider: NSObject {
    private let anchorProvider: PasskeyPresentationAnchorProviding
    /// Starts the platform request. Defaults to `performRequests()`; injectable so
    /// unit tests can hold the ceremony in flight (no UI / no real anchor) and
    /// exercise Task cancellation. Production callers use the default.
    private let performStart: @MainActor (ASAuthorizationController) -> Void
    private var activeContinuation: CheckedContinuation<OwnerPasskeyAttestation, Error>?
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

    /// Runs the platform passkey creation ceremony for `request` and returns the
    /// raw attestation. Presents the system sheet anchored to the injected window.
    ///
    /// - Throws: ``OwnerPasskeyRegistrationError`` on cancellation/failure, or
    ///   ``OwnerPasskeyRegistrationError/alreadyInProgress`` if a ceremony is
    ///   already running on this instance.
    public func register(
        _ request: OwnerPasskeyRegistrationRequest
    ) async throws -> OwnerPasskeyAttestation {
        guard activeContinuation == nil else {
            throw OwnerPasskeyRegistrationError.alreadyInProgress
        }
        let authRequest = Self.makeRegistrationRequest(request)
        let controller = ASAuthorizationController(authorizationRequests: [authRequest])
        controller.delegate = self
        controller.presentationContextProvider = self
        activeController = controller
        // If the surrounding Task is cancelled while the ceremony is in flight,
        // cancel the platform controller and resolve the awaiting continuation
        // with `.canceled`, clearing state so the next `register(_:)` is allowed
        // (otherwise `activeContinuation` would stay set and the next call would
        // throw `.alreadyInProgress`). `onCancel` runs on an arbitrary executor,
        // so hop to the main actor before touching ceremony state.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeContinuation = continuation
                // Close the cancel-before-start race: if the Task was already
                // cancelled (or cancelled while the continuation was being
                // installed), `onCancel` may have run as a no-op. Resolve here and
                // never start the ceremony (no system sheet for an already-dead
                // request).
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
    /// resolves the awaiting `register(_:)` with
    /// ``OwnerPasskeyRegistrationError/canceled``, clearing state so a
    /// subsequent `register(_:)` is allowed. No-op when nothing is in flight
    /// (`finish` is resume-once).
    private func cancelActiveCeremony() {
        guard activeContinuation != nil else { return }
        activeController?.cancel()
        finish(.failure(OwnerPasskeyRegistrationError.canceled))
    }

    private func finish(_ result: Result<OwnerPasskeyAttestation, Error>) {
        let continuation = activeContinuation
        activeContinuation = nil
        activeController = nil
        continuation?.resume(with: result)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyProvider: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let registration = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration
        else {
            finish(.failure(OwnerPasskeyRegistrationError.unexpectedCredentialType))
            return
        }
        guard let attestationObject = registration.rawAttestationObject else {
            finish(.failure(OwnerPasskeyRegistrationError.invalidResponse))
            return
        }
        finish(.success(OwnerPasskeyAttestation(
            credentialID: registration.credentialID,
            attestationObject: attestationObject,
            clientDataJSON: registration.rawClientDataJSON
        )))
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
