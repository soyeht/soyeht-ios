import CryptoKit
import Foundation
import LocalAuthentication
import Security

public struct OwnerApprovalCapability: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable {
        case noSession = "no_session"
        case identityMismatch = "identity_mismatch"
        case noKey = "no_key"
        case needsAuthentication = "needs_authentication"
        case proven
        case error
    }

    public let state: State
    public let cause: String

    public init(state: State, cause: String) {
        self.state = state
        self.cause = cause
    }

    /// Contains no key material, account names or household identifiers.
    public var diagnostic: String { "owner_capability=\(state.rawValue) cause=\(cause)" }
    public var canAttemptApproval: Bool { state == .proven || state == .needsAuthentication }

    public static func failure(_ error: Error) -> Self {
        switch error {
        case OwnerIdentityKeyError.keyNotFound:
            return .init(state: .noKey, cause: "item_not_found")
        case OwnerIdentityKeyError.publicKeyMismatch:
            return .init(state: .identityMismatch, cause: "signing_key_mismatch")
        case OwnerIdentityKeyError.biometryCanceled, OwnerIdentityKeyError.biometryLockout:
            return .init(state: .needsAuthentication, cause: "authentication_required")
        case OwnerIdentityKeyError.securityFailure(let domain, let code):
            return securityFailure(domain: domain, code: code)
        default:
            var current: NSError? = error as NSError
            // Bound traversal also handles malformed error chains from adapters.
            for _ in 0..<8 {
                guard let value = current else { break }
                let result = securityFailure(domain: value.domain, code: value.code)
                if result.state == .needsAuthentication { return result }
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            return .init(state: .error, cause: "capability_check_failed")
        }
    }

    private static func securityFailure(domain: String, code: Int) -> Self {
        if domain == LAError.errorDomain {
            return .init(state: .needsAuthentication, cause: "LAError_\(code)")
        }
        if domain == NSOSStatusErrorDomain {
            let authentication = [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled]
            return .init(state: authentication.contains(OSStatus(clamping: code)) ? .needsAuthentication : .error,
                         cause: "security_\(code)")
        }
        return .init(state: .error, cause: "security_error")
    }
}

/// Proves only the ability to sign as the current owner. The engine still
/// authenticates every operation; this observation is never an authorization.
public struct OwnerApprovalCapabilityChecker {
    public typealias LoadSession = () throws -> ActiveHouseholdState?
    public typealias LoadSigner = (ActiveHouseholdState) throws -> any OwnerIdentitySigning
    private let loadSession: LoadSession
    private let loadSigner: LoadSigner

    public init(loadSession: @escaping LoadSession, loadSigner: @escaping LoadSigner) {
        self.loadSession = loadSession
        self.loadSigner = loadSigner
    }

    public static func local(profile: SoyehtInstallProfile = .current) -> Self {
        Self(loadSession: {
            guard let data = try HouseholdSessionStore.defaultStorage(for: profile)
                .loadWithoutInteraction(account: HouseholdSessionStore.activeSessionAccount) else { return nil }
            return try JSONDecoder().decode(ActiveHouseholdState.self, from: data)
        }, loadSigner: { session in
            try SecureEnclaveOwnerIdentityKeyProvider(servicePrefix: profile.householdOwnerKeyPrefix)
                .loadOwnerIdentityWithoutInteraction(keyReference: session.ownerKeyReference,
                    publicKey: session.ownerPublicKey, personId: session.ownerPersonId)
        })
    }

    public func check(authority: PairingAuthority) -> OwnerApprovalCapability {
        do {
            guard let session = try loadSession() else {
                return .init(state: .noSession, cause: "session_absent")
            }
            guard session.householdId == authority.householdID,
                  session.ownerPersonId == authority.ownerPersonID,
                  session.ownerPublicKey == authority.ownerPublicKey else {
                return .init(state: .identityMismatch, cause: "engine_owner_mismatch")
            }
            let signer = try loadSigner(session)
            guard signer.personId == authority.ownerPersonID,
                  signer.publicKey == authority.ownerPublicKey else {
                return .init(state: .identityMismatch, cause: "signer_identity_mismatch")
            }
            // Fresh, domain-separated, local-only proof. Never a request PoP or
            // reusable certificate, and never sent to the engine or the logs.
            let challenge = Data("soyeht.owner-capability.v1\0".utf8) + PairingCrypto.randomBytes(count: 32)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signer.sign(challenge))
            let key = try P256.Signing.PublicKey(compressedRepresentation: session.ownerPublicKey)
            guard key.isValidSignature(signature, for: challenge) else {
                return .init(state: .identityMismatch, cause: "signature_mismatch")
            }
            return .init(state: .proven, cause: "local_signature_verified")
        } catch {
            return .failure(error)
        }
    }
}
