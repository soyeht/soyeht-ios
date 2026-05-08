import CryptoKit
import Foundation
import SoyehtCore

/// In-memory `HouseholdSecureStoring` for tests that need a `CRLStore` /
/// `HouseholdSessionStore` without touching the device Keychain. Mirrors the
/// helper in `SoyehtCoreTests` so the App test target can build deterministic
/// integration suites without depending on the unit-test internal type.
final class TestInMemoryHouseholdStorage: HouseholdSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var failNextSave: Bool = false

    func save(_ data: Data, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failNextSave {
            failNextSave = false
            return false
        }
        values[account] = data
        return true
    }

    func load(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

/// In-memory `HouseholdGossipCursorStoring` so gossip-consumer tests can
/// assert cursor persistence without UserDefaults state leaking across runs.
final class TestInMemoryGossipCursorStore: HouseholdGossipCursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: UInt64] = [:]

    func loadCursor(for householdId: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return cursors[householdId]
    }

    func saveCursor(_ cursor: UInt64, for householdId: String) {
        lock.lock()
        defer { lock.unlock() }
        cursors[householdId] = cursor
    }

    func clearCursor(for householdId: String) {
        lock.lock()
        defer { lock.unlock() }
        cursors.removeValue(forKey: householdId)
    }
}

/// Records every `URLRequest` that flows through the test transport closure.
/// The integration tests use it to satisfy the Phase 3 traffic contract:
/// owner-events long-poll, gossip WS, and PoP-signed RPCs only — zero
/// polling to household-member endpoints (FR-016 / SC-009).
actor TrafficRecorder {
    private(set) var requests: [URLRequest] = []
    private(set) var paths: [String] = []

    func record(_ request: URLRequest) {
        requests.append(request)
        if let path = request.url?.path {
            paths.append(path)
        }
    }

    func currentPaths() -> [String] {
        paths
    }

    func currentRequests() -> [URLRequest] {
        requests
    }

    static let allowedPathPrefixes: [String] = [
        "/api/v1/household/owner-events",  // long-poll + /:cursor/approve
        "/api/v1/household/join-request",  // QR-staging POST
        "/api/v1/household/gossip",         // gossip WS (HTTP upgrade goes through transport)
        "/api/v1/household/snapshot",       // snapshot bootstrap (PoP-authed)
        "/api/v1/household/owner-device/push-token",  // APNS register
    ]

    /// Verifies every captured path starts with an allowed prefix from the
    /// Phase 3 contract surface — anything else (e.g. a polling probe to a
    /// per-member endpoint) is a traffic-shape violation.
    func assertAllPathsAllowed() -> [String] {
        paths.filter { path in
            !Self.allowedPathPrefixes.contains { prefix in path.hasPrefix(prefix) }
        }
    }
}

/// Recorded HTTP response factory used by the test transport. Each scripted
/// response is consumed in FIFO order. Tests can reset and re-script for
/// multi-request runs.
struct ScriptedHTTPResponse: Sendable {
    let status: Int
    let body: Data
    let contentType: String?

    init(status: Int = 200, body: Data, contentType: String? = "application/cbor") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
}

/// Builds owner-event response bodies, gossip event frames, and signed
/// `MachineCert` CBOR for the App-side integration tests. All keys are
/// deterministic so traffic captures can byte-compare in regression tests.
enum MachineJoinTestFixtures {
    /// Builds a canonical-CBOR `MachineCert` per protocol §5, signed by
    /// `householdPrivateKey`. Mirrors `SoyehtCoreTests/HouseholdTestFixtures`.
    static func signedMachineCert(
        householdPrivateKey: P256.Signing.PrivateKey,
        machinePublicKey: Data,
        householdId: String? = nil,
        hostname: String = "studio.local",
        platform: String = "macos",
        joinedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> Data {
        let hhPub = householdPrivateKey.publicKey.compressedRepresentation
        let resolvedHouseholdId = try householdId
            ?? HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let machineId = try HouseholdIdentifiers.identifier(
            for: machinePublicKey,
            kind: .machine
        )
        let withoutSignature: [String: HouseholdCBORValue] = [
            "hh_id": .text(resolvedHouseholdId),
            "hostname": .text(hostname),
            "issued_by": .text(resolvedHouseholdId),
            "joined_at": .unsigned(UInt64(joinedAt.timeIntervalSince1970)),
            "m_id": .text(machineId),
            "m_pub": .bytes(machinePublicKey),
            "platform": .text(platform),
            "type": .text("machine"),
            "v": .unsigned(1),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(withoutSignature))
        let signature = try householdPrivateKey
            .signature(for: signingBytes)
            .rawRepresentation
        var full = withoutSignature
        full["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(full))
    }

    /// Builds a canonical CBOR gossip event frame, signed by `issuerKey`
    /// (the founder Mac in Story 1; the backup Mac in T044c after the
    /// founder dies). Returns the bytes ready to feed into
    /// `HouseholdGossipConsumer.process(.data(...))`.
    static func gossipEventFrame(
        eventId: Data,
        cursor: UInt64,
        type: String,
        timestamp: Date,
        issuerMachineId: String,
        issuerKey: P256.Signing.PrivateKey,
        payload: [String: HouseholdCBORValue]
    ) throws -> Data {
        var map: [String: HouseholdCBORValue] = [
            "cursor": .unsigned(cursor),
            "event_id": .bytes(eventId),
            "issuer_m_id": .text(issuerMachineId),
            "payload": .map(payload),
            "ts": .unsigned(UInt64(timestamp.timeIntervalSince1970)),
            "type": .text(type),
            "v": .unsigned(1),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(map))
        map["signature"] = .bytes(
            try issuerKey.signature(for: signingBytes).rawRepresentation
        )
        return HouseholdCBOR.encode(.map(map))
    }

    /// Builds a canonical owner-event CBOR map (one entry inside the
    /// owner-events response array). The signature is over the CBOR map
    /// minus the `signature` key, signed by `issuerKey`.
    static func ownerEventCBOR(
        cursor: UInt64,
        type: String,
        payload: [String: HouseholdCBORValue],
        timestamp: Date,
        issuerMachineId: String,
        issuerKey: P256.Signing.PrivateKey
    ) throws -> HouseholdCBORValue {
        var map: [String: HouseholdCBORValue] = [
            "cursor": .unsigned(cursor),
            "issuer_m_id": .text(issuerMachineId),
            "payload": .map(payload),
            "ts": .unsigned(UInt64(timestamp.timeIntervalSince1970)),
            "type": .text(type),
            "v": .unsigned(1),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(map))
        map["signature"] = .bytes(
            try issuerKey.signature(for: signingBytes).rawRepresentation
        )
        return .map(map)
    }

    /// Builds the canonical CBOR body returned by the owner-events
    /// long-poll: `{v=1, events=[…], next_cursor=N}`.
    static func ownerEventsResponse(
        events: [HouseholdCBORValue],
        nextCursor: UInt64
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "events": .array(events),
            "next_cursor": .unsigned(nextCursor),
            "v": .unsigned(1),
        ]))
    }

    /// Builds the CBOR `JoinRequest` sub-payload the founder Mac forwards
    /// to the iPhone via the long-poll.
    static func joinRequestCBOR(
        envelope: JoinRequestEnvelope
    ) -> Data {
        HouseholdCBOR.joinRequest(envelope)
    }

    /// Builds a Bonjour-origin `JoinRequestEnvelope` for an unjoined
    /// candidate Mac. Signs the FR-029 challenge under `candidatePrivateKey`
    /// so the iPhone-side parser accepts the envelope.
    static func bonjourJoinRequestEnvelope(
        candidatePrivateKey: P256.Signing.PrivateKey,
        nonce: Data,
        hostname: String = "studio.local",
        platform: String = "macos",
        candidateAddress: String = "100.64.1.5:8443",
        ttlUnix: UInt64,
        householdId: String,
        receivedAt: Date,
        transport: PairMachineTransport = .lan
    ) throws -> JoinRequestEnvelope {
        let candidatePublicKey = candidatePrivateKey.publicKey.compressedRepresentation
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: candidatePublicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try candidatePrivateKey
            .signature(for: challenge)
            .rawRepresentation
        let origin: JoinRequestTransportOrigin = {
            switch transport {
            case .lan: return .bonjourShortcut
            case .tailscale: return .qrTailscale
            }
        }()
        return JoinRequestEnvelope(
            householdId: householdId,
            machinePublicKey: candidatePublicKey,
            nonce: nonce,
            rawHostname: hostname,
            rawPlatform: platform,
            candidateAddress: candidateAddress,
            ttlUnix: ttlUnix,
            challengeSignature: signature,
            transportOrigin: origin,
            receivedAt: receivedAt
        )
    }

    /// Builds a `pair-machine` URL signed by the candidate so
    /// `QRScannerDispatcher`'s parser accepts it. Used by the Story 2 test
    /// to drive the QR-scan path end-to-end.
    static func pairMachineURL(
        candidatePrivateKey: P256.Signing.PrivateKey,
        nonce: Data,
        hostname: String = "studio.local",
        platform: PairMachinePlatform = .macos,
        transport: PairMachineTransport = .tailscale,
        address: String = "studio.tailnet:8443",
        expiry: UInt64
    ) throws -> URL {
        let publicKey = candidatePrivateKey.publicKey.compressedRepresentation
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform.rawValue
        )
        let signature = try candidatePrivateKey
            .signature(for: challenge)
            .rawRepresentation
        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-machine"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "m_pub", value: publicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "hostname", value: hostname),
            URLQueryItem(name: "platform", value: platform.rawValue),
            URLQueryItem(name: "transport", value: transport.rawValue),
            URLQueryItem(name: "addr", value: address),
            URLQueryItem(
                name: "challenge_sig",
                value: signature.soyehtBase64URLEncodedString()
            ),
            URLQueryItem(name: "ttl", value: String(expiry)),
        ]
        guard let url = components.url else {
            throw NSError(
                domain: "MachineJoinTestFixtures",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to build pair-machine URL"]
            )
        }
        return url
    }
}
