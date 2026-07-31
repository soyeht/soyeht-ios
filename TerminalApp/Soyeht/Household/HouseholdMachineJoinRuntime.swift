import CryptoKit
import Foundation
import os
import SoyehtCore

/// Narrow app-side seam over `RosterEvidenceCoordinator`, in the same spirit as
/// `BaseMachineAuthorityBootstrapping`. The runtime only forwards what it is
/// told: it never re-classifies, retries, or probes.
protocol RosterEvidenceActivating: Sendable {
    func bootstrap() async -> RosterCoordinatorState
    func refresh() async -> RosterCoordinatorState
}

extension RosterEvidenceCoordinator: RosterEvidenceActivating {}

/// Seam over the snapshot step so the activation ordering around it can be
/// tested without a signed snapshot corpus. Production keeps the real
/// bootstrapper; nothing about the snapshot contract changes here.
protocol HouseholdSnapshotBootstrapping: Sendable {
    func bootstrap() async throws -> HouseholdSnapshotBootstrapResult
}

extension HouseholdSnapshotBootstrapper: HouseholdSnapshotBootstrapping {}

@MainActor
final class HouseholdMachineJoinRuntime: ObservableObject {
    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "household-runtime")

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
    ///
    /// The foreground boundaries are appended after the activation/teardown
    /// set on purpose: they are not part of the ordered activation contract
    /// above. A foreground can arrive at any time, any number of times, and
    /// none of these phases participates in the `.snapshotStarted → … →
    /// .ownerEventsStarted` ordering assertion.
    ///
    /// Exactly one of `.rosterRevalidationStarted` / `.rosterRevalidationSkipped`
    /// fires per `enterForeground()`, and a started revalidation is always
    /// terminated by `.rosterRevalidationPublished` or
    /// `.rosterRevalidationDiscarded`. That pairing is what makes "the roster
    /// was silently never re-checked" observable rather than inferred.
    enum LifecyclePhase: Sendable, Equatable {
        case snapshotStarted
        case snapshotCompleted
        case activationFailed
        case gossipStarted
        case ownerEventsStarted
        case stopRequested
        case stopCompleted
        /// `enterForeground()` reached a live owner-events coordinator and told
        /// it to resume. Emitted once per call, and only when a coordinator
        /// exists — so "roster work swallowed the owner-events wake-up" is a
        /// test failure rather than a silent regression.
        case ownerEventsForegrounded
        /// A foreground roster revalidation began against the live activation.
        case rosterRevalidationStarted
        /// The revalidation's result was published verbatim onto `rosterState`.
        case rosterRevalidationPublished
        /// The revalidation finished, but its activation was no longer current
        /// (`stop()` or a household switch won the race), so nothing was
        /// published.
        case rosterRevalidationDiscarded
        /// No revalidation was started: no active identity owns a roster
        /// activator, or one round-trip is already in flight.
        case rosterRevalidationSkipped
    }

    @Published private(set) var pendingRequests: [JoinRequestQueue.PendingRequest] = []
    @Published private(set) var pendingDevicePairRequests: [DevicePairRequestQueue.PendingRequest] = []
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
    @Published private(set) var confirmingDevicePairRequest: DevicePairRequestQueue.PendingRequest?

    /// Verified roster state, published verbatim from `RosterEvidenceCoordinator`.
    /// No parallel cache and no mapping layer, so the two cannot disagree.
    ///
    /// Deliberately NOT folded into `lifecycleError`. `.degraded` is operational
    /// and preserves activation; `.unknown`, `.terminalFork`, `.requiresRePairing`
    /// and `.tamperSuspected` must stay individually visible for the UI slice.
    /// Projection gating belongs to a later slice — this one only publishes.
    ///
    /// While no roster activator is injected this stays `.unknown`, which means
    /// "nothing established", NOT "roster is healthy". See
    /// `rosterActivatingFactory`.
    @Published private(set) var rosterState: RosterCoordinatorState = .unknown

    var confirmingRequestKey: String? {
        confirmingRequest?.envelope.idempotencyKey
    }

    var isApprovalV2ReviewEnabled: Bool {
        approvalV2ReviewEnabled
    }

    let queue: JoinRequestQueue
    let devicePairQueue: DevicePairRequestQueue

    private let keyProvider: any OwnerIdentityKeyCreating
    private let wordlist: BIP39Wordlist
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private let approvalV2ReviewEnabled: Bool
    private let membershipStore: HouseholdMembershipStore
    private let crlStore: CRLStore?
    private let gossipCursorStore: any HouseholdGossipCursorStoring
    /// Test-only bypass. When injected it wins over `rosterActivationProvider`,
    /// so runtime tests can drive roster states without a network round-trip.
    /// Production leaves this nil.
    private let rosterActivatingFactory: (
        @MainActor (ActiveHouseholdState, HouseholdPoPSigner) -> any RosterEvidenceActivating
    )?
    /// Production wiring: bootstraps the machine authority and resolves the
    /// route through `MachineReachability`. Nil disables the roster step
    /// entirely — the runtime then publishes nothing and `rosterState` stays
    /// `.unknown`, which means "nothing established", NOT "roster is fine".
    private let rosterActivationProvider: RosterActivationProvider?
    /// Nil in production, where the real `HouseholdSnapshotBootstrapper` is
    /// built below. Test-injectable so activation ordering can be exercised.
    private let snapshotBootstrappingFactory: (
        @MainActor (ActiveHouseholdState, HouseholdPoPSigner, CRLStore) -> any HouseholdSnapshotBootstrapping
    )?
    /// Test-only hook. Production callers leave this nil and pay no
    /// overhead. Tests inject a recorder to assert the documented phase
    /// order without instrumenting URLSession or refactoring the runtime
    /// into per-phase factories.
    private let phaseObserver: (@MainActor (LifecyclePhase) -> Void)?

    private var activeHouseholdId: String?
    private var activationToken = UUID()
    private var queueTask: Task<Void, Never>?
    private var devicePairQueueTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var ownerEventsCoordinator: OwnerEventsCoordinator?
    private var gossipSocket: HouseholdGossipSocket?
    private var gossipTask: Task<Void, Never>?
    /// The roster activator built for the CURRENT activation, retained so a
    /// foreground revalidation can reuse the household, identity and route that
    /// activation already validated. That reuse is the whole point: it is what
    /// keeps revalidation from re-authenticating, bootstrapping a second
    /// machine authority, resolving a second route, or acquiring an endpoint of
    /// its own. Nil whenever there is nothing to revalidate — before any
    /// activation, when no trusted route could be resolved, and after `stop()`.
    private var rosterActivator: (any RosterEvidenceActivating)?
    /// The activation token `rosterActivator` was built under. A foreground
    /// revalidates only while this still equals `activationToken`, so an
    /// activator that outlived its activation can never be reused — belt to the
    /// `stop()` teardown's braces.
    private var rosterActivatorToken: UUID?
    /// Single-flight slot for roster round-trips, scoped to the activation that
    /// holds it. Non-nil means one is already in flight and a further request
    /// is DROPPED rather than queued: iOS delivers foreground notifications in
    /// bursts, and queueing would turn one wake-up into a fan-out of duplicate
    /// evidence fetches against the same coordinator.
    ///
    /// Token-scoping is what makes release safe. A late completion from a dead
    /// activation releases a token nobody holds any more, so it cannot free the
    /// live activation's slot out from under it.
    private var rosterRefreshingToken: UUID?
    private var rosterRefreshTask: Task<Void, Never>?

    init(
        queue: JoinRequestQueue = JoinRequestQueue(),
        devicePairQueue: DevicePairRequestQueue = DevicePairRequestQueue(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        wordlist: BIP39Wordlist? = nil,
        crlStore: CRLStore? = nil,
        gossipCursorStore: any HouseholdGossipCursorStoring = UserDefaultsHouseholdGossipCursorStore(),
        session: URLSession = .shared,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        approvalV2ReviewEnabled: Bool = false,
        rosterActivatingFactory: (
            @MainActor (ActiveHouseholdState, HouseholdPoPSigner) -> any RosterEvidenceActivating
        )? = nil,
        rosterActivationProvider: RosterActivationProvider? = RosterActivationProvider(),
        snapshotBootstrappingFactory: (
            @MainActor (ActiveHouseholdState, HouseholdPoPSigner, CRLStore) -> any HouseholdSnapshotBootstrapping
        )? = nil,
        phaseObserver: (@MainActor (LifecyclePhase) -> Void)? = nil
    ) {
        self.queue = queue
        self.devicePairQueue = devicePairQueue
        self.keyProvider = keyProvider
        self.wordlist = wordlist ?? Self.loadBundledWordlist()
        self.session = session
        self.nowProvider = nowProvider
        self.approvalV2ReviewEnabled = approvalV2ReviewEnabled
        self.membershipStore = HouseholdMembershipStore()
        self.crlStore = crlStore ?? (try? CRLStore())
        self.gossipCursorStore = gossipCursorStore
        self.rosterActivatingFactory = rosterActivatingFactory
        self.rosterActivationProvider = rosterActivationProvider
        self.snapshotBootstrappingFactory = snapshotBootstrappingFactory
        self.phaseObserver = phaseObserver
        observeQueue()
        observeDevicePairQueue()
    }

    deinit {
        queueTask?.cancel()
        devicePairQueueTask?.cancel()
        activationTask?.cancel()
        gossipTask?.cancel()
        rosterRefreshTask?.cancel()
    }

    func activate(_ household: ActiveHouseholdState) {
        Self.logger.info("soyeht_diag runtime_activate requested delegated=\(household.isDelegatedDevice, privacy: .public)")
        if activeHouseholdId == household.householdId,
           lifecycleError == nil,
           activationTask != nil {
            Self.logger.info("soyeht_diag runtime_activate ignored existing_activation_task")
            return
        }
        if activeHouseholdId == household.householdId,
           lifecycleError == nil,
           gossipSocket != nil,
           ownerEventsCoordinator != nil {
            Self.logger.info("soyeht_diag runtime_activate foreground_existing_runtime")
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
                Self.logger.info("soyeht_diag runtime_snapshot_start")
                let crlStore = try self.requireCRLStore()
                let ownerIdentity = try self.loadOwnerIdentity(for: household)
                let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: self.nowProvider)

                let bootstrapper = self.makeSnapshotBootstrapping(
                    household,
                    popSigner: popSigner,
                    crlStore: crlStore
                )
                self.phaseObserver?(.snapshotStarted)
                let bootstrap = try await bootstrapper.bootstrap()
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
                Self.logger.info("soyeht_diag runtime_snapshot_completed cursor=\(bootstrap.cursor, privacy: .public)")
                self.gossipCursorStore.saveCursor(bootstrap.cursor, for: household.householdId)

                // Roster evidence sits between the snapshot and gossip: the
                // snapshot is the atomic seed, and gossip should not start
                // against a household whose roster state is still unestablished.
                // No roster outcome is an activation failure — every state is
                // operational here and gossip proceeds regardless. When no
                // activator is wired the step is skipped entirely rather than
                // publishing a state nobody produced.
                // Building the activator performs the authority bootstrap and
                // the route resolution, so it is itself an await and gets the
                // same revalidation as every other suspension point.
                let rosterActivator = await self.makeRosterActivating(
                    household, popSigner: popSigner
                )
                guard self.activationToken == token,
                      self.activeHouseholdId == household.householdId else {
                    return
                }
                if let roster = rosterActivator {
                    // Retain the activator for the life of THIS activation, so a
                    // later foreground revalidates through the very object that
                    // already holds the validated household, identity and route.
                    self.rosterActivator = roster
                    self.rosterActivatorToken = token
                    // Own the single-flight slot across the whole bootstrap +
                    // refresh pair. `activate` opened with `stop()`, which
                    // released the slot and cleared the activator, and these two
                    // lines are the only place either is re-armed — so the claim
                    // cannot be contended here, and a foreground arriving
                    // mid-activation is dropped instead of racing this pass.
                    self.claimRosterRefresh(token)
                    defer { self.releaseRosterRefresh(token) }

                    let bootstrapped = await roster.bootstrap()
                    // Re-validate after EVERY await: a `stop()` or household
                    // switch during the roster round-trip means a newer
                    // activation owns `rosterState`, and publishing here would
                    // install a stale household's roster on top of it.
                    guard self.activationToken == token,
                          self.activeHouseholdId == household.householdId else {
                        return
                    }
                    self.rosterState = bootstrapped

                    let refreshed = await roster.refresh()
                    guard self.activationToken == token,
                          self.activeHouseholdId == household.householdId else {
                        return
                    }
                    self.rosterState = refreshed
                }

                self.startGossip(
                    household: household,
                    popSigner: popSigner,
                    crlStore: crlStore,
                    activationToken: token
                )
                self.phaseObserver?(.gossipStarted)
                // Do not seed owner-events from `bootstrap.cursor`: the
                // snapshot can already include a still-valid device-pair
                // request cursor while the snapshot body has no pending
                // request list. Starting from zero lets the poller recover
                // pending approvals after foreground; expired history is
                // skipped by OwnerEventsLongPoll.
                self.startOwnerEvents(
                    household: household,
                    popSigner: popSigner,
                    initialCursor: 0
                )
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
                Self.logger.error("soyeht_diag runtime_activation_failed error=\(String(describing: error), privacy: .public)")
                self.activeHouseholdId = nil
                self.lifecycleError = error
                self.phaseObserver?(.activationFailed)
            } catch {
                guard self.activationToken == token else { return }
                Self.logger.error("soyeht_diag runtime_activation_failed_unknown error=\(String(describing: error), privacy: .public)")
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
        confirmingDevicePairRequest = nil
        // Same reasoning for the roster: an ex-household's roster state must not
        // stay visible across logout or bleed into the next activation. This is
        // teardown, not a competing cache — the next activation republishes from
        // the coordinator, which re-reads the store.
        //
        // The activator, its token and the single-flight slot are dropped with
        // it. After this point no foreground can revalidate, and a revalidation
        // still in flight can neither publish (its token is dead) nor free the
        // next activation's slot (release is token-scoped). The cancel is best
        // effort only: `RosterEvidenceCoordinator.refresh()` is non-throwing and
        // does not poll for cancellation, so the token guard in
        // `finishRosterRevalidation` — not cancellation — is what actually stops
        // a late publish.
        rosterState = .unknown
        rosterActivator = nil
        rosterActivatorToken = nil
        rosterRefreshingToken = nil
        rosterRefreshTask?.cancel()
        rosterRefreshTask = nil
        Task { [devicePairQueue] in await devicePairQueue.clear() }
        phaseObserver?(.stopCompleted)
    }

    /// Foreground transition. Owner-events resumes first — it is the path the
    /// operator is actively waiting on — and then the roster is revalidated
    /// against the activation that is already live.
    ///
    /// Revalidation is deliberately NOT a re-activation. There is no logout,
    /// no login, no second authority bootstrap, no parallel endpoint and no
    /// `ActiveHouseholdState` read: it goes through the activator retained by
    /// `activate(_:)`, which already resolved its route through
    /// `MachineReachability`. That is what keeps the roster's warm-session
    /// currency inside the identity that was validated when the session began.
    ///
    /// Fail-closed both ways. Whatever the coordinator returns is published
    /// verbatim, so a revocation or tamper that appeared while the app was
    /// backgrounded becomes visible on the next foreground instead of waiting
    /// for a logout — and a condition the engine has since resolved clears on
    /// the same path, so the banner cannot become permanent.
    func enterForeground() {
        if let ownerEventsCoordinator {
            ownerEventsCoordinator.enterForeground()
            phaseObserver?(.ownerEventsForegrounded)
        }
        revalidateRoster()
    }

    func enterBackground() {
        ownerEventsCoordinator?.enterBackground()
    }

    /// Starts one roster round-trip for the live activation, or reports why it
    /// did not.
    ///
    /// Both guards are refusals, not optimisations. Without a live activation
    /// there is no validated context to revalidate against, so nothing may be
    /// fetched and nothing may be published; and without the single-flight slot
    /// a burst of foreground notifications would fan out into duplicate
    /// evidence fetches.
    private func revalidateRoster() {
        guard let householdId = activeHouseholdId,
              let activator = rosterActivator,
              rosterActivatorToken == activationToken else {
            phaseObserver?(.rosterRevalidationSkipped)
            return
        }
        let token = activationToken
        guard claimRosterRefresh(token) else {
            phaseObserver?(.rosterRevalidationSkipped)
            return
        }
        phaseObserver?(.rosterRevalidationStarted)
        rosterRefreshTask = Task { [weak self] in
            let next = await activator.refresh()
            guard let self else { return }
            self.finishRosterRevalidation(
                token: token, householdId: householdId, state: next
            )
        }
    }

    /// Re-validates the same way every `await` in `activate(_:)` does, and for
    /// the same reason: a `stop()` or a household switch during the round-trip
    /// means this activation no longer owns `rosterState`. Publishing here
    /// would either resurrect a dead household's roster on top of the
    /// `.unknown` teardown installed, or overwrite the successor household's
    /// freshly-published state with a foreign one.
    ///
    /// The slot is released before the guard so a discarded revalidation still
    /// frees what it took — and because release is token-scoped, doing so
    /// cannot disturb whatever activation now holds it.
    private func finishRosterRevalidation(
        token: UUID,
        householdId: String,
        state: RosterCoordinatorState
    ) {
        releaseRosterRefresh(token)
        guard activationToken == token, activeHouseholdId == householdId else {
            phaseObserver?(.rosterRevalidationDiscarded)
            return
        }
        rosterState = state
        phaseObserver?(.rosterRevalidationPublished)
    }

    /// Takes the single-flight slot for `token`, or reports that someone else
    /// already holds it. Never steals: a contended claim fails rather than
    /// displacing the in-flight round-trip.
    @discardableResult
    private func claimRosterRefresh(_ token: UUID) -> Bool {
        guard rosterRefreshingToken == nil else { return false }
        rosterRefreshingToken = token
        return true
    }

    /// Token-scoped release. A late completion from a rotated activation
    /// releases a token nobody holds, which is a no-op — so it can never free
    /// the live activation's slot.
    private func releaseRosterRefresh(_ token: UUID) {
        guard rosterRefreshingToken == token else { return }
        rosterRefreshingToken = nil
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

    func beginConfirmingDevicePair(_ request: DevicePairRequestQueue.PendingRequest) {
        confirmingDevicePairRequest = request
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

    func endConfirmingDevicePair(_ idempotencyKey: String) {
        if confirmingDevicePairRequest?.envelope.idempotencyKey == idempotencyKey {
            confirmingDevicePairRequest = nil
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
                    keyReference: household.signingKeyReference,
                    publicKey: household.signingPublicKey,
                    personId: household.ownerPersonId
                )
                return try OperatorAuthorizationSigner().sign(
                    envelope: envelope,
                    cursor: cursor,
                    ownerIdentity: ownerIdentity,
                    localHouseholdId: household.householdId,
                    now: nowProvider()
                )
            },
            submitAction: { [keyProvider, nowProvider, session] envelope, authorization in
                // Stage 1 of the Phase 3 finalize ceremony: pin the trust
                // anchor on the candidate. This MUST succeed before the
                // founder Mac is asked to approve, otherwise the candidate
                // will reject the founder's `local/finalize` with
                // `trust_anchor_missing` and the operator sees a recoverable
                // network failure surfaced as a permanent ceremony abort
                // (see `theyos/specs/003-machine-join/contracts/local-anchor.md`).
                //
                // Bonjour-shortcut envelopes do not carry an anchor secret
                // today; we let the request flow to the founder anyway so
                // the failure surfaces in the founder's
                // `m2_finalize_outcome_ambiguous` log path rather than being
                // silently swallowed here.
                if let anchorSecret = envelope.anchorSecret {
                    let anchorClient = LocalAnchorClient()
                    try await anchorClient.pinAnchor(
                        candidateAddress: envelope.candidateAddress,
                        anchorSecret: anchorSecret,
                        householdId: household.householdId,
                        householdPublicKey: household.householdPublicKey
                    )
                }

                let ownerIdentity = try keyProvider.loadOwnerIdentity(
                    keyReference: household.signingKeyReference,
                    publicKey: household.signingPublicKey,
                    personId: household.ownerPersonId
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

    func makeOwnerApprovalV2ReviewAdapter(
        for request: JoinRequestQueue.PendingRequest,
        household: ActiveHouseholdState
    ) throws -> OwnerApprovalV2ReviewAdapter {
        let ownerIdentity = try keyProvider.loadOwnerIdentity(
            keyReference: household.signingKeyReference,
            publicKey: household.signingPublicKey,
            personId: household.ownerPersonId
        )
        let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: nowProvider)
        let client = OwnerApprovalV2Client(
            baseURL: household.endpoint,
            popSigner: popSigner,
            transport: JoinRequestStagingClient.urlSessionTransport(session)
        )
        let passkeyProvider = PasskeyProvider(anchorProvider: KeyWindowPasskeyAnchorProvider())
        let orchestrator = OwnerApprovalV2Orchestrator(client: client, provider: passkeyProvider)
        let reviewModel = OwnerApprovalV2ReviewViewModel(cursor: request.cursor, orchestrator: orchestrator)
        return OwnerApprovalV2ReviewAdapter(
            request: request,
            queue: queue,
            runtime: self,
            reviewModel: reviewModel,
            nowProvider: nowProvider,
            pinAnchor: { [session] envelope in
                try await OwnerApprovalV2ReviewAdapter.requireAndPinLocalAnchor(
                    envelope: envelope,
                    household: household,
                    transport: LocalAnchorClient.urlSessionTransport(session)
                )
            }
        )
    }

    func makeDevicePairViewModel(
        for request: DevicePairRequestQueue.PendingRequest,
        household: ActiveHouseholdState
    ) throws -> DevicePairConfirmationViewModel {
        let ownerIdentity = try keyProvider.loadOwnerIdentity(
            keyReference: household.ownerKeyReference,
            publicKey: household.ownerPublicKey,
            personId: household.ownerPersonId
        )
        let nowProvider = self.nowProvider
        return DevicePairConfirmationViewModel(
            envelope: request.envelope,
            queue: devicePairQueue,
            nowProvider: nowProvider,
            approveAction: { [session] envelope in
                try await HouseholdDevicePairingService(
                    httpClient: URLSessionHouseholdDevicePairingHTTPClient(session: session),
                    now: nowProvider
                ).approve(
                    requestId: envelope.requestId,
                    devicePublicKey: envelope.devicePublicKey,
                    deviceName: envelope.deviceName,
                    platform: envelope.platform,
                    household: household,
                    ownerIdentity: ownerIdentity
                )
            }
        )
    }

    private func observeQueue() {
        queueTask?.cancel()
        queueTask = Task { [weak self, queue, nowProvider] in
            let stream = await queue.events()
            let initialRequests = await queue.pendingRequests(now: nowProvider())
            await MainActor.run {
                self?.pendingRequests = initialRequests
            }
            for await _ in stream {
                let requests = await queue.pendingRequests(now: nowProvider())
                await MainActor.run {
                    self?.pendingRequests = requests
                }
            }
        }
    }

    private func observeDevicePairQueue() {
        devicePairQueueTask?.cancel()
        devicePairQueueTask = Task { [weak self, devicePairQueue, nowProvider] in
            let stream = await devicePairQueue.events()
            let initialRequests = await devicePairQueue.pendingRequests(now: nowProvider())
            await MainActor.run {
                Self.logger.info("soyeht_diag device_pair_queue_snapshot count=\(initialRequests.count, privacy: .public)")
                self?.pendingDevicePairRequests = initialRequests
            }
            for await _ in stream {
                let requests = await devicePairQueue.pendingRequests(now: nowProvider())
                await MainActor.run {
                    Self.logger.info("soyeht_diag device_pair_queue_update count=\(requests.count, privacy: .public)")
                    self?.pendingDevicePairRequests = requests
                }
            }
        }
    }

    private func refreshPendingRequests() async {
        pendingRequests = await queue.pendingRequests(now: nowProvider())
    }

    /// Returns the roster activator for this activation, or nil when no trusted
    /// route could be established.
    ///
    /// Production goes through `RosterActivationProvider`, which acquires the
    /// base URL from `MachineReachability` — this runtime acquires no endpoint
    /// itself. Tests inject `rosterActivatingFactory` to bypass the network.
    /// A nil result is not an error: the roster step is skipped, `rosterState`
    /// stays `.unknown`, and activation continues to gossip.
    private func makeRosterActivating(
        _ household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner
    ) async -> (any RosterEvidenceActivating)? {
        if let factory = rosterActivatingFactory {
            return factory(household, popSigner)
        }
        guard let provider = rosterActivationProvider else { return nil }
        return await provider.makeActivator(
            household: household,
            popSigner: popSigner,
            session: session,
            now: nowProvider
        )
    }

    private func makeSnapshotBootstrapping(
        _ household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner,
        crlStore: CRLStore
    ) -> any HouseholdSnapshotBootstrapping {
        if let factory = snapshotBootstrappingFactory {
            return factory(household, popSigner, crlStore)
        }
        let snapshot = HouseholdSnapshotBootstrapper(
            baseURL: household.endpoint,
            householdId: household.householdId,
            householdPublicKey: household.householdPublicKey,
            crlStore: crlStore,
            membershipStore: membershipStore,
            authorizationProvider: { method, pathAndQuery, body in
                try popSigner.authorization(
                    method: method,
                    pathAndQuery: pathAndQuery,
                    body: body
                ).authorizationHeader
            },
            transport: HouseholdSnapshotBootstrapper.urlSessionTransport(session),
            nowProvider: nowProvider
        )
        return snapshot
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
                keyReference: household.signingKeyReference,
                publicKey: household.signingPublicKey,
                personId: household.ownerPersonId
            )
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.signingFailed
        }
    }

    private func startOwnerEvents(
        household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner,
        initialCursor: UInt64
    ) {
        let poller = OwnerEventsLongPoll(
            baseURL: household.endpoint,
            householdId: household.householdId,
            queue: queue,
            devicePairQueue: devicePairQueue,
            wordlist: wordlist,
            initialCursor: initialCursor,
            popSigner: popSigner,
            eventVerifier: { [membershipStore] event in
                try await Self.verifyOwnerEvent(event, membershipStore: membershipStore)
            },
            transport: OwnerEventsLongPoll.urlSessionTransport(session),
            nowProvider: nowProvider
        )
        let logger = Self.logger
        let coordinator = OwnerEventsCoordinator(
            foregroundRun: {
                try await poller.runForeground { result in
                    logger.info(
                        "soyeht_diag owner_events_poll cursor=\(result.cursor, privacy: .public) timed_out=\(result.timedOut, privacy: .public) device_pairs=\(result.enqueuedDevicePairRequests.count, privacy: .public)"
                    )
                }
            },
            backgroundFetch: {
                let result = try await poller.pollOnce()
                logger.info(
                    "soyeht_diag owner_events_background cursor=\(result.cursor, privacy: .public) timed_out=\(result.timedOut, privacy: .public) device_pairs=\(result.enqueuedDevicePairRequests.count, privacy: .public)"
                )
            }
        )
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
        guard let scheme = components.scheme,
              let host = components.host,
              let webSocketScheme = EndpointPolicy.householdWebSocketScheme(
                inputScheme: scheme,
                host: host
              ) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        components.scheme = webSocketScheme
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
            receivedAt: receivedAt,
            anchorSecret: anchorSecret
        )
    }
}
