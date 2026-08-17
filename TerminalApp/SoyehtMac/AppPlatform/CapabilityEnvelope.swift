import Foundation

/// Phase 2b contract §1 — the capability-bridge message envelope.
///
/// Pure domain types: no AppKit, testable in the domain package. The command
/// vocabulary is a CLOSED enum (never a string dispatched by table), the
/// request decode is STRICT (an unknown key is rejected, not ignored —
/// `Codable` synthesis silently skips extra keys, and a keyed container's
/// `allKeys` only reports keys the type can already represent, so rejection
/// requires a second container keyed by any-string and a set comparison;
/// both measured in phase 2a), and the body size limit is enforced BEFORE
/// the parser, not after.

/// The closed command vocabulary. Adding a capability adds a case here —
/// which is a contract change: consumers switching exhaustively over this
/// enum must be told in the same commit.
enum CapabilityCommand: String, Codable, Hashable, CaseIterable {
    case metricsRead = "metrics.read"
}

/// Closed failure-code vocabulary. Kept as an enum (rawValue on the wire —
/// byte-identical JSON to a plain string) so no producer can mint a code
/// outside the vocabulary; the phase-2b review rule, applied by construction
/// instead of by convention.
enum CapabilityFailureCode: String, Codable, Hashable, CaseIterable {
    /// Body exceeded the size limit (checked before parsing).
    case tooLarge = "too_large"
    /// Body is not decodable JSON / malformed envelope.
    case malformed = "malformed"
    /// A key outside the envelope's schema was present.
    case unknownKey = "unknown_key"
    /// The command is not in the closed vocabulary.
    case unknownCommand = "unknown_command"
    /// Envelope version is not one this binary speaks.
    case unsupportedVersion = "unsupported_version"
    /// The principal lacks the capability (set by the policy slice, not the
    /// envelope — listed here so the wire vocabulary lives in one place).
    case notGranted = "not_granted"
    /// Rate limit exceeded (enforced by the bridge slice).
    case rateLimited = "rate_limited"
    /// Internal error; no detail is disclosed.
    case internalError = "internal_error"
}

/// Failure payload returned to the app. `message` is safe to display and
/// MUST NOT leak path, host, username, or file existence — errors are not
/// an oracle. The static constructors carry no context parameters beyond
/// what is safe by design.
struct CapabilityFailure: Codable, Hashable {
    let code: CapabilityFailureCode
    let message: String

    private init(code: CapabilityFailureCode, message: String) {
        self.code = code
        self.message = message
    }

    static func tooLarge(limitBytes: Int) -> CapabilityFailure {
        CapabilityFailure(code: .tooLarge, message: "Request body exceeds \(limitBytes) bytes.")
    }

    static var malformed: CapabilityFailure {
        CapabilityFailure(code: .malformed, message: "Request body is not a valid capability envelope.")
    }

    static var unknownCommand: CapabilityFailure {
        CapabilityFailure(code: .unknownCommand, message: "Command is not in the capability vocabulary.")
    }

    static var unsupportedVersion: CapabilityFailure {
        CapabilityFailure(code: .unsupportedVersion, message: "Envelope version is not supported.")
    }

    static var notGranted: CapabilityFailure {
        CapabilityFailure(code: .notGranted, message: "Capability is not granted to this app.")
    }

    static var rateLimited: CapabilityFailure {
        CapabilityFailure(code: .rateLimited, message: "Too many requests.")
    }

    static var internalError: CapabilityFailure {
        CapabilityFailure(code: .internalError, message: "The request could not be completed.")
    }
}

/// Envelope decode failures. The bridge maps these to `CapabilityFailure`
/// codes on the wire; they exist separately so tests can assert the REASON
/// a body was refused, not just that it was.
enum CapabilityRequestError: Error, Equatable {
    case tooLarge(limitBytes: Int)
    case malformed
    case unknownKey(String)
    case unknownCommand(String)
    case unsupportedVersion(Int)
    case missingKey(String)
    case invalidID
}

/// The request envelope the app's relay sends to the bridge.
struct CapabilityRequest: Codable, Hashable {
    /// Envelope version. Only `1` exists; anything else is refused.
    let v: Int
    /// Correlation id, opaque to the bridge. Bounded by the body-size limit.
    let id: String
    let command: CapabilityCommand

    init(id: String, command: CapabilityCommand) {
        self.v = 1
        self.id = id
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case v, id, command
    }

    private static let knownKeys: Set<String> = ["v", "id", "command"]

    /// Maximum accepted body, enforced BEFORE any parsing. Requests carry a
    /// version, an id, and a command — anything larger is not a request, and
    /// parsing it would only be doing the attacker's work.
    static let maxBodyBytes = 4096

    /// Strict decode with the size gate in front. This is the single entry
    /// point the bridge should use — it refuses, in order: oversized body,
    /// undecodable JSON, unknown key, missing key, bad types, unknown
    /// command, unsupported version.
    static func decode(_ data: Data, limitBytes: Int = CapabilityRequest.maxBodyBytes) throws -> CapabilityRequest {
        guard data.count <= limitBytes else {
            throw CapabilityRequestError.tooLarge(limitBytes: limitBytes)
        }
        do {
            return try JSONDecoder().decode(CapabilityRequest.self, from: data)
        } catch let error as CapabilityRequestError {
            throw error
        } catch {
            throw CapabilityRequestError.malformed
        }
    }

    init(from decoder: Decoder) throws {
        // Unknown-key rejection: compare against an ANY-keyed container.
        // A typed container cannot see keys outside its own CodingKeys
        // (measured, phase 2a) — this second container is the only view
        // that reports them.
        let any = try decoder.container(keyedBy: AnyCodingKey.self)
        let present = Set(any.allKeys.map(\.stringValue))
        if let unknown = present.first(where: { !Self.knownKeys.contains($0) }) {
            throw CapabilityRequestError.unknownKey(unknown)
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try c.decodeIfPresent(Int.self, forKey: .v) else {
            throw CapabilityRequestError.missingKey("v")
        }
        guard version == 1 else {
            throw CapabilityRequestError.unsupportedVersion(version)
        }
        guard let rawID = try c.decodeIfPresent(String.self, forKey: .id) else {
            throw CapabilityRequestError.missingKey("id")
        }
        guard !rawID.isEmpty else {
            throw CapabilityRequestError.invalidID
        }
        guard let rawCommand = try c.decodeIfPresent(String.self, forKey: .command) else {
            throw CapabilityRequestError.missingKey("command")
        }
        guard let command = CapabilityCommand(rawValue: rawCommand) else {
            throw CapabilityRequestError.unknownCommand(rawCommand)
        }
        self.init(id: rawID, command: command)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(command, forKey: .command)
    }
}

/// CodingKey that accepts any string — the lens through which an unknown
/// key becomes visible to strict decoding.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
