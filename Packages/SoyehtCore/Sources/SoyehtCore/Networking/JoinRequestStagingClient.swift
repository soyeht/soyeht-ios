import Foundation

public struct JoinRequestAccepted: Equatable, Sendable {
    public let ownerEventCursor: UInt64
    public let expiry: UInt64

    public init(ownerEventCursor: UInt64, expiry: UInt64) {
        self.ownerEventCursor = ownerEventCursor
        self.expiry = expiry
    }
}

public struct OwnerApprovalAck: Equatable, Sendable {
    public let machineCertHash: Data

    public init(machineCertHash: Data) {
        self.machineCertHash = machineCertHash
    }
}

public struct JoinRequestStagingClient: Sendable {
    public typealias AuthorizationProvider = @Sendable (_ method: String, _ pathAndQuery: String, _ body: Data) throws -> String
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let joinRequestPath = "/api/v1/household/join-request"
    fileprivate static let contentType = "application/cbor"

    // The join-request and owner-approval acks are framed by `v: uint`. Both
    // contracts are intentionally fail-closed: any key outside the known
    // allowlist fails decoding, forcing theyos to bump the envelope `v`
    // when shape changes (mirroring the `as_of_vc` posture in
    // `HouseholdSnapshotBootstrapper`). Splitting required vs. known up-front
    // makes the eventual relaxation a one-line allowlist add.
    fileprivate static let acceptedRequiredKeys: Set<String> = ["v", "owner_event_cursor", "expiry"]
    fileprivate static let acceptedKnownKeys: Set<String> = acceptedRequiredKeys
    fileprivate static let approvalAckRequiredKeys: Set<String> = ["v", "machine_cert_hash"]
    fileprivate static let approvalAckKnownKeys: Set<String> = approvalAckRequiredKeys

    private let baseURL: URL
    private let authorizationProvider: AuthorizationProvider
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        authorizationProvider: @escaping AuthorizationProvider,
        transport: @escaping TransportPerform = JoinRequestStagingClient.urlSessionTransport()
    ) {
        self.baseURL = baseURL
        self.authorizationProvider = authorizationProvider
        self.perform = transport
    }

    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = JoinRequestStagingClient.urlSessionTransport()
    ) {
        self.init(
            baseURL: baseURL,
            authorizationProvider: { method, pathAndQuery, body in
                try popSigner.authorization(
                    method: method,
                    pathAndQuery: pathAndQuery,
                    body: body
                ).authorizationHeader
            },
            transport: transport
        )
    }

    public static func urlSessionTransport(_ session: URLSession = .shared) -> TransportPerform {
        { request in try await session.data(for: request) }
    }

    public func submit(_ envelope: JoinRequestEnvelope) async throws -> JoinRequestAccepted {
        let body = HouseholdCBOR.joinRequest(envelope)
        let (url, pathAndQuery) = Self.endpointURL(baseURL: baseURL, path: Self.joinRequestPath)
        let authorization = try mapSigningError {
            try authorizationProvider("POST", pathAndQuery, body)
        }
        let data = try await send(method: "POST", url: url, body: body, authorization: authorization)
        return try Self.decodeJoinRequestAccepted(data)
    }

    private func send(method: String, url: URL, body: Data, authorization: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard Self.isCBORContentType(contentType) else {
            throw MachineJoinError.protocolViolation(detail: .wrongContentType(returned: contentType))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try Self.decodeErrorEnvelope(data)
        }
        return data
    }

    private static func decodeJoinRequestAccepted(_ data: Data) throws -> JoinRequestAccepted {
        guard case .map(let map) = try decodeCanonical(data) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try HouseholdCBORMapKeys.requireRequired(map, keys: acceptedRequiredKeys)
        try HouseholdCBORMapKeys.requireKnown(map, keys: acceptedKnownKeys)
        guard case .unsigned(1) = map["v"],
              case .unsigned(let cursor) = map["owner_event_cursor"],
              case .unsigned(let expiry) = map["expiry"] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return JoinRequestAccepted(ownerEventCursor: cursor, expiry: expiry)
    }

    fileprivate static func endpointURL(baseURL: URL, path: String) -> (URL, String) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.percentEncodedQuery = nil
        components.fragment = nil
        return (components.url!, components.percentEncodedPath)
    }

    fileprivate static func decodeCanonical(_ data: Data) throws -> HouseholdCBORValue {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard HouseholdCBOR.encode(decoded) == data else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return decoded
    }

    fileprivate static func decodeErrorEnvelope(_ data: Data) throws -> MachineJoinError {
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

    fileprivate static func isCBORContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == contentType
    }

    private func mapSigningError(_ operation: () throws -> String) throws -> String {
        do {
            return try operation()
        } catch let error as MachineJoinError {
            throw error
        } catch HouseholdPoPError.biometryCanceled {
            throw MachineJoinError.biometricCancel
        } catch {
            throw MachineJoinError.signingFailed
        }
    }
}

public struct OwnerApprovalClient: Sendable {
    public typealias AuthorizationProvider = @Sendable (_ method: String, _ pathAndQuery: String, _ body: Data) throws -> String
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let authorizationProvider: AuthorizationProvider
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        authorizationProvider: @escaping AuthorizationProvider,
        transport: @escaping TransportPerform = JoinRequestStagingClient.urlSessionTransport()
    ) {
        self.baseURL = baseURL
        self.authorizationProvider = authorizationProvider
        self.perform = transport
    }

    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = JoinRequestStagingClient.urlSessionTransport()
    ) {
        self.init(
            baseURL: baseURL,
            authorizationProvider: { method, pathAndQuery, body in
                try popSigner.authorization(
                    method: method,
                    pathAndQuery: pathAndQuery,
                    body: body
                ).authorizationHeader
            },
            transport: transport
        )
    }

    public func approve(_ authorization: OperatorAuthorizationResult) async throws -> OwnerApprovalAck {
        let path = "/api/v1/household/owner-events/\(authorization.cursor)/approve"
        let (url, pathAndQuery) = JoinRequestStagingClient.endpointURL(baseURL: baseURL, path: path)
        let header: String
        do {
            header = try authorizationProvider("POST", pathAndQuery, authorization.outerBody)
        } catch let error as MachineJoinError {
            throw error
        } catch HouseholdPoPError.biometryCanceled {
            throw MachineJoinError.biometricCancel
        } catch {
            throw MachineJoinError.signingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(JoinRequestStagingClient.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(JoinRequestStagingClient.contentType, forHTTPHeaderField: "Accept")
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.httpBody = authorization.outerBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard JoinRequestStagingClient.isCBORContentType(contentType) else {
            throw MachineJoinError.protocolViolation(detail: .wrongContentType(returned: contentType))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try JoinRequestStagingClient.decodeErrorEnvelope(data)
        }
        return try Self.decodeAck(data)
    }

    private static func decodeAck(_ data: Data) throws -> OwnerApprovalAck {
        guard case .map(let map) = try JoinRequestStagingClient.decodeCanonical(data) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try HouseholdCBORMapKeys.requireRequired(map, keys: JoinRequestStagingClient.approvalAckRequiredKeys)
        try HouseholdCBORMapKeys.requireKnown(map, keys: JoinRequestStagingClient.approvalAckKnownKeys)
        guard case .unsigned(1) = map["v"],
              case .bytes(let hash) = map["machine_cert_hash"],
              hash.count == 32 else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return OwnerApprovalAck(machineCertHash: hash)
    }
}
