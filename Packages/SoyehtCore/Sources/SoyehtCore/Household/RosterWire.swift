import Foundation

public enum RosterWireError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedContentType
    case payloadTooLarge
    case malformedResponse
    case nonCanonicalResponse
    case unexpectedKeySet
    case serverError(code: String)
    case transportFailed
}

public enum RosterWire {
    public static let contentType = "application/cbor"
    public static let admitBodyLimit = 1024 * 1024
    public static let nonceBodyLimit = 1024

    public static func endpointURL(baseURL: URL, path: String) throws -> (URL, String) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RosterWireError.invalidURL
        }
        if components.percentEncodedQuery != nil || components.fragment != nil {
            throw RosterWireError.invalidURL
        }
        if path.contains("?") || path.contains("#") {
            throw RosterWireError.invalidURL
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty ? path : "/\(basePath)\(path)"
        guard let url = components.url else {
            throw RosterWireError.invalidURL
        }
        return (url, components.percentEncodedPath)
    }

    public static func validateResponseContentType(_ value: String?) throws {
        guard value == contentType else {
            throw RosterWireError.unsupportedContentType
        }
    }

    public static func decodeCanonical(_ data: Data) throws -> HouseholdCBORValue {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw RosterWireError.malformedResponse
        }
        guard HouseholdCBOR.encode(decoded) == data else {
            throw RosterWireError.nonCanonicalResponse
        }
        return decoded
    }

    public static let knownErrorLiterals: Set<String> = [
        "unauthenticated",
        "invalid_request",
        "query_not_allowed",
        "invalid_machine_id",
        "payload_too_large",
        "body_not_allowed",
        "unsupported_media_type",
        "already_initialized",
        "not_ready",
        "not_initialized",
        "clock_unavailable",
        "lock_timeout",
        "internal_error",
        "sign_failed",
        "household",
        "owner_auth",
        "storage",
        "store_io",
        "unsafe_file_type",
        "temp_already_exists",
        "mode_mismatch",
        "invalid_path",
        "inconsistent_provisioning_state",
        "readback_mismatch",
        "invalid_current_owner_authority",
        "latch_poisoned",
        "encode_failed",
        "integrity_non_canonical",
        "integrity_duplicate_key",
        "integrity_unknown_field",
        "integrity_null_field",
        "integrity_version",
        "integrity_household",
        "integrity_key_set",
        "integrity_checkpoint_decode",
        "integrity_checkpoint_signature",
        "integrity_owner_certificate",
        "integrity_owner_continuity",
        "integrity_sequence",
        "integrity_hash",
        "integrity_projection",
        "integrity_fork_reapply",
        "integrity_temporal",
        "integrity_epoch",
    ]

    public static func decodeErrorEnvelope(_ data: Data) -> RosterWireError {
        guard let decoded = try? decodeCanonical(data),
              case .map(let map) = decoded,
              case .unsigned(let v) = map["v"], v == 1,
              case .text(let code) = map["error"],
              map.count == 2,
              knownErrorLiterals.contains(code) else {
            return .malformedResponse
        }
        return .serverError(code: code)
    }

    public static func requireExactKeys(_ map: [String: HouseholdCBORValue], _ keys: Set<String>) throws {
        guard Set(map.keys) == keys else {
            throw RosterWireError.unexpectedKeySet
        }
    }

    public static func requireText(_ map: [String: HouseholdCBORValue], _ key: String) throws -> String {
        guard case .text(let v) = map[key] else {
            throw RosterWireError.unexpectedKeySet
        }
        return v
    }

    public static func requireUInt(_ map: [String: HouseholdCBORValue], _ key: String) throws -> UInt64 {
        guard case .unsigned(let v) = map[key] else {
            throw RosterWireError.unexpectedKeySet
        }
        return v
    }

    public static func requireBytes(_ map: [String: HouseholdCBORValue], _ key: String) throws -> Data {
        guard case .bytes(let v) = map[key] else {
            throw RosterWireError.unexpectedKeySet
        }
        return v
    }

    public static func requireBytes32(_ map: [String: HouseholdCBORValue], _ key: String) throws -> Data {
        let data = try requireBytes(map, key)
        guard data.count == 32 else {
            throw RosterWireError.unexpectedKeySet
        }
        return data
    }

    public static func requireBytes64(_ map: [String: HouseholdCBORValue], _ key: String) throws -> Data {
        let data = try requireBytes(map, key)
        guard data.count == 64 else {
            throw RosterWireError.unexpectedKeySet
        }
        return data
    }

    public static func requireMap(_ map: [String: HouseholdCBORValue], _ key: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let v) = map[key] else {
            throw RosterWireError.unexpectedKeySet
        }
        return v
    }

    public static func encodeNonceRequest(clientNonce: Data) throws -> Data {
        guard clientNonce.count == 32 else {
            throw RosterWireError.malformedResponse
        }
        return HouseholdCBOR.encode(.map([
            "client_nonce": .bytes(clientNonce),
            "v": .unsigned(1),
        ]))
    }
}
