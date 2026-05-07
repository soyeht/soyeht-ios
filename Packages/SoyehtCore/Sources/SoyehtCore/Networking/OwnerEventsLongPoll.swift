import Foundation

public actor OwnerEventsLongPoll {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias AuthorizationProvider = @Sendable (_ method: String, _ pathAndQuery: String, _ body: Data) throws -> String
    public typealias EventVerifier = @Sendable (OwnerEvent) async throws -> Void
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias NowProvider = @Sendable () -> Date

    public struct Configuration: Sendable, Equatable {
        public var longPollTimeout: TimeInterval
        public var initialReconnectBackoff: TimeInterval
        public var maxReconnectBackoff: TimeInterval
        public var reconnectBackoffMultiplier: Double

        public init(
            longPollTimeout: TimeInterval = 45,
            initialReconnectBackoff: TimeInterval = 1,
            maxReconnectBackoff: TimeInterval = 60,
            reconnectBackoffMultiplier: Double = 2
        ) {
            self.longPollTimeout = longPollTimeout
            self.initialReconnectBackoff = initialReconnectBackoff
            self.maxReconnectBackoff = maxReconnectBackoff
            self.reconnectBackoffMultiplier = reconnectBackoffMultiplier
        }
    }

    public struct OwnerEvent: Sendable, Equatable {
        public let cursor: UInt64
        public let type: String
        public let timestamp: UInt64
        public let issuerMachineId: String
        public let payload: [String: HouseholdCBORValue]
        public let signature: Data

        public init(
            cursor: UInt64,
            type: String,
            timestamp: UInt64,
            issuerMachineId: String,
            payload: [String: HouseholdCBORValue],
            signature: Data
        ) {
            self.cursor = cursor
            self.type = type
            self.timestamp = timestamp
            self.issuerMachineId = issuerMachineId
            self.payload = payload
            self.signature = signature
        }
    }

    public struct PollResult: Sendable, Equatable {
        public let previousCursor: UInt64
        public let cursor: UInt64
        public let timedOut: Bool
        public let enqueuedJoinRequests: [JoinRequestEnvelope]
        public let duplicateJoinRequests: [JoinRequestEnvelope]
        public let acknowledgedMachinePublicKeys: [Data]

        public init(
            previousCursor: UInt64,
            cursor: UInt64,
            timedOut: Bool,
            enqueuedJoinRequests: [JoinRequestEnvelope],
            duplicateJoinRequests: [JoinRequestEnvelope],
            acknowledgedMachinePublicKeys: [Data]
        ) {
            self.previousCursor = previousCursor
            self.cursor = cursor
            self.timedOut = timedOut
            self.enqueuedJoinRequests = enqueuedJoinRequests
            self.duplicateJoinRequests = duplicateJoinRequests
            self.acknowledgedMachinePublicKeys = acknowledgedMachinePublicKeys
        }
    }

    private static let contentType = "application/cbor"
    private static let ownerEventsPath = "/api/v1/household/owner-events"
    private static let responseKeys: Set<String> = ["v", "events", "next_cursor"]
    private static let eventKeys: Set<String> = ["v", "cursor", "ts", "type", "payload", "issuer_m_id", "signature"]
    private static let joinRequestPayloadKeys: Set<String> = ["join_request_cbor", "fingerprint", "expiry"]
    private static let joinRequestKeys: Set<String> = ["v", "m_pub", "nonce", "hostname", "platform", "addr", "transport", "challenge_sig"]

    private let baseURL: URL
    private let householdId: String
    private let queue: JoinRequestQueue
    private let wordlist: BIP39Wordlist
    private let configuration: Configuration
    private let authorizationProvider: AuthorizationProvider
    private let eventVerifier: EventVerifier
    private let perform: TransportPerform
    private let sleeper: Sleeper
    private let nowProvider: NowProvider
    private var lastAppliedCursor: UInt64

    public init(
        baseURL: URL,
        householdId: String,
        queue: JoinRequestQueue,
        wordlist: BIP39Wordlist,
        initialCursor: UInt64 = 0,
        configuration: Configuration = Configuration(),
        authorizationProvider: @escaping AuthorizationProvider,
        eventVerifier: @escaping EventVerifier,
        transport: @escaping TransportPerform = OwnerEventsLongPoll.urlSessionTransport(),
        sleeper: @escaping Sleeper = { seconds in
            try await OwnerEventsLongPoll.sleep(seconds: seconds)
        },
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        self.baseURL = baseURL
        self.householdId = householdId
        self.queue = queue
        self.wordlist = wordlist
        self.lastAppliedCursor = initialCursor
        self.configuration = configuration
        self.authorizationProvider = authorizationProvider
        self.eventVerifier = eventVerifier
        self.perform = transport
        self.sleeper = sleeper
        self.nowProvider = nowProvider
    }

    public init(
        baseURL: URL,
        householdId: String,
        queue: JoinRequestQueue,
        wordlist: BIP39Wordlist,
        initialCursor: UInt64 = 0,
        configuration: Configuration = Configuration(),
        popSigner: HouseholdPoPSigner,
        eventVerifier: @escaping EventVerifier,
        transport: @escaping TransportPerform = OwnerEventsLongPoll.urlSessionTransport(),
        sleeper: @escaping Sleeper = { seconds in
            try await OwnerEventsLongPoll.sleep(seconds: seconds)
        },
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        self.init(
            baseURL: baseURL,
            householdId: householdId,
            queue: queue,
            wordlist: wordlist,
            initialCursor: initialCursor,
            configuration: configuration,
            authorizationProvider: { method, pathAndQuery, body in
                try popSigner.authorization(
                    method: method,
                    pathAndQuery: pathAndQuery,
                    body: body
                ).authorizationHeader
            },
            eventVerifier: eventVerifier,
            transport: transport,
            sleeper: sleeper,
            nowProvider: nowProvider
        )
    }

    public static func urlSessionTransport(_ session: URLSession = .shared) -> TransportPerform {
        { request in try await session.data(for: request) }
    }

    public static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    public func currentCursor() -> UInt64 {
        lastAppliedCursor
    }

    @discardableResult
    public func pollOnce(now: Date? = nil) async throws -> PollResult {
        let previousCursor = lastAppliedCursor
        let (url, pathAndQuery) = Self.ownerEventsURL(
            baseURL: baseURL,
            cursor: previousCursor
        )
        let authorization: String
        do {
            authorization = try authorizationProvider("GET", pathAndQuery, Data())
        } catch let error as MachineJoinError {
            throw error
        } catch HouseholdPoPError.biometryCanceled {
            throw MachineJoinError.biometricCancel
        } catch {
            throw MachineJoinError.signingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.longPollTimeout
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

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

        if http.statusCode == 204 {
            guard data.isEmpty else {
                throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
            }
            return PollResult(
                previousCursor: previousCursor,
                cursor: previousCursor,
                timedOut: true,
                enqueuedJoinRequests: [],
                duplicateJoinRequests: [],
                acknowledgedMachinePublicKeys: []
            )
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

        let processed = try await processEventsResponse(
            data,
            previousCursor: previousCursor,
            now: now ?? nowProvider()
        )
        lastAppliedCursor = processed.cursor
        return processed
    }

    public func runForeground(
        maxPolls: Int? = nil,
        maxTransportReconnects: Int? = nil,
        onResult: @escaping @Sendable (PollResult) async -> Void = { _ in }
    ) async throws {
        var completedPolls = 0
        var consecutiveDrops = 0
        while !Task.isCancelled, maxPolls.map({ completedPolls < $0 }) ?? true {
            do {
                let result = try await pollOnce()
                consecutiveDrops = 0
                completedPolls += 1
                await onResult(result)
            } catch MachineJoinError.networkDrop {
                if let maxTransportReconnects, consecutiveDrops >= maxTransportReconnects {
                    throw MachineJoinError.networkDrop
                }
                let delay = reconnectDelay(forAttempt: consecutiveDrops)
                consecutiveDrops += 1
                try await sleeper(delay)
            }
        }
    }

    private func processEventsResponse(
        _ data: Data,
        previousCursor: UInt64,
        now: Date
    ) async throws -> PollResult {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard case .map(let map) = decoded,
              HouseholdCBOR.encode(.map(map)) == data else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try Self.requireExactKeys(map, expected: Self.responseKeys)
        let version = try map.ownerEventsRequiredUInt("v")
        guard version == 1 else {
            throw MachineJoinError.protocolViolation(
                detail: .unsupportedErrorVersion(version)
            )
        }
        let nextCursor = try map.ownerEventsRequiredUInt("next_cursor")
        guard nextCursor >= previousCursor else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let eventValues = try map.ownerEventsRequiredArray("events")

        var enqueued: [JoinRequestEnvelope] = []
        var duplicates: [JoinRequestEnvelope] = []
        var acknowledged: [Data] = []

        for eventValue in eventValues {
            let event = try Self.decodeOwnerEvent(eventValue)
            do {
                try await eventVerifier(event)
            } catch let error as MachineJoinError {
                throw error
            } catch let error as MachineCertError {
                throw MachineJoinError(error)
            } catch {
                throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
            }

            switch event.type {
            case "join-request":
                let envelope = try decodeJoinRequestEnvelope(from: event.payload, now: now)
                let inserted = await queue.enqueue(envelope)
                if inserted {
                    enqueued.append(envelope)
                } else {
                    duplicates.append(envelope)
                }
            case "machine-joined", "join-cancelled":
                if let machinePublicKey = try Self.optionalMachinePublicKey(from: event.payload) {
                    _ = await queue.acknowledgeByMachine(publicKey: machinePublicKey)
                    acknowledged.append(machinePublicKey)
                }
            default:
                break
            }
        }

        return PollResult(
            previousCursor: previousCursor,
            cursor: nextCursor,
            timedOut: false,
            enqueuedJoinRequests: enqueued,
            duplicateJoinRequests: duplicates,
            acknowledgedMachinePublicKeys: acknowledged
        )
    }

    private func decodeJoinRequestEnvelope(
        from payload: [String: HouseholdCBORValue],
        now: Date
    ) throws -> JoinRequestEnvelope {
        try Self.requireExactKeys(payload, expected: Self.joinRequestPayloadKeys)
        let fingerprint = try payload.ownerEventsRequiredText("fingerprint")
        let expiry = try payload.ownerEventsRequiredUInt("expiry")
        let joinRequestCBOR = try payload.ownerEventsRequiredBytes("join_request_cbor")
        guard Date(timeIntervalSince1970: TimeInterval(expiry)) > now else {
            throw MachineJoinError.qrExpired
        }

        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(joinRequestCBOR)
        } catch {
            throw MachineJoinError.qrInvalid(reason: .schemaUnsupported(version: nil))
        }
        guard case .map(let map) = decoded,
              HouseholdCBOR.encode(.map(map)) == joinRequestCBOR else {
            throw MachineJoinError.qrInvalid(reason: .schemaUnsupported(version: nil))
        }
        try Self.requireExactKeys(
            map,
            expected: Self.joinRequestKeys,
            missingFieldError: { .qrInvalid(reason: .missingField(name: $0)) }
        )

        let version = try map.ownerEventsRequiredUInt("v")
        guard version == 1 else {
            throw MachineJoinError.qrInvalid(
                reason: .schemaUnsupported(version: String(version))
            )
        }

        let machinePublicKey = try map.ownerEventsRequiredBytes("m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw MachineJoinError.qrInvalid(reason: .invalidPublicKey)
        }

        let nonce = try map.ownerEventsRequiredBytes("nonce")
        guard nonce.count == 32 else {
            throw MachineJoinError.qrInvalid(reason: .invalidNonce)
        }

        let hostname = try map.ownerEventsRequiredText("hostname")
        guard !hostname.isEmpty, hostname.utf8.count <= 64 else {
            throw MachineJoinError.qrInvalid(reason: .invalidHostname)
        }

        let platform = try map.ownerEventsRequiredText("platform")
        guard PairMachinePlatform(rawValue: platform) != nil else {
            throw MachineJoinError.qrInvalid(
                reason: .unsupportedPlatform(value: platform)
            )
        }

        let transport = try map.ownerEventsRequiredText("transport")
        guard PairMachineTransport(rawValue: transport) != nil else {
            throw MachineJoinError.qrInvalid(
                reason: .unsupportedTransport(value: transport)
            )
        }

        let address = try map.ownerEventsRequiredText("addr")
        guard !address.isEmpty else {
            throw MachineJoinError.qrInvalid(reason: .invalidAddress)
        }

        let challengeSignature = try map.ownerEventsRequiredBytes("challenge_sig")
        guard challengeSignature.count == PairMachineQR.challengeSignatureLength else {
            throw MachineJoinError.qrInvalid(reason: .challengeSigInvalid)
        }
        do {
            try PairMachineQR.verifyChallengeSignature(
                machinePublicKey: machinePublicKey,
                nonce: nonce,
                hostname: hostname,
                platform: platform,
                signature: challengeSignature
            )
        } catch let error as PairMachineQRError {
            throw MachineJoinError(error)
        } catch {
            throw MachineJoinError.qrInvalid(reason: .challengeSigInvalid)
        }

        let derivedFingerprint: OperatorFingerprint
        do {
            derivedFingerprint = try OperatorFingerprint.derive(
                machinePublicKey: machinePublicKey,
                wordlist: wordlist
            )
        } catch {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard derivedFingerprint.words.joined(separator: " ") == fingerprint else {
            throw MachineJoinError.derivationDrift
        }

        return JoinRequestEnvelope(
            householdId: householdId,
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            rawHostname: hostname,
            rawPlatform: platform,
            candidateAddress: address,
            ttlUnix: expiry,
            challengeSignature: challengeSignature,
            transportOrigin: .bonjourShortcut,
            receivedAt: now
        )
    }

    private func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let multiplier = pow(
            configuration.reconnectBackoffMultiplier,
            Double(max(0, attempt))
        )
        return min(
            configuration.maxReconnectBackoff,
            configuration.initialReconnectBackoff * multiplier
        )
    }

    private static func ownerEventsURL(baseURL: URL, cursor: UInt64) -> (URL, String) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty
            ? ownerEventsPath
            : "/\(basePath)\(ownerEventsPath)"
        let cursorBytes = HouseholdCBOR.encode(.unsigned(cursor))
        components.queryItems = [
            URLQueryItem(
                name: "since",
                value: cursorBytes.soyehtBase64URLEncodedString()
            ),
        ]
        let pathAndQuery = "\(components.path)?\(components.percentEncodedQuery ?? "")"
        return (components.url!, pathAndQuery)
    }

    private static func decodeOwnerEvent(_ value: HouseholdCBORValue) throws -> OwnerEvent {
        guard case .map(let map) = value else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try requireExactKeys(map, expected: eventKeys)
        let version = try map.ownerEventsRequiredUInt("v")
        guard version == 1 else {
            throw MachineJoinError.protocolViolation(
                detail: .unsupportedErrorVersion(version)
            )
        }
        let signature = try map.ownerEventsRequiredBytes("signature")
        guard signature.count == PairMachineQR.challengeSignatureLength else {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
        return OwnerEvent(
            cursor: try map.ownerEventsRequiredUInt("cursor"),
            type: try map.ownerEventsRequiredText("type"),
            timestamp: try map.ownerEventsRequiredUInt("ts"),
            issuerMachineId: try map.ownerEventsRequiredText("issuer_m_id"),
            payload: try map.ownerEventsRequiredMap("payload"),
            signature: signature
        )
    }

    private static func optionalMachinePublicKey(
        from payload: [String: HouseholdCBORValue]
    ) throws -> Data? {
        guard let value = payload["m_pub"] else { return nil }
        guard case .bytes(let machinePublicKey) = value else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw MachineJoinError.qrInvalid(reason: .invalidPublicKey)
        }
        return machinePublicKey
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

    private static func requireExactKeys(
        _ map: [String: HouseholdCBORValue],
        expected: Set<String>,
        missingFieldError: ((String) -> MachineJoinError)? = nil
    ) throws {
        let keys = Set(map.keys)
        let missing = expected.subtracting(keys)
        if let missingField = missing.sorted().first {
            throw missingFieldError?(missingField)
                ?? MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard keys.subtracting(expected).isEmpty else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    private static func isCBORContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == contentType
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func ownerEventsRequiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func ownerEventsRequiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func ownerEventsRequiredUInt(_ key: String) throws -> UInt64 {
        guard case .unsigned(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func ownerEventsRequiredArray(_ key: String) throws -> [HouseholdCBORValue] {
        guard case .array(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func ownerEventsRequiredMap(_ key: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }
}
