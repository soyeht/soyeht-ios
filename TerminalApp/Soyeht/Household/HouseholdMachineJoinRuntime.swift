import CryptoKit
import Foundation
import SoyehtCore

@MainActor
final class HouseholdMachineJoinRuntime: ObservableObject {
    @Published private(set) var pendingRequests: [JoinRequestQueue.PendingRequest] = []
    @Published private(set) var lifecycleError: MachineJoinError?

    let queue: JoinRequestQueue

    private let keyProvider: any OwnerIdentityKeyCreating
    private let wordlist: BIP39Wordlist
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private let membershipStore: HouseholdMembershipStore
    private let crlStore: CRLStore?

    private var activeHouseholdId: String?
    private var queueTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var ownerEventsCoordinator: OwnerEventsCoordinator?
    private var gossipSocket: HouseholdGossipSocket?
    private var gossipTask: Task<Void, Never>?

    init(
        queue: JoinRequestQueue = JoinRequestQueue(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        wordlist: BIP39Wordlist = (try! BIP39Wordlist()),
        session: URLSession = .shared,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queue = queue
        self.keyProvider = keyProvider
        self.wordlist = wordlist
        self.session = session
        self.nowProvider = nowProvider
        self.membershipStore = HouseholdMembershipStore()
        self.crlStore = try? CRLStore()
        observeQueue()
    }

    deinit {
        queueTask?.cancel()
        activationTask?.cancel()
        gossipTask?.cancel()
    }

    func activate(_ household: ActiveHouseholdState) {
        guard activeHouseholdId != household.householdId else {
            ownerEventsCoordinator?.enterForeground()
            return
        }
        stop()
        activeHouseholdId = household.householdId
        lifecycleError = nil
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let crlStore = try self.requireCRLStore()
                let ownerIdentity = try self.loadOwnerIdentity(for: household)
                let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: self.nowProvider)

                let snapshot = HouseholdSnapshotBootstrapper(
                    baseURL: household.endpoint,
                    householdId: household.householdId,
                    householdPublicKey: household.householdPublicKey,
                    crlStore: crlStore,
                    membershipStore: self.membershipStore,
                    authorizationProvider: { method, pathAndQuery, body in
                        try popSigner.authorization(
                            method: method,
                            pathAndQuery: pathAndQuery,
                            body: body
                        ).authorizationHeader
                    },
                    transport: HouseholdSnapshotBootstrapper.urlSessionTransport(self.session),
                    nowProvider: self.nowProvider
                )
                _ = try await snapshot.bootstrap()

                self.startGossip(household: household, popSigner: popSigner, crlStore: crlStore)
                self.startOwnerEvents(household: household, popSigner: popSigner)
            } catch let error as MachineJoinError {
                self.lifecycleError = error
            } catch {
                self.lifecycleError = .networkDrop
            }
        }
    }

    func stop() {
        activationTask?.cancel()
        activationTask = nil
        ownerEventsCoordinator?.stop()
        ownerEventsCoordinator = nil
        gossipTask?.cancel()
        gossipTask = nil
        Task { [gossipSocket] in
            await gossipSocket?.cancel()
        }
        gossipSocket = nil
        activeHouseholdId = nil
    }

    func enterForeground() {
        ownerEventsCoordinator?.enterForeground()
    }

    func enterBackground() {
        ownerEventsCoordinator?.enterBackground()
    }

    func stageScannedMachineJoin(
        _ envelope: JoinRequestEnvelope,
        household: ActiveHouseholdState
    ) async throws {
        let ownerIdentity = try loadOwnerIdentity(for: household)
        let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: nowProvider)
        let client = JoinRequestStagingClient(
            baseURL: household.endpoint,
            popSigner: popSigner,
            transport: JoinRequestStagingClient.urlSessionTransport(session)
        )
        let accepted = try await client.submit(envelope)
        let staged = envelope.withTTLUnix(accepted.expiry)
        _ = await queue.enqueue(staged, cursor: accepted.ownerEventCursor)
        await refreshPendingRequests()
    }

    func makeViewModel(
        for request: JoinRequestQueue.PendingRequest,
        household: ActiveHouseholdState
    ) throws -> JoinRequestConfirmationViewModel {
        try JoinRequestConfirmationViewModel(
            envelope: request.envelope,
            cursor: request.cursor,
            queue: queue,
            wordlist: wordlist,
            nowProvider: nowProvider,
            signAction: { [keyProvider, nowProvider] envelope, cursor in
                let ownerIdentity = try keyProvider.loadOwnerIdentity(
                    keyReference: household.ownerKeyReference,
                    publicKey: household.ownerPublicKey
                )
                return try OperatorAuthorizationSigner().sign(
                    envelope: envelope,
                    cursor: cursor,
                    ownerIdentity: ownerIdentity,
                    localHouseholdId: household.householdId,
                    now: nowProvider()
                )
            },
            submitAction: { [keyProvider, nowProvider, session] _, authorization in
                let ownerIdentity = try keyProvider.loadOwnerIdentity(
                    keyReference: household.ownerKeyReference,
                    publicKey: household.ownerPublicKey
                )
                let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: nowProvider)
                let client = OwnerApprovalClient(
                    baseURL: household.endpoint,
                    popSigner: popSigner,
                    transport: JoinRequestStagingClient.urlSessionTransport(session)
                )
                _ = try await client.approve(authorization)
            }
        )
    }

    private func observeQueue() {
        queueTask?.cancel()
        queueTask = Task { [weak self, queue, nowProvider] in
            for await _ in await queue.events() {
                let requests = await queue.pendingRequests(now: nowProvider())
                await MainActor.run {
                    self?.pendingRequests = requests
                }
            }
        }
    }

    private func refreshPendingRequests() async {
        pendingRequests = await queue.pendingRequests(now: nowProvider())
    }

    private func requireCRLStore() throws -> CRLStore {
        guard let crlStore else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return crlStore
    }

    private func loadOwnerIdentity(for household: ActiveHouseholdState) throws -> any OwnerIdentitySigning {
        do {
            return try keyProvider.loadOwnerIdentity(
                keyReference: household.ownerKeyReference,
                publicKey: household.ownerPublicKey
            )
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.signingFailed
        }
    }

    private func startOwnerEvents(
        household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner
    ) {
        let poller = OwnerEventsLongPoll(
            baseURL: household.endpoint,
            householdId: household.householdId,
            queue: queue,
            wordlist: wordlist,
            popSigner: popSigner,
            eventVerifier: { [membershipStore] event in
                try await Self.verifyOwnerEvent(event, membershipStore: membershipStore)
            },
            transport: OwnerEventsLongPoll.urlSessionTransport(session),
            nowProvider: nowProvider
        )
        let coordinator = OwnerEventsCoordinator(longPoll: poller)
        ownerEventsCoordinator = coordinator
        coordinator.enterForeground()
    }

    private func startGossip(
        household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner,
        crlStore: CRLStore
    ) {
        let initialCursor = UserDefaultsHouseholdGossipCursorStore()
            .loadCursor(for: household.householdId)
        let socket = HouseholdGossipSocket(
            initialCursor: initialCursor,
            cursorHandshakeBuilder: { cursor in
                var map: [String: HouseholdCBORValue] = ["v": .unsigned(1)]
                if let cursor {
                    map["since"] = .unsigned(cursor)
                }
                return .data(HouseholdCBOR.encode(.map(map)))
            },
            transportFactory: { [session] cursor in
                let request = try Self.gossipRequest(
                    household: household,
                    cursor: cursor,
                    popSigner: popSigner
                )
                return URLSessionGossipTransport(task: session.webSocketTask(with: request))
            }
        )
        let consumer = HouseholdGossipConsumer(
            householdId: household.householdId,
            householdPublicKey: household.householdPublicKey,
            crlStore: crlStore,
            membershipStore: membershipStore,
            queue: queue,
            eventVerifier: { [membershipStore] event in
                try await Self.verifyGossipEvent(event, membershipStore: membershipStore)
            }
        )
        gossipSocket = socket
        gossipTask = Task {
            let frames = await socket.frames()
            await socket.start()
            do {
                try await consumer.run(
                    frames: frames,
                    cursorUpdater: { cursor in
                        await socket.updateCursor(cursor)
                    }
                )
            } catch {
                await MainActor.run {
                    self.lifecycleError = (error as? MachineJoinError) ?? .gossipDisconnect
                }
            }
        }
    }

    nonisolated private static func gossipRequest(
        household: ActiveHouseholdState,
        cursor: UInt64?,
        popSigner: HouseholdPoPSigner
    ) throws -> URLRequest {
        var components = URLComponents(url: household.endpoint, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty
            ? "/api/v1/household/gossip"
            : "/\(basePath)/api/v1/household/gossip"
        if let cursor {
            components.percentEncodedQuery = "since=\(HouseholdCBOR.encode(.unsigned(cursor)).soyehtBase64URLEncodedString())"
        } else {
            components.percentEncodedQuery = nil
        }
        guard let url = components.url else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let pathAndQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        let authorization = try popSigner.authorization(
            method: "GET",
            pathAndQuery: pathAndQuery,
            body: Data()
        ).authorizationHeader
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated private static func verifyOwnerEvent(
        _ event: OwnerEventsLongPoll.OwnerEvent,
        membershipStore: HouseholdMembershipStore
    ) async throws {
        guard let member = await membershipStore.member(for: event.issuerMachineId) else {
            throw MachineJoinError.certValidationFailed(reason: .wrongIssuer)
        }
        try verifySignature(
            signature: event.signature,
            signingBytes: event.signingBytes,
            publicKey: member.machinePublicKey
        )
    }

    nonisolated private static func verifyGossipEvent(
        _ event: HouseholdGossipEvent,
        membershipStore: HouseholdMembershipStore
    ) async throws {
        guard let member = await membershipStore.member(for: event.issuerMachineId) else {
            throw MachineJoinError.certValidationFailed(reason: .wrongIssuer)
        }
        try verifySignature(
            signature: event.signature,
            signingBytes: event.signingBytes,
            publicKey: member.machinePublicKey
        )
    }

    nonisolated private static func verifySignature(
        signature: Data,
        signingBytes: Data,
        publicKey: Data
    ) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
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
}

private extension JoinRequestEnvelope {
    func withTTLUnix(_ ttlUnix: UInt64) -> JoinRequestEnvelope {
        JoinRequestEnvelope(
            householdId: householdId,
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            rawHostname: rawHostname,
            rawPlatform: rawPlatform,
            candidateAddress: candidateAddress,
            ttlUnix: ttlUnix,
            challengeSignature: challengeSignature,
            transportOrigin: transportOrigin,
            receivedAt: receivedAt
        )
    }
}
