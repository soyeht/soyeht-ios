import Foundation

public enum HouseholdPairingError: Error, Equatable {
    case invalidQR
    case expiredQR
    case cameraPermissionDenied
    case noMatchingHousehold
    case identityKeyUnavailable
    case biometryCanceled
    case pairingRejected
    case firstOwnerAlreadyPaired
    case certInvalid
    case storageFailed
    case networkUnavailable

    public enum Recovery: Equatable, Sendable {
        case scanFreshQRCode
        case enableCamera
        case joinHouseholdNetwork
        case retryBiometry
        case retryPairing
        case retryLater
        case checkDeviceSecurity
    }

    public var recovery: Recovery {
        switch self {
        case .invalidQR, .expiredQR:
            return .scanFreshQRCode
        case .cameraPermissionDenied:
            return .enableCamera
        case .noMatchingHousehold:
            return .joinHouseholdNetwork
        case .identityKeyUnavailable, .biometryCanceled:
            return .retryBiometry
        case .pairingRejected, .firstOwnerAlreadyPaired, .certInvalid:
            return .retryPairing
        case .storageFailed:
            return .checkDeviceSecurity
        case .networkUnavailable:
            return .retryLater
        }
    }

    public var localizationKey: String {
        switch self {
        case .invalidQR:
            return "household.pairing.error.invalidQR"
        case .expiredQR:
            return "household.pairing.error.expiredQR"
        case .cameraPermissionDenied:
            return "household.pairing.error.cameraPermissionDenied"
        case .noMatchingHousehold:
            return "household.pairing.error.noMatchingHousehold"
        case .identityKeyUnavailable:
            return "household.pairing.error.identityKeyUnavailable"
        case .biometryCanceled:
            return "household.pairing.error.biometryCanceled"
        case .pairingRejected:
            return "household.pairing.error.pairingRejected"
        case .firstOwnerAlreadyPaired:
            return "household.pairing.error.firstOwnerAlreadyPaired"
        case .certInvalid:
            return "household.pairing.error.certInvalid"
        case .storageFailed:
            return "household.pairing.error.storageFailed"
        case .networkUnavailable:
            return "household.pairing.error.networkUnavailable"
        }
    }
}
