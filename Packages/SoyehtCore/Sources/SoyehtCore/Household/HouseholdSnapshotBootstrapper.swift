import CryptoKit
import Foundation

public enum HouseholdSnapshotCursor: Equatable, Sendable {
    case uint(UInt64)
    case bytes(Data)

    var uintValue: UInt64? {
        if case .uint(let value) = self { return value }
        return nil
    }
}

public struct HouseholdSnapshotBootstrapResult: Equatable, Sendable {
    public let householdId: String
    public let cursor: HouseholdSnapshotCursor?
    public let headEventHash: Data
    public let issuedAt: Date
    public let insertedRevocationCount: Int
    public let memberCount: Int
    public let skippedRevokedMachineCount: Int

    public init(
        householdId: String,
        cursor: HouseholdSnapshotCursor?,
        headEventHash: Data,
        issuedAt: Date,
        insertedRevocationCount: Int,
        memberCount: Int,
        skippedRevokedMachineCount: Int
    ) {
        self.householdId = householdId
        self.cursor = cursor
        self.headEventHash = headEventHash
        self.issuedAt = issuedAt
        self.insertedRevocationCount = insertedRevocationCount
        self.memberCount = memberCount
        self.skippedRevokedMachineCount = skippedRevokedMachineCount
    }
}

public struct HouseholdSnapshotBootstrapper: Sendable {
    public typealias SnapshotFetcher = @Sendable () async throws -> Data
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias AuthorizationProvider = @Sendable (_ method: String, _ pathAndQuery: String, _ body: Data) throws -> String
    public typealias NowProvider = @Sendable () -> Date

    public static let snapshotPath = "/api/v1/household/snapshot"
    private static let contentType = "application/cbor"
    private static let envelopeKeys: Set<String> = ["v", "snapshot", "signature"]
    private static let requiredBodyKeys: Set<String> = [
        "v",
        "hh_id",
        "machines",
        "crl",
        "head_event_hash",
        "issued_at",
    ]
    private static let knownBodyKeys: Set<String> = requiredBodyKeys.union([
        "as_of_cursor",
        "as_of_vc",
        "household",
        "people",
        "devices",
        "claws",
    ])
    private static let revocationKeys: Set<String> = [
        "subject_id",
        "revoked_at",
        "reason",
        "cascade",
        "signature",
    ]

    private let householdId: String
    private let householdPublicKey: Data
    private let crlStore: CRLStore
    private let membershipStore: HouseholdMembershipStore
    private let fetchSnapshot: SnapshotFetcher
    private let nowProvider: NowProvider

    public init(
        householdId: String,
        householdPublicKey: Data,
        crlStore: CRLStore,
        membershipStore: HouseholdMembershipStore,
        fetchSnapshot: @escaping SnapshotFetcher,
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        self.householdId = householdId
        self.householdPublicKey = householdPublicKey
        self.crlStore = crlStore
        self.membershipStore = membershipStore
        self.fetchSnapshot = fetchSnapshot
        self.nowProvider = nowProvider
    }

    public init(
        baseURL: URL,
        householdId: String,
        householdPublicKey: Data,
        crlStore: CRLStore,
        membershipStore: HouseholdMembershipStore,
        authorizationProvider: @escaping AuthorizationProvider,
        transport: @escaping TransportPerform = HouseholdSnapshotBootstrapper.urlSessionTransport(),
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        let (url, pathAndQuery) = Self.snapshotURL(baseURL: baseURL)
        self.init(
            householdId: householdId,
            householdPublicKey: householdPublicKey,
            crlStore: crlStore,
            membershipStore: membershipStore,
            fetchSnapshot: {
                let authorization: String
                do {
                    authorization = try authorizationProvider("GET", pathAndQuery, Data())
                } catch let error as MachineJoinError {
                    throw error
                } catch {
                    throw MachineJoinError.signingFailed
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
                request.setValue(authorization, forHTTPHeaderField: "Authorization")

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await transport(request)
                } catch let error as MachineJoinError {
                    throw error
                } catch {
                    throw MachineJoinError.networkDrop
                }
                guard let http = response as? HTTPURLResponse else {
                    throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
                }
                let returnedContentType = http.value(forHTTPHeaderField: "Content-Type")
                guard Self.isCBORContentType(returnedContentType) else {
                    throw MachineJoinError.protocolViolation(
                        detail: .wrongContentType(returned: returnedContentType)
                    )
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw try Self.decodeErrorEnvelope(data)
                }
                return data
            },
            nowProvider: nowProvider
        )
    }

    public static func urlSessionTransport(_ session: URLSession = .shared) -> TransportPerform {
        { request in try await session.data(for: request) }
    }

    @discardableResult
    public func bootstrap() async throws -> HouseholdSnapshotBootstrapResult {
        let data: Data
        do {
            data = try await fetchSnapshot()
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.networkDrop
        }

        let decoded = try Self.decodeSnapshotEnvelope(
            data,
            expectedHouseholdId: householdId,
            householdPublicKey: householdPublicKey,
            now: nowProvider()
        )

        let inserted = try await crlStore.seedFromSnapshot(
            decoded.revocations,
            snapshotCursor: decoded.cursor?.uintValue,
            now: nowProvider()
        )
        await membershipStore.replaceAll(with: decoded.members)

        return HouseholdSnapshotBootstrapResult(
            householdId: decoded.householdId,
            cursor: decoded.cursor,
            headEventHash: decoded.headEventHash,
            issuedAt: decoded.issuedAt,
            insertedRevocationCount: inserted,
            memberCount: decoded.members.count,
            skippedRevokedMachineCount: decoded.skippedRevokedMachineCount
        )
    }

    private struct DecodedSnapshot: Sendable {
        let householdId: String
        let cursor: HouseholdSnapshotCursor?
        let headEventHash: Data
        let issuedAt: Date
        let revocations: [RevocationEntry]
        let members: [HouseholdMember]
        let skippedRevokedMachineCount: Int
    }

    private static func decodeSnapshotEnvelope(
        _ data: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        now: Date
    ) throws -> DecodedSnapshot {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard case .map(let envelope) = decoded,
              HouseholdCBOR.encode(.map(envelope)) == data else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try requireExactKeys(envelope, expected: envelopeKeys)
        let envelopeVersion = try envelope.snapshotRequiredUInt("v")
        guard envelopeVersion == 1 else {
            throw MachineJoinError.protocolViolation(
                detail: .unsupportedErrorVersion(envelopeVersion)
            )
        }
        let signature = try envelope.snapshotRequiredBytes("signature")
        guard signature.count == 64 else {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
        let body = try envelope.snapshotRequiredMap("snapshot")
        let bodyBytes = HouseholdCBOR.encode(.map(body))
        try verifySignature(
            signature: signature,
            signingBytes: bodyBytes,
            householdPublicKey: householdPublicKey
        )
        return try decodeSnapshotBody(
            body,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey,
            now: now
        )
    }

    private static func decodeSnapshotBody(
        _ body: [String: HouseholdCBORValue],
        expectedHouseholdId: String,
        householdPublicKey: Data,
        now: Date
    ) throws -> DecodedSnapshot {
        try requireRequiredKeys(body, required: requiredBodyKeys)
        try requireKnownKeys(body, known: knownBodyKeys)
        guard body["as_of_cursor"] != nil || body["as_of_vc"] != nil else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }

        let version = try body.snapshotRequiredUInt("v")
        guard version == 1 else {
            throw MachineJoinError.protocolViolation(detail: .unsupportedErrorVersion(version))
        }
        let snapshotHouseholdId = try body.snapshotRequiredText("hh_id")
        guard snapshotHouseholdId == expectedHouseholdId else {
            throw MachineJoinError.hhMismatch
        }
        let cursor = try decodeCursor(from: body["as_of_cursor"])
        let headEventHash = try body.snapshotRequiredBytes("head_event_hash")
        guard headEventHash.count == 32 else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let issuedAtSeconds = try body.snapshotRequiredUInt("issued_at")
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedAtSeconds))

        let revocationValues = try body.snapshotRequiredArray("crl")
        let revocations = try revocationValues.map {
            try decodeRevocationEntry($0, householdPublicKey: householdPublicKey)
        }
        let revokedIds = Set(revocations.map(\.subjectId))

        let machineValues = try body.snapshotRequiredArray("machines")
        var members: [HouseholdMember] = []
        var skippedRevoked = 0
        for machineValue in machineValues {
            let certBytes = try machineCertBytes(from: machineValue)
            let cert: MachineCert
            do {
                cert = try MachineCert(cbor: certBytes)
                try MachineCertValidator.validate(
                    cert: cert,
                    expectedHouseholdId: expectedHouseholdId,
                    householdPublicKey: householdPublicKey,
                    isRevoked: { revokedIds.contains($0) },
                    now: now
                )
                members.append(HouseholdMember(from: cert))
            } catch MachineCertError.revoked {
                skippedRevoked += 1
            } catch let error as MachineCertError {
                throw MachineJoinError(error)
            }
        }

        return DecodedSnapshot(
            householdId: snapshotHouseholdId,
            cursor: cursor,
            headEventHash: headEventHash,
            issuedAt: issuedAt,
            revocations: revocations,
            members: members,
            skippedRevokedMachineCount: skippedRevoked
        )
    }

    private static func decodeRevocationEntry(
        _ value: HouseholdCBORValue,
        householdPublicKey: Data
    ) throws -> RevocationEntry {
        guard case .map(let map) = value else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try requireExactKeys(map, expected: revocationKeys)
        let signature = try map.snapshotRequiredBytes("signature")
        guard signature.count == 64 else {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
        try verifySignature(
            signature: signature,
            signingBytes: HouseholdCBOR.encode(.map(map.filter { $0.key != "signature" })),
            householdPublicKey: householdPublicKey
        )

        let subjectId = try map.snapshotRequiredText("subject_id")
        let reason = try map.snapshotRequiredText("reason")
        let cascadeText = try map.snapshotRequiredText("cascade")
        guard !subjectId.isEmpty, !reason.isEmpty else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard let cascade = RevocationEntry.Cascade(rawValue: cascadeText) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let revokedAt = try map.snapshotRequiredUInt("revoked_at")
        return RevocationEntry(
            subjectId: subjectId,
            revokedAt: Date(timeIntervalSince1970: TimeInterval(revokedAt)),
            reason: reason,
            cascade: cascade,
            signature: signature
        )
    }

    private static func machineCertBytes(from value: HouseholdCBORValue) throws -> Data {
        switch value {
        case .map(let map):
            return HouseholdCBOR.encode(.map(map))
        case .bytes(let bytes):
            return bytes
        default:
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    private static func decodeCursor(from value: HouseholdCBORValue?) throws -> HouseholdSnapshotCursor? {
        guard let value else { return nil }
        switch value {
        case .unsigned(let cursor):
            return .uint(cursor)
        case .bytes(let cursor):
            return .bytes(cursor)
        default:
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    private static func verifySignature(
        signature: Data,
        signingBytes: Data,
        householdPublicKey: Data
    ) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(signature, for: signingBytes) else {
                throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
            }
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
    }

    private static func decodeErrorEnvelope(_ data: Data) throws -> MachineJoinError {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            return .protocolViolation(detail: .malformedErrorBody)
        }
        guard case .map(let map) = decoded else {
            return .protocolViolation(detail: .malformedErrorBody)
        }
        guard let versionValue = map["v"], case .unsigned(let version) = versionValue else {
            return .protocolViolation(detail: .missingErrorEnvelopeField)
        }
        guard version == 1 else {
            return .protocolViolation(detail: .unsupportedErrorVersion(version))
        }
        guard let errorValue = map["error"], case .text(let code) = errorValue else {
            return .protocolViolation(detail: .missingErrorEnvelopeField)
        }
        var message: String?
        if let messageValue = map["message"] {
            guard case .text(let text) = messageValue else {
                return .protocolViolation(detail: .malformedErrorBody)
            }
            message = text
        }
        return .serverError(code: code, message: message)
    }

    private static func snapshotURL(baseURL: URL) -> (URL, String) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty
            ? snapshotPath
            : "/\(basePath)\(snapshotPath)"
        components.query = nil
        return (components.url!, components.path)
    }

    private static func isCBORContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == contentType
    }

    private static func requireExactKeys(
        _ map: [String: HouseholdCBORValue],
        expected: Set<String>
    ) throws {
        let keys = Set(map.keys)
        guard keys == expected else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    private static func requireRequiredKeys(
        _ map: [String: HouseholdCBORValue],
        required: Set<String>
    ) throws {
        guard required.isSubset(of: Set(map.keys)) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    private static func requireKnownKeys(
        _ map: [String: HouseholdCBORValue],
        known: Set<String>
    ) throws {
        guard Set(map.keys).subtracting(known).isEmpty else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func snapshotRequiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func snapshotRequiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func snapshotRequiredUInt(_ key: String) throws -> UInt64 {
        guard case .unsigned(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func snapshotRequiredArray(_ key: String) throws -> [HouseholdCBORValue] {
        guard case .array(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func snapshotRequiredMap(_ key: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }
}
