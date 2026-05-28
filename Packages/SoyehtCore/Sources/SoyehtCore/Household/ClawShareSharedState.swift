import Foundation

/// App-Group-backed shared state between the host app and the
/// `SoyehtClawShareTunnelProvider` NetworkExtension. The host
/// writes the credential + session request here; the extension
/// reads them at `startTunnel` and writes status updates back.
///
/// Storage layout (one Codable file per slot inside the App Group
/// container):
/// - `credential.json` — `ClawShareSharedCredential`
/// - `session-request.json` — `ClawShareSharedSessionRequest`
/// - `session-status.json` — `ClawShareSharedSessionStatus`
///
/// The extension's sandbox cannot reach the host's `Application
/// Support`, so this shared container is the only place the two
/// sides can exchange Codable state. SE-backed identity stays in
/// the shared Keychain access group, NOT in this file storage.
public enum ClawShareAppGroup {
    /// Canonical group identifier shared by host + extension. The
    /// entitlement files on both targets MUST list this id, otherwise
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// returns nil and the extension cannot read the credential.
    public static let identifier = "group.com.soyeht.mobile.clawshare"
}

// MARK: - Persisted record types

/// Wire shape for the `GuestCredential` bytes the host hands to the
/// extension. We persist the CBOR + a clock-domain hint so the
/// extension can refuse expired credentials without re-decoding
/// every field.
public struct ClawShareSharedCredential: Codable, Sendable, Equatable {
    public let credentialCBOR: Data
    public let issuedAtUnix: UInt64
    public let expiresAtUnix: UInt64
    public let clawId: String

    public init(
        credentialCBOR: Data,
        issuedAtUnix: UInt64,
        expiresAtUnix: UInt64,
        clawId: String
    ) {
        self.credentialCBOR = credentialCBOR
        self.issuedAtUnix = issuedAtUnix
        self.expiresAtUnix = expiresAtUnix
        self.clawId = clawId
    }
}

/// Host-side request asking the extension to bring up the tunnel.
/// The extension reads this on `startTunnel` and uses it to decide
/// which credential to load. A counter on every request distinguishes
/// "reuse current tunnel" from "fresh attempt".
public struct ClawShareSharedSessionRequest: Codable, Sendable, Equatable {
    public let slotIdHex: String
    public let requestedAtUnix: UInt64
    public let attempt: UInt32

    public init(slotIdHex: String, requestedAtUnix: UInt64, attempt: UInt32) {
        self.slotIdHex = slotIdHex
        self.requestedAtUnix = requestedAtUnix
        self.attempt = attempt
    }
}

/// Where the engine's claw data tunnel is reachable. The host stages
/// this (derived from its engine base URL) so the extension — which
/// cannot read the host's networking config — knows which `host:port`
/// to dial. Persisted in its own slot so it survives independently of
/// the credential.
public struct ClawShareSharedEndpoint: Codable, Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Snapshot the extension publishes back. The host polls (or
/// observes via NSFileCoordinator presenter) and uses
/// `ClawShareSessionStatus.isOpenable` to decide whether the
/// "open" affordance may appear.
public struct ClawShareSharedSessionStatus: Codable, Sendable, Equatable {
    /// Stable wire encoding of `ClawShareSessionStatus`. Persisted as
    /// the kebab-case rawValue + an optional payload field; the
    /// `decoded` accessor converts back.
    public let kind: String
    public let sinceUnix: UInt64?
    public let reason: String?
    public let updatedAtUnix: UInt64

    public init(_ status: ClawShareSessionStatus, updatedAtUnix: UInt64) {
        switch status {
        case .idle:                       kind = "idle";                sinceUnix = nil; reason = nil
        case .credentialReady:            kind = "credential-ready";    sinceUnix = nil; reason = nil
        case .dialing:                    kind = "dialing";             sinceUnix = nil; reason = nil
        case .awaitingFirstPacket:        kind = "awaiting-first-packet"; sinceUnix = nil; reason = nil
        case .connected(let since):       kind = "connected";           sinceUnix = since; reason = nil
        case .streamReady(let since):  kind = "stream-ready";     sinceUnix = since; reason = nil
        case .stopped(let r):             kind = "stopped";             sinceUnix = nil; reason = r
        case .failed(let r):              kind = "failed";              sinceUnix = nil; reason = r
        }
        self.updatedAtUnix = updatedAtUnix
    }

    public var decoded: ClawShareSessionStatus? {
        switch kind {
        case "idle":                       return .idle
        case "credential-ready":           return .credentialReady
        case "dialing":                    return .dialing
        case "awaiting-first-packet":      return .awaitingFirstPacket
        case "connected":                  return sinceUnix.map(ClawShareSessionStatus.connected(sinceUnix:))
        case "stream-ready":            return sinceUnix.map(ClawShareSessionStatus.streamReady(sinceUnix:))
        case "stopped":                    return .stopped(reason: reason ?? "")
        case "failed":                     return .failed(reason: reason ?? "")
        default:                           return nil
        }
    }
}

// MARK: - Store

public protocol ClawShareSharedStore: Sendable {
    func saveCredential(_ record: ClawShareSharedCredential) throws
    func loadCredential() throws -> ClawShareSharedCredential?
    func clearCredential() throws

    func saveSessionRequest(_ request: ClawShareSharedSessionRequest) throws
    func loadSessionRequest() throws -> ClawShareSharedSessionRequest?
    func clearSessionRequest() throws

    func saveEndpoint(_ endpoint: ClawShareSharedEndpoint) throws
    func loadEndpoint() throws -> ClawShareSharedEndpoint?
    func clearEndpoint() throws

    /// The host-signed proof-of-possession token (canonical CBOR of a
    /// `SessionAuthToken`), staged by the host before starting the tunnel.
    func saveSessionToken(_ tokenCBOR: Data) throws
    func loadSessionToken() throws -> Data?
    func clearSessionToken() throws

    func saveStatus(_ status: ClawShareSharedSessionStatus) throws
    func loadStatus() throws -> ClawShareSharedSessionStatus?
}

/// Production store backed by the App Group container. Reads + writes
/// JSON files inside the shared sandbox so the extension and the
/// host see the same bytes.
public final class FileSystemClawShareSharedStore: ClawShareSharedStore, @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Convenience constructor that resolves the canonical App Group
    /// container. Returns nil if the entitlement is missing — the
    /// caller must surface that as a configuration error rather than
    /// silently fall back to a non-shared location.
    public static func appGroup(identifier: String = ClawShareAppGroup.identifier) -> FileSystemClawShareSharedStore? {
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            return nil
        }
        let dir = container.appendingPathComponent("claw-share", isDirectory: true)
        return FileSystemClawShareSharedStore(directory: dir)
    }

    public func saveCredential(_ record: ClawShareSharedCredential) throws {
        try writeJSON(record, to: "credential.json")
    }
    public func loadCredential() throws -> ClawShareSharedCredential? {
        try readJSON(from: "credential.json")
    }
    public func clearCredential() throws {
        try remove("credential.json")
    }

    public func saveSessionRequest(_ request: ClawShareSharedSessionRequest) throws {
        try writeJSON(request, to: "session-request.json")
    }
    public func loadSessionRequest() throws -> ClawShareSharedSessionRequest? {
        try readJSON(from: "session-request.json")
    }
    public func clearSessionRequest() throws {
        try remove("session-request.json")
    }

    public func saveEndpoint(_ endpoint: ClawShareSharedEndpoint) throws {
        try writeJSON(endpoint, to: "endpoint.json")
    }
    public func loadEndpoint() throws -> ClawShareSharedEndpoint? {
        try readJSON(from: "endpoint.json")
    }
    public func clearEndpoint() throws {
        try remove("endpoint.json")
    }

    public func saveSessionToken(_ tokenCBOR: Data) throws {
        let url = directory.appendingPathComponent("session-token.cbor")
        try tokenCBOR.write(to: url, options: .atomic)
    }
    public func loadSessionToken() throws -> Data? {
        let url = directory.appendingPathComponent("session-token.cbor")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    public func clearSessionToken() throws {
        try remove("session-token.cbor")
    }

    public func saveStatus(_ status: ClawShareSharedSessionStatus) throws {
        try writeJSON(status, to: "session-status.json")
    }
    public func loadStatus() throws -> ClawShareSharedSessionStatus? {
        try readJSON(from: "session-status.json")
    }

    // MARK: - private

    private func writeJSON<T: Encodable>(_ value: T, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(from name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func remove(_ name: String) throws {
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
