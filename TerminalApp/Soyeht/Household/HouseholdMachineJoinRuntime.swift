import CryptoKit
import Foundation
import SoyehtCore

@MainActor
final class HouseholdMachineJoinRuntime: ObservableObject {
    /// Marks the phase boundaries `activate(_:)` and `stop()` cross when the
    /// post-pairing lifecycle moves between subsystems. On the success
    /// branch, the contract is `.snapshotStarted` → `.snapshotCompleted` →
    /// `.gossipStarted` → `.ownerEventsStarted`; teardown fires
    /// `.stopRequested` → `.stopCompleted`. `.activationFailed` may fire
    /// before or after `.snapshotStarted` and terminates activation without
    /// downstream phases. Cancellation via `stop()` is recorded by the stop
    /// boundary pair, not as a protocol failure. The success phases must be
    /// observed in this exact order — any reordering means the snapshot is no
    /// longer the atomic seed for the gossip stream and the protocol invariant
    /// is broken.
    enum LifecyclePhase: Sendable, Equatable {
        case snapshotStarted
        case snapshotCompleted
        case activationFailed
        case gossipStarted
        case ownerEventsStarted
        case stopRequested
        case stopCompleted
    }

    @Published private(set) var pendingRequests: [JoinRequestQueue.PendingRequest] = []
    @Published private(set) var lifecycleError: MachineJoinError?
    /// Snapshot of the join request the operator is mid-confirming
    /// (biometric ceremony + signing + approval POST). The home view uses
    /// this — not the live queue — to drive the visible card so the
    /// `JoinRequestConfirmationCardHost` survives:
    ///
    /// 1. A newer request arriving on owner-events / gossip that would
    ///    otherwise change `requests.last`.
    /// 2. The operator tapping a secondary pill (the pill row hides while
    ///    a snapshot is held, so this is just defence-in-depth).
    /// 3. The queue removing the entry while the card still needs to be
    ///    visible — `acknowledgeByMachine` mid-`.authorizing`,
    ///    `confirmClaim` running before the VM transitions to
    ///    `.succeeded`, or terminal failure flows that pull the entry
    ///    while the user still needs to read the error banner.
    ///
    /// The snapshot is set *synchronously* on the operator's Confirm tap
    /// (via `JoinRequestConfirmationView.onConfirmTap`) so the
    /// SwiftUI/MainActor reentrancy window between Confirm and
    /// `state = .authorizing` cannot reorder the topId before the lock
    /// lands.
    @Published private(set) var confirmingRequest: JoinRequestQueue.PendingRequest?

    var confirmingRequestKey: String? {
        confirmingRequest?.envelope.idempotencyKey
    }

    let queue: JoinRequestQueue

    private let keyProvider: any OwnerIdentityKeyCreating
    private let wordlist: BIP39Wordlist
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private let membershipStore: HouseholdMembershipStore
    private let crlStore: CRLStore?
    private let gossipCursorStore: any HouseholdGossipCursorStoring
    /// Test-only hook. Production callers leave this nil and pay no
    /// overhead. Tests inject a recorder to assert the documented phase
    /// order without instrumenting URLSession or refactoring the runtime
    /// into per-phase factories.
    private let phaseObserver: (@MainActor (LifecyclePhase) -> Void)?

    private var activeHouseholdId: String?
    private var activationToken = UUID()
    private var queueTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var ownerEventsCoordinator: OwnerEventsCoordinator?
    private var gossipSocket: HouseholdGossipSocket?
    private var gossipTask: Task<Void, Never>?

    init(
        queue: JoinRequestQueue = JoinRequestQueue(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        wordlist: BIP39Wordlist? = nil,
        crlStore: CRLStore? = nil,
        gossipCursorStore: any HouseholdGossipCursorStoring = UserDefaultsHouseholdGossipCursorStore(),
        session: URLSession = .shared,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        phaseObserver: (@MainActor (LifecyclePhase) -> Void)? = nil
    ) {
        self.queue = queue
        self.keyProvider = keyProvider
        self.wordlist = wordlist ?? Self.loadBundledWordlist()
        self.session = session
        self.nowProvider = nowProvider
        self.membershipStore = HouseholdMembershipStore()
        self.crlStore = crlStore ?? (try? CRLStore())
        self.gossipCursorStore = gossipCursorStore
        self.phaseObserver = phaseObserver
        observeQueue()
    }

    deinit {
        queueTask?.cancel()
        activationTask?.cancel()
        gossipTask?.cancel()
    }

    func activate(_ household: ActiveHouseholdState) {
        if activeHouseholdId == household.householdId,
           lifecycleError == nil,
           activationTask != nil {
            return
        }
        if activeHouseholdId == household.householdId,
           lifecycleError == nil,
           gossipSocket != nil,
           ownerEventsCoordinator != nil {
            ownerEventsCoordinator?.enterForeground()
            return
        }
        stop()
        let token = UUID()
        activationToken = token
        activeHouseholdId = household.householdId
        lifecycleError = nil
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationToken == token {
                    self.activationTask = nil
                }
            }
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
                self.phaseObserver?(.snapshotStarted)
                let bootstrap = try await snapshot.bootstrap()
                // Token-gate the success path. If `stop()` (or a switch to a
                // different household) rotated `activationToken` while the
                // snapshot fetch was in flight, abandon the activation
                // without persisting the cursor or starting gossip /
                // owner-events — the new activation owns the runtime now,
                // and we must not clobber its sockets/coordinators with a
                // stale household's components.
                guard self.activationToken == token,
                      self.activeHouseholdId == household.householdId else {
                    return
                }
                self.phaseObserver?(.snapshotCompleted)
                self.gossipCursorStore.saveCursor(bootstrap.cursor, for: household.householdId)

                self.startGossip(
                    household: household,
                    popSigner: popSigner,
                    crlStore: crlStore,
                    activationToken: token
                )
                self.phaseObserver?(.gossipStarted)
                self.startOwnerEvents(household: household, popSigner: popSigner)
                self.phaseObserver?(.ownerEventsStarted)
            } catch is CancellationError {
                // Swift Concurrency cancellation token. Most cancel paths
                // we hit (URLSession, transports) surface as
                // `URLError(.cancelled)` wrapped into `.networkDrop`, not
                // `CancellationError` — the actual user-visible silencing
                // when `stop()` rotates the activation comes from the
                // token guard in the `catch` blocks below. This branch
                // exists for completeness; the token guard is the real
                // protection.
                //
                // Skip the `.activationFailed` emission here — a cancelled
                // activation is not a failure of the pairing protocol,
                // it is the teardown path racing the activation Task,
                // and the `.stopRequested` / `.stopCompleted` boundary
                // already records the lifecycle event correctly.
            } catch let error as MachineJoinError {
                guard self.activationToken == token else { return }
                self.activeHouseholdId = nil
                self.lifecycleError = error
                self.phaseObserver?(.activationFailed)
            } catch {
                guard self.activationToken == token else { return }
                self.activeHouseholdId = nil
                self.lifecycleError = .networkDrop
                self.phaseObserver?(.activationFailed)
            }
        }
    }

    func stop() {
        phaseObserver?(.stopRequested)
        activationToken = UUID()
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
        // Releasing the household session also drops any in-flight
        // confirm — leaving the snapshot set would either pin the
        // ex-household's card visible across logout, or leak it into the
        // next activation. Both are wrong; clear it here.
        confirmingRequest = nil
        phaseObserver?(.stopCompleted)
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
        let cappedExpiry = try Self.cappedStagedTTL(
            originalTTLUnix: envelope.ttlUnix,
            acceptedExpiry: accepted.expiry,
            now: nowProvider()
        )
        let staged = envelope.withTTLUnix(cappedExpiry)
        _ = await queue.enqueue(staged, cursor: accepted.ownerEventCursor)
        await refreshPendingRequests()
    }

    /// Capture a snapshot of the request the operator just tapped Confirm
    /// on. Called *synchronously* from the Confirm button's tap handler —
    /// before `Task { await viewModel.confirm() }` is created — so the
    /// snapshot lands before any `await` yields the main actor and a
    /// concurrent gossip / owner-events delivery can re-publish
    /// `pendingRequests` and rebuild the card host out from under the
    /// in-flight ViewModel.
    func beginConfirming(_ request: JoinRequestQueue.PendingRequest) {
        confirmingRequest = request
    }

    /// Release the snapshot. Idempotent on key mismatch (a stale
    /// `onChange`/`onDisappear` from a previous host won't clobber a
    /// newer confirm). The card host calls this when the VM reaches a
    /// state at which the operator no longer needs the card pinned —
    /// `.pending` after a non-terminal revert, or `.dismissed` after
    /// success/failure resolution.
    func endConfirming(_ idempotencyKey: String) {
        if confirmingRequest?.envelope.idempotencyKey == idempotencyKey {
            confirmingRequest = nil
        }
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
            throw MachineJoinError.signingFailed
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
        crlStore: CRLStore,
        activationToken: UUID
    ) {
        let initialCursor = gossipCursorStore.loadCursor(for: household.householdId)
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
            cursorStore: gossipCursorStore,
            eventVerifier: { [membershipStore] event in
                try await Self.verifyGossipEvent(event, membershipStore: membershipStore)
            }
        )
        gossipSocket = socket
        gossipTask = Task { [weak self] in
            let frames = await socket.frames()
            await socket.start()
            do {
                try await consumer.run(
                    frames: frames,
                    cursorUpdater: { cursor in
                        await socket.updateCursor(cursor)
                    }
                )
            } catch is CancellationError {
                // See the matching note in `activate(_:)`. The actual
                // silencing on stop/household-switch comes from the token +
                // household guard in the generic `catch` below; this branch
                // exists for completeness.
            } catch {
                await MainActor.run {
                    guard let self,
                          self.activationToken == activationToken,
                          self.activeHouseholdId == household.householdId else {
                        return
                    }
                    self.lifecycleError = (error as? MachineJoinError) ?? .gossipDisconnect
                }
            }
        }
    }

    /// Returns the unix-second TTL that should govern a staged join
    /// request. The original QR's `ttlUnix` is the hard ceiling — the
    /// candidate signed the QR challenge with that value and the local
    /// `PairMachineQR` parser already enforced our 5 min cap. The
    /// staging server can shorten the window (e.g. it knows about a
    /// concurrent join) but must not extend it.
    ///
    /// Both sides are validated symmetrically against `now`: a zero or
    /// already-past `acceptedExpiry` is rejected (server bug / attack),
    /// and a zero or already-past `originalTTLUnix` is rejected too
    /// (significant clock skew, or the QR sat in the scanner buffer
    /// long enough to expire between parse and stage). The intent is to
    /// fail closed at the staging boundary instead of relying on
    /// `JoinRequestQueue.pendingEntries(now:)` to silently drop a
    /// permanently-expired entry.
    nonisolated static func cappedStagedTTL(
        originalTTLUnix: UInt64,
        acceptedExpiry: UInt64,
        now: Date
    ) throws -> UInt64 {
        let nowUnix = UInt64(max(0, now.timeIntervalSince1970))
        guard acceptedExpiry > nowUnix else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard originalTTLUnix > nowUnix else {
            throw MachineJoinError.qrExpired
        }
        return min(originalTTLUnix, acceptedExpiry)
    }

    nonisolated private static func loadBundledWordlist() -> BIP39Wordlist {
        do {
            return try BIP39Wordlist()
        } catch {
            preconditionFailure("SoyehtCore BIP39 wordlist resource is missing or corrupt: \(error)")
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

extension JoinRequestEnvelope {
    /// Returns a copy with `ttlUnix` replaced. Used by
    /// `HouseholdMachineJoinRuntime.stageScannedMachineJoin` to enforce the
    /// staging-server cap against the QR's hard ceiling. Exposed at module
    /// level (not file-private) so the Story-2 integration test can mirror
    /// the production rebuild byte-for-byte instead of repeating the
    /// field-by-field initializer call site — keeping the production helper
    /// the single source of truth for envelope-with-TTL transitions.
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
