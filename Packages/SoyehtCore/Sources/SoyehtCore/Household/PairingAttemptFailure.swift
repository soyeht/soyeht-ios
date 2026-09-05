import Foundation

/// Carries the actual operation and transport failure through services to UI.
/// Diagnostics contain no request body, credentials or URL query.
public struct PairingAttemptFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Stage: String, Sendable {
        case discovery, claim, notification, status, initialize, confirm
        case request, poll, approval, identity, storage
    }

    public enum NetworkCause: String, Sendable {
        case dns, connection, timeout, offline, tls, other
    }

    public enum Cause: Equatable, Sendable {
        case address(PairingAddressError)
        case network(NetworkCause, domain: String, code: Int)
        case server(status: Int)
        case bootstrap(code: String)
        case invalidResponse
        case certificate
        case approvalUnavailable
        case approvalExpired
        case identityUnavailable
        case storage
        case unknown(domain: String, code: Int)
    }

    public let stage: Stage
    public let endpoint: URL?
    public let cause: Cause

    public init(stage: Stage, endpoint: URL?, cause: Cause) {
        self.stage = stage
        self.endpoint = endpoint.flatMap(Self.sanitized)
        self.cause = cause
    }

    public static func capture(_ error: Error, stage: Stage, endpoint: URL?) -> Self {
        if let failure = error as? Self { return failure }
        if let address = error as? PairingAddressError {
            return Self(stage: stage, endpoint: endpoint, cause: .address(address))
        }
        if let bootstrap = error as? BootstrapError {
            let cause: Cause
            switch bootstrap {
            case .networkDrop: cause = .network(.other, domain: "BootstrapError", code: 0)
            case .protocolViolation, .engineTooOld: cause = .invalidResponse
            case .serverError(let code, _): cause = .bootstrap(code: code)
            }
            return Self(stage: stage, endpoint: endpoint, cause: cause)
        }
        if let pairing = error as? HouseholdPairingError {
            let cause: Cause
            switch pairing {
            case .invalidQR: cause = .invalidResponse
            case .expiredQR: cause = .address(.expiredOffer)
            case .identityKeyUnavailable, .biometryCanceled: cause = .identityUnavailable
            case .certInvalid: cause = .certificate
            case .firstOwnerAlreadyPaired: cause = .approvalUnavailable
            case .storageFailed: cause = .storage
            default: cause = .unknown(domain: "HouseholdPairingError", code: (error as NSError).code)
            }
            return Self(stage: stage, endpoint: endpoint, cause: cause)
        }
        if let pairing = error as? HouseholdDevicePairingError {
            let cause: Cause
            switch pairing {
            case .invalidLink: cause = .invalidResponse
            case .identityKeyUnavailable, .biometryCanceled: cause = .identityUnavailable
            case .certInvalid: cause = .certificate
            case .approvalTimedOut: cause = .approvalExpired
            case .storageFailed: cause = .storage
            default: cause = .unknown(domain: "HouseholdDevicePairingError", code: (error as NSError).code)
            }
            return Self(stage: stage, endpoint: endpoint, cause: cause)
        }
        if let urlError = error as? URLError {
            let kind: NetworkCause
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed: kind = .dns
            case .cannotConnectToHost, .networkConnectionLost: kind = .connection
            case .timedOut: kind = .timeout
            case .notConnectedToInternet: kind = .offline
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid: kind = .tls
            default: kind = .other
            }
            return Self(stage: stage, endpoint: endpoint,
                        cause: .network(kind, domain: NSURLErrorDomain, code: urlError.code.rawValue))
        }
        if error is DecodingError {
            return Self(stage: stage, endpoint: endpoint, cause: .invalidResponse)
        }
        let ns = error as NSError
        return Self(stage: stage, endpoint: endpoint, cause: .unknown(domain: ns.domain, code: ns.code))
    }

    /// Cancellation is control flow, never a failure message or a retry.
    public static func rethrow(_ error: Error, stage: Stage, endpoint: URL?) throws -> Never {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
        throw capture(error, stage: stage, endpoint: endpoint)
    }

    public var diagnostic: String {
        "stage=\(stage.rawValue) endpoint=\(endpoint?.absoluteString ?? "none") cause=\(String(describing: cause))"
    }

    public var errorDescription: String? { userMessage }

    public var userMessage: String {
        switch cause {
        case .address(.profileMissing), .address(.profileMismatch):
            return String(localized: "The Mac and iPhone need matching Soyeht builds. Update both apps and try again.", bundle: .module)
        case .address(.unsupportedVersion), .invalidResponse:
            return String(localized: "The Mac and iPhone could not understand each other. Update both apps and try again.", bundle: .module)
        case .address(.expiredOffer), .address(.staleDecision):
            return String(localized: "This pairing offer has expired. Open Add iPhone on the Mac and try again.", bundle: .module)
        case .address:
            return String(localized: "No compatible address is available for this step. Open Add iPhone on the Mac and check the network connection.", bundle: .module)
        case .network(.dns, _, _):
            return String(localized: "The Mac’s network name could not be resolved. Check the network connection and try again.", bundle: .module)
        case .network(.timeout, _, _):
            return String(localized: "The Mac did not answer in time. Check the connection on both devices and try again.", bundle: .module)
        case .network(.connection, _, _):
            return String(localized: "The connection to the Mac failed. Keep Soyeht open on the Mac and try again.", bundle: .module)
        case .network(.offline, _, _):
            return String(localized: "This device is offline. Connect it to the same Wi-Fi or tailnet as the Mac and try again.", bundle: .module)
        case .network(.tls, _, _):
            return String(localized: "The Mac’s secure connection could not be verified. Check its address and try again.", bundle: .module)
        case .network:
            return String(localized: "The network connection failed. Check both devices and try again.", bundle: .module)
        case .server(let status):
            return String(localized: "The Mac declined this step (\(status)). Open Add iPhone on the Mac and try again.", bundle: .module)
        case .bootstrap(let code):
            if code == "profile_missing" || code == "profile_mismatch" {
                return String(localized: "The Mac and iPhone need matching Soyeht builds. Update both apps and try again.", bundle: .module)
            }
            if code == "invitation_not_recognized" || code == "invitation_expired" || code == "invitation_already_claimed" {
                return String(localized: "This invitation is no longer available. Open Add iPhone on the Mac and try again.", bundle: .module)
            }
            return String(localized: "The Mac declined this step. Open Add iPhone on the Mac and try again.", bundle: .module)
        case .certificate:
            return String(localized: "The home’s identity could not be verified. Check the security code on both devices.", bundle: .module)
        case .approvalUnavailable:
            return String(localized: "Approval is needed from a device that holds the home owner’s key. Check Add iPhone on the Mac for available options.", bundle: .module)
        case .approvalExpired:
            return String(localized: "The approval request expired. Start a new request and approve it on an authorized device.", bundle: .module)
        case .identityUnavailable:
            return String(localized: "The signing key could not be opened. Unlock this device and try again.", bundle: .module)
        case .storage:
            return String(localized: "The pairing could not be saved. Unlock this device and try again.", bundle: .module)
        case .unknown:
            return String(localized: "Pairing could not finish this step. Keep Soyeht open on both devices and try again.", bundle: .module)
        }
    }

    private static func sanitized(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}
