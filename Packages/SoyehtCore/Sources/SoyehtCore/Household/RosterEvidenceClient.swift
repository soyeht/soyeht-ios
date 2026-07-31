import Foundation

public struct RosterEvidenceSnapshotBody: Sendable, Equatable {
    public let v: UInt64
    public let hhId: String
    public let stateKind: UInt64
    public let genesisCheckpoint: Data?
    public let acceptedCheckpoint: Data?
    public let predecessorCheckpoint: Data?
    public let conflictingCheckpoint: Data?
    public let floorSecs: UInt64
}

public struct RosterEvidenceResponse: Sendable, Equatable {
    public let v: UInt64
    public let outcome: String
    public let snapshotBody: RosterEvidenceSnapshotBody?
    public let stateEvidenceDigest: Data?
    public let fullSnapshotDigest: Data?
    public let signerMId: String
    public let signerMachineCert: Data
    public let signerMachineCertFingerprint: Data
    public let clientNonce: Data
    public let signature: Data
}

public enum RosterEvidenceClientError: Error, Equatable, Sendable {
    case wire(RosterWireError)
    case httpStatus(Int)
    case transportFailed
}

public struct RosterEvidenceClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/household/roster/evidence"

    static let outcomes: Set<String> = [
        "available",
        "unavailable_clock_state",
        "unavailable_owner_authority",
        "unavailable_checkpoint_stale",
    ]

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(baseURL: URL, popSigner: HouseholdPoPSigner, perform: @escaping TransportPerform) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = perform
    }

    public func evidence(clientNonce: Data) async throws -> RosterEvidenceResponse {
        let (url, pathAndQuery) = try RosterWire.endpointURL(baseURL: baseURL, path: Self.path)
        guard clientNonce.count == 32 else {
            throw RosterEvidenceClientError.wire(.malformedResponse)
        }
        let body = try RosterWire.encodeNonceRequest(clientNonce: clientNonce)
        guard body.count <= RosterWire.nonceBodyLimit else {
            throw RosterEvidenceClientError.wire(.payloadTooLarge)
        }
        let authorization = try popSigner.authorization(
            method: "POST",
            pathAndQuery: pathAndQuery,
            body: body
        ).authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(RosterWire.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw RosterEvidenceClientError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw RosterEvidenceClientError.transportFailed
        }
        try RosterWire.validateResponseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        guard http.statusCode == 200 else {
            throw RosterEvidenceClientError.wire(
                RosterClientErrorEnvelope.decodeError(status: http.statusCode, data: data)
            )
        }
        let decoded = try RosterWire.decodeCanonical(data)
        guard case .map(let map) = decoded else {
            throw RosterEvidenceClientError.wire(.unexpectedKeySet)
        }
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterEvidenceClientError.wire(.malformedResponse) }
        let outcome = try RosterWire.requireText(map, "outcome")
        guard Self.outcomes.contains(outcome) else { throw RosterEvidenceClientError.wire(.malformedResponse) }

        if outcome == "available" {
            try RosterWire.requireExactKeys(map, [
                "client_nonce", "full_snapshot_digest", "outcome",
                "signer_m_id", "signer_machine_cert", "signer_machine_cert_fingerprint",
                "signature", "snapshot_body", "state_evidence_digest", "v",
            ])
        } else {
            try RosterWire.requireExactKeys(map, [
                "client_nonce", "outcome", "signer_m_id",
                "signer_machine_cert", "signer_machine_cert_fingerprint",
                "signature", "v",
            ])
        }

        let signerMId = try RosterWire.requireText(map, "signer_m_id")
        let signerMachineCert = try RosterWire.requireBytes(map, "signer_machine_cert")
        guard !signerMachineCert.isEmpty else { throw RosterEvidenceClientError.wire(.malformedResponse) }
        let signerMachineCertFingerprint = try RosterWire.requireBytes32(map, "signer_machine_cert_fingerprint")
        let clientNonceEcho = try RosterWire.requireBytes32(map, "client_nonce")
        let signature = try RosterWire.requireBytes64(map, "signature")

        var snapshotBody: RosterEvidenceSnapshotBody?
        var stateEvidenceDigest: Data?
        var fullSnapshotDigest: Data?
        if outcome == "available" {
            // Re-encode the already canonically validated nested map to recover the exact
            // canonical bytes the peer sent, then decode through the single shared
            // implementation. Nothing is re-derived from typed fields.
            let snapshotMap = try RosterWire.requireMap(map, "snapshot_body")
            snapshotBody = try Self.decodeSnapshotBody(
                canonicalSnapshotBody: HouseholdCBOR.encode(.map(snapshotMap))
            )
            stateEvidenceDigest = try RosterWire.requireBytes32(map, "state_evidence_digest")
            fullSnapshotDigest = try RosterWire.requireBytes32(map, "full_snapshot_digest")
        }

        return RosterEvidenceResponse(
            v: v,
            outcome: outcome,
            snapshotBody: snapshotBody,
            stateEvidenceDigest: stateEvidenceDigest,
            fullSnapshotDigest: fullSnapshotDigest,
            signerMId: signerMId,
            signerMachineCert: signerMachineCert,
            signerMachineCertFingerprint: signerMachineCertFingerprint,
            clientNonce: clientNonceEcho,
            signature: signature
        )
    }

    /// The one and only implementation of the evidence snapshot-body contract: canonical
    /// encoding, per-state-kind exact key sets, and the predecessor rule keyed off the
    /// accepted checkpoint's own sequence. Internal rather than private so that a stored
    /// snapshot can be rehydrated later through exactly these rules instead of a second
    /// decoder that would be free to drift. Fail-closed throughout.
    static func decodeSnapshotBody(canonicalSnapshotBody: Data) throws -> RosterEvidenceSnapshotBody {
        let decodedBody = try RosterWire.decodeCanonical(canonicalSnapshotBody)
        guard case .map(let sMap) = decodedBody else {
            throw RosterEvidenceClientError.wire(.unexpectedKeySet)
        }
        let v = try RosterWire.requireUInt(sMap, "v")
        guard v == 1 else { throw RosterEvidenceClientError.wire(.malformedResponse) }
        let hhId = try RosterWire.requireText(sMap, "hh_id")
        let stateKind = try RosterWire.requireUInt(sMap, "state_kind")
        guard stateKind <= 3 else { throw RosterEvidenceClientError.wire(.malformedResponse) }
        let floorSecs = try RosterWire.requireUInt(sMap, "floor_secs")

        switch stateKind {
        case 0:
            try RosterWire.requireExactKeys(sMap, ["v", "hh_id", "state_kind", "floor_secs"])
            return RosterEvidenceSnapshotBody(
                v: v, hhId: hhId, stateKind: stateKind,
                genesisCheckpoint: nil, acceptedCheckpoint: nil,
                predecessorCheckpoint: nil, conflictingCheckpoint: nil,
                floorSecs: floorSecs
            )
        case 1:
            let accepted = try RosterWire.requireBytes(sMap, "accepted_checkpoint")
            let acceptedSequence = try checkpointSequence(accepted)
            if acceptedSequence > 1 {
                try RosterWire.requireExactKeys(sMap, [
                    "v", "hh_id", "state_kind", "floor_secs",
                    "genesis_checkpoint", "accepted_checkpoint", "predecessor_checkpoint",
                ])
            } else {
                try RosterWire.requireExactKeys(sMap, [
                    "v", "hh_id", "state_kind", "floor_secs",
                    "genesis_checkpoint", "accepted_checkpoint",
                ])
            }
            let genesis = try RosterWire.requireBytes(sMap, "genesis_checkpoint")
            let predecessor: Data? = acceptedSequence > 1
                ? try RosterWire.requireBytes(sMap, "predecessor_checkpoint")
                : nil
            return RosterEvidenceSnapshotBody(
                v: v, hhId: hhId, stateKind: stateKind,
                genesisCheckpoint: genesis, acceptedCheckpoint: accepted,
                predecessorCheckpoint: predecessor, conflictingCheckpoint: nil,
                floorSecs: floorSecs
            )
        case 2, 3:
            let accepted = try RosterWire.requireBytes(sMap, "accepted_checkpoint")
            let acceptedSequence = try checkpointSequence(accepted)
            if acceptedSequence > 1 {
                try RosterWire.requireExactKeys(sMap, [
                    "v", "hh_id", "state_kind", "floor_secs",
                    "genesis_checkpoint", "accepted_checkpoint",
                    "conflicting_checkpoint", "predecessor_checkpoint",
                ])
            } else {
                try RosterWire.requireExactKeys(sMap, [
                    "v", "hh_id", "state_kind", "floor_secs",
                    "genesis_checkpoint", "accepted_checkpoint", "conflicting_checkpoint",
                ])
            }
            let genesis = try RosterWire.requireBytes(sMap, "genesis_checkpoint")
            let conflicting = try RosterWire.requireBytes(sMap, "conflicting_checkpoint")
            let predecessor: Data? = acceptedSequence > 1
                ? try RosterWire.requireBytes(sMap, "predecessor_checkpoint")
                : nil
            return RosterEvidenceSnapshotBody(
                v: v, hhId: hhId, stateKind: stateKind,
                genesisCheckpoint: genesis, acceptedCheckpoint: accepted,
                predecessorCheckpoint: predecessor, conflictingCheckpoint: conflicting,
                floorSecs: floorSecs
            )
        default:
            throw RosterEvidenceClientError.wire(.malformedResponse)
        }
    }

    private static func checkpointSequence(_ checkpointBytes: Data) throws -> UInt64 {
        let decoded = try RosterWire.decodeCanonical(checkpointBytes)
        guard case .map(let map) = decoded else {
            throw RosterEvidenceClientError.wire(.malformedResponse)
        }
        return try RosterWire.requireUInt(map, "checkpoint_sequence")
    }
}
