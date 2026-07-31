import Foundation

public struct RosterCurrencyMember: Sendable, Equatable {
    public let mId: String
    public let mPub: Data
    public let machineCert: Data
    public let machineCertFingerprint: Data
}

public struct RosterCurrencyTombstone: Sendable, Equatable {
    public let v: UInt64
    public let kind: String
    public let hhId: String
    public let epoch: Data
    public let sequence: UInt64
    public let prevEventHash: Data
    public let mId: String
    public let mPub: Data
    public let machineCertFingerprint: Data
    public let revokedAt: UInt64
    public let reason: UInt64
    public let cascade: UInt64
    public let ownerPId: String
    public let ownerCertFingerprint: Data
    public let ownerPersonCert: Data
    public let signature: Data
    /// The canonical CBOR of this tombstone exactly as the peer sent it, recovered by
    /// re-encoding the same validated nested map. Retained so the revocation signature can
    /// be verified later against the bytes that were actually signed, rather than against
    /// a map rebuilt from the typed fields above.
    public let canonicalTombstone: Data
}

public struct RosterCurrencyResponse: Sendable, Equatable {
    public let v: UInt64
    public let outcome: String
    public let member: RosterCurrencyMember?
    public let tombstone: RosterCurrencyTombstone?
}

public enum RosterCurrencyClientError: Error, Equatable, Sendable {
    case wire(RosterWireError)
    case httpStatus(Int)
    case transportFailed
}

public struct RosterCurrencyClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let pathPrefix = "/api/v1/household/roster/currency"
    static let revocationKind = "household-machine-roster-revocation/v1"

    static let outcomes: Set<String> = [
        "active",
        "revoked",
        "not_listed",
        "unavailable_no_genesis",
        "unavailable_checkpoint_stale",
        "unavailable_checkpoint_fork_conflict",
        "unavailable_event_fork_conflict",
        "unavailable_clock_state",
        "unavailable_owner_authority",
    ]

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(baseURL: URL, popSigner: HouseholdPoPSigner, perform: @escaping TransportPerform) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = perform
    }

    public func currency(machineId: String) async throws -> RosterCurrencyResponse {
        guard Self.isValidMachineId(machineId) else {
            throw RosterCurrencyClientError.wire(.invalidURL)
        }
        let (url, pathAndQuery) = try RosterWire.endpointURL(
            baseURL: baseURL,
            path: "\(Self.pathPrefix)/\(machineId)"
        )
        let authorization = try popSigner.authorization(
            method: "GET",
            pathAndQuery: pathAndQuery,
            body: Data()
        ).authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw RosterCurrencyClientError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw RosterCurrencyClientError.transportFailed
        }
        try RosterWire.validateResponseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        guard http.statusCode == 200 else {
            throw RosterCurrencyClientError.wire(
                RosterClientErrorEnvelope.decodeError(status: http.statusCode, data: data)
            )
        }
        let decoded = try RosterWire.decodeCanonical(data)
        guard case .map(let map) = decoded else {
            throw RosterCurrencyClientError.wire(.unexpectedKeySet)
        }
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let outcome = try RosterWire.requireText(map, "outcome")
        guard Self.outcomes.contains(outcome) else { throw RosterCurrencyClientError.wire(.malformedResponse) }

        var member: RosterCurrencyMember?
        var tombstone: RosterCurrencyTombstone?

        switch outcome {
        case "active":
            try RosterWire.requireExactKeys(map, ["member", "outcome", "v"])
            member = try decodeMember(map, requestedMachineId: machineId)
        case "revoked":
            try RosterWire.requireExactKeys(map, ["outcome", "tombstone", "v"])
            tombstone = try decodeTombstone(map, requestedMachineId: machineId)
        default:
            try RosterWire.requireExactKeys(map, ["outcome", "v"])
        }

        return RosterCurrencyResponse(v: v, outcome: outcome, member: member, tombstone: tombstone)
    }

    private static func isValidMachineId(_ machineId: String) -> Bool {
        guard machineId.hasPrefix("m_"), machineId.count == 54 else { return false }
        return machineId.dropFirst(2).allSatisfy { character in
            switch character {
            case "a"..."z", "2"..."7": return true
            default: return false
            }
        }
    }

    private func decodeMember(
        _ map: [String: HouseholdCBORValue],
        requestedMachineId: String
    ) throws -> RosterCurrencyMember {
        let mMap = try RosterWire.requireMap(map, "member")
        try RosterWire.requireExactKeys(mMap, ["m_id", "m_pub", "machine_cert", "machine_cert_fingerprint"])
        let mId = try RosterWire.requireText(mMap, "m_id")
        guard mId == requestedMachineId else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let mPub = try RosterWire.requireBytes(mMap, "m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(mPub)
        } catch {
            throw RosterCurrencyClientError.wire(.malformedResponse)
        }
        let machineCert = try RosterWire.requireBytes(mMap, "machine_cert")
        guard !machineCert.isEmpty else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let machineCertFingerprint = try RosterWire.requireBytes32(mMap, "machine_cert_fingerprint")
        return RosterCurrencyMember(
            mId: mId,
            mPub: mPub,
            machineCert: machineCert,
            machineCertFingerprint: machineCertFingerprint
        )
    }

    private func decodeTombstone(
        _ map: [String: HouseholdCBORValue],
        requestedMachineId: String
    ) throws -> RosterCurrencyTombstone {
        let tMap = try RosterWire.requireMap(map, "tombstone")
        try RosterWire.requireExactKeys(tMap, [
            "v", "kind", "hh_id", "epoch", "sequence", "prev_event_hash",
            "m_id", "m_pub", "machine_cert_fingerprint", "revoked_at",
            "reason", "cascade", "owner_p_id", "owner_cert_fingerprint",
            "owner_person_cert", "signature",
        ])
        let v = try RosterWire.requireUInt(tMap, "v")
        guard v == 1 else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let kind = try RosterWire.requireText(tMap, "kind")
        guard kind == Self.revocationKind else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let hhId = try RosterWire.requireText(tMap, "hh_id")
        let epoch = try RosterWire.requireBytes32(tMap, "epoch")
        let sequence = try RosterWire.requireUInt(tMap, "sequence")
        let prevEventHash = try RosterWire.requireBytes32(tMap, "prev_event_hash")
        let mId = try RosterWire.requireText(tMap, "m_id")
        guard mId == requestedMachineId else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let mPub = try RosterWire.requireBytes(tMap, "m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(mPub)
        } catch {
            throw RosterCurrencyClientError.wire(.malformedResponse)
        }
        let machineCertFingerprint = try RosterWire.requireBytes32(tMap, "machine_cert_fingerprint")
        let revokedAt = try RosterWire.requireUInt(tMap, "revoked_at")
        let reason = try RosterWire.requireUInt(tMap, "reason")
        guard reason <= 4 else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let cascade = try RosterWire.requireUInt(tMap, "cascade")
        guard cascade <= 1 else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let ownerPId = try RosterWire.requireText(tMap, "owner_p_id")
        let ownerCertFingerprint = try RosterWire.requireBytes32(tMap, "owner_cert_fingerprint")
        let ownerPersonCert = try RosterWire.requireBytes(tMap, "owner_person_cert")
        guard !ownerPersonCert.isEmpty else { throw RosterCurrencyClientError.wire(.malformedResponse) }
        let signature = try RosterWire.requireBytes64(tMap, "signature")
        return RosterCurrencyTombstone(
            v: v,
            kind: kind,
            hhId: hhId,
            epoch: epoch,
            sequence: sequence,
            prevEventHash: prevEventHash,
            mId: mId,
            mPub: mPub,
            machineCertFingerprint: machineCertFingerprint,
            revokedAt: revokedAt,
            reason: reason,
            cascade: cascade,
            ownerPId: ownerPId,
            ownerCertFingerprint: ownerCertFingerprint,
            ownerPersonCert: ownerPersonCert,
            signature: signature,
            canonicalTombstone: HouseholdCBOR.encode(.map(tMap))
        )
    }
}
