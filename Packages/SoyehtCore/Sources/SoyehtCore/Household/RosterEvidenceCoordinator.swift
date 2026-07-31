import Foundation

/// Why the roster could not be advanced, without implying anything was forged.
/// Degraded states are retryable and never touch persistence.
public enum RosterDegradedReason: Equatable, Sendable {
    /// The engine answered, attested, that it cannot serve a roster right now.
    /// The string is the engine's own outcome, carried through rather than
    /// re-declared here — `RosterEvidenceClient.outcomes` owns that set.
    case engine(outcome: String)
    /// Transport, HTTP status, or wire-level rejection while fetching.
    case transport
    /// The store could not accept or persist the write — the secure store
    /// refused it, or the anchor it needed was no longer there. The candidate is
    /// never published, and nothing is cleared on this account.
    case storage
}

/// Security-relevant rejections. Every case is a dataless enum or an existing
/// error type — no certificates, raw bytes, tombstones or nonces are carried,
/// so this can be surfaced or logged without leaking material.
public enum RosterTamperCategory: Equatable, Sendable {
    /// A persisted blob existed and was refused at load time.
    case storedStateRejected(RosterProjectionLoadRejection)
    /// The evidence verifier rejected the response.
    case evidence(RosterEvidenceError)
    /// Certificate/checkpoint authority verification failed.
    case authority(RosterAuthorityError)
    /// Verification failed in a way that maps to neither enum above.
    case malformed
    /// The signer anchor did not match AND no owner-signed revocation could be
    /// produced to explain it. Never offer re-pairing from this state.
    case anchorUnproven
    /// The store semantically refused a candidate the verifier had already
    /// accepted: a floor rollback, a fork divergence, or a re-derivation that
    /// contradicted the verifier's own reading of the same bytes. The second
    /// line of defence caught something. Availability and persistence failures
    /// are NOT in this category — see `RosterDegradedReason.storage`.
    case storeRefusedCandidate
}

public enum RosterCoordinatorState: Equatable, Sendable {
    /// No usable roster state and nothing wrong: never paired, or an anchor is
    /// pinned but no evidence has been accepted yet.
    case unknown
    case current(VerifiedRosterProjection)
    /// Could not advance. `lastKnown` is the projection the store still holds at
    /// the moment of degrading — carried explicitly so that an unavailable or
    /// transport failure can never be mistaken for a cleared roster. It is `nil`
    /// only when the store genuinely had no current (pending anchor).
    case degraded(reason: RosterDegradedReason, lastKnown: VerifiedRosterProjection?)
    /// A Mac-attested fork. Absorbing: the store will only accept byte-identical
    /// replays from here.
    case terminalFork(VerifiedRosterProjection)
    /// The pinned signer was provably retired by the owner. Only a fresh
    /// user-driven QR/pair flow can move off this state.
    case requiresRePairing(retiredMId: String)
    case tamperSuspected(RosterTamperCategory)
}

/// Composition seam between `RosterEvidenceClient`, `RosterEvidenceVerifier`
/// and `RosterProjectionStore`.
///
/// **Classification is by stage, not by error type.** A failure while *fetching*
/// is degraded — the engine or the network did not cooperate, and nothing about
/// the stored state is suspect. A failure while *verifying* is tamper — the
/// bytes arrived and did not hold up against the household root. Splitting on
/// concrete error types instead would misfile a canonicality rejection thrown
/// inside the verifier as a transport problem.
///
/// **`anchorMismatch` is never trusted on its own.** `RosterEvidenceVerifier`
/// raises that single case for seven distinct causes, so treating it as "the
/// Mac was replaced" would hand an attacker a re-pair prompt. It is only ever
/// resolved to `requiresRePairing` by an owner-signed revocation that this
/// coordinator verifies itself against the household root key.
///
/// This type performs no logging at all: everything it handles is either
/// key material, canonical bytes, or a nonce.
public actor RosterEvidenceCoordinator {
    public typealias EvidenceFetch = @Sendable (_ clientNonce: Data) async throws -> RosterEvidenceResponse
    public typealias CurrencyProbe = @Sendable (_ machineId: String) async throws -> RosterCurrencyResponse
    public typealias NonceProvider = @Sendable () -> Data
    public typealias NowProvider = @Sendable () -> Date

    /// The anchor and the previous projection are two halves of one decision, so
    /// they are produced together from a single case. `.qrPin` requires
    /// `previousProjection == nil` and `.stableBinding` requires it non-nil; by
    /// deriving both from one value the illegal pairing cannot be constructed,
    /// which is what keeps a *structural* `anchorMismatch` from ever reaching
    /// the tamper classifier.
    private enum RefreshBasis {
        case pin(fingerprint: Data)
        case stable(binding: RosterSignerBinding, previous: VerifiedRosterProjection)

        var anchor: RosterEvidenceAnchor {
            switch self {
            case .pin(let fingerprint): return .qrPin(fingerprint: fingerprint)
            case .stable(let binding, _): return .stableBinding(binding)
            }
        }

        var previousProjection: VerifiedRosterProjection? {
            switch self {
            case .pin: return nil
            case .stable(_, let previous): return previous
            }
        }

        /// Only the stable path has a signer to interrogate. On the pin path
        /// there is no persisted binding, so an `anchorMismatch` there can never
        /// be proven and must not trigger a currency probe.
        var pinnedBinding: RosterSignerBinding? {
            switch self {
            case .pin: return nil
            case .stable(let binding, _): return binding
            }
        }
    }

    private let store: RosterProjectionStore
    private let expectedHouseholdId: String
    private let householdPublicKey: Data
    private let fetchEvidence: EvidenceFetch
    private let probeCurrency: CurrencyProbe
    private let nonceProvider: NonceProvider
    private let now: NowProvider
    private var state: RosterCoordinatorState = .unknown

    public init(
        store: RosterProjectionStore,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        fetchEvidence: @escaping EvidenceFetch,
        probeCurrency: @escaping CurrencyProbe,
        // Deliberately not defaulted: the entropy source is the caller's
        // concern, and this type should neither own a CSPRNG nor borrow one
        // from an unrelated domain. Must return 32 bytes.
        nonceProvider: @escaping NonceProvider,
        now: @escaping NowProvider = { Date() }
    ) {
        self.store = store
        self.expectedHouseholdId = expectedHouseholdId
        self.householdPublicKey = householdPublicKey
        self.fetchEvidence = fetchEvidence
        self.probeCurrency = probeCurrency
        self.nonceProvider = nonceProvider
        self.now = now
    }

    public func currentState() -> RosterCoordinatorState { state }

    /// Publishes whatever the store already holds, without any network call.
    @discardableResult
    public func bootstrap() async -> RosterCoordinatorState {
        switch await store.load() {
        case .absent:
            if let rejection = await store.lastRejection() {
                return publish(.tamperSuspected(.storedStateRejected(rejection)))
            }
            return publish(.unknown)
        case .pendingAnchor:
            // An anchor is pinned but nothing has been accepted yet.
            return publish(.unknown)
        case .current(let stored):
            return publish(
                stored.projection.isTerminalFork
                    ? .terminalFork(stored.projection)
                    : .current(stored.projection)
            )
        }
    }

    /// Fetches, verifies, and — only on a verified `available` — persists.
    @discardableResult
    public func refresh() async -> RosterCoordinatorState {
        let stored = await store.load()
        let basis: RefreshBasis
        switch stored {
        case .absent:
            // Nothing to anchor against. Do not fetch: an unanchored response
            // could not be verified against anything.
            if let rejection = await store.lastRejection() {
                return publish(.tamperSuspected(.storedStateRejected(rejection)))
            }
            return publish(.unknown)
        case .pendingAnchor(let fingerprint):
            basis = .pin(fingerprint: fingerprint)
        case .current(let record):
            basis = .stable(binding: record.signerBinding, previous: record.projection)
        }

        let nonce = nonceProvider()

        let response: RosterEvidenceResponse
        do {
            response = try await fetchEvidence(nonce)
        } catch {
            // Fetch stage: transport, HTTP status, or wire rejection. The store
            // is untouched, and the projection it still holds rides along so
            // this cannot read as a clear.
            return publish(.degraded(reason: .transport, lastKnown: basis.previousProjection))
        }

        let outcome: RosterEvidenceOutcome
        do {
            outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(
                response: response,
                expectedNonce: nonce,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey,
                anchor: basis.anchor,
                previousProjection: basis.previousProjection
            )
        } catch RosterEvidenceError.anchorMismatch {
            return await resolveAnchorMismatch(basis: basis)
        } catch let error as RosterEvidenceError {
            return publish(.tamperSuspected(.evidence(error)))
        } catch let error as RosterAuthorityError {
            return publish(.tamperSuspected(.authority(error)))
        } catch {
            return publish(.tamperSuspected(.malformed))
        }

        switch outcome {
        case .unavailable(_, let engineOutcome):
            // Attested "cannot answer". No write, no clear: the persisted
            // pending/current stays exactly as it is for the next attempt.
            return publish(.degraded(
                reason: .engine(outcome: engineOutcome),
                lastKnown: basis.previousProjection
            ))
        case .available(let evidence):
            return await commit(evidence, lastKnown: basis.previousProjection)
        }
    }

    private func commit(
        _ evidence: RosterAvailableEvidence,
        lastKnown: VerifiedRosterProjection?
    ) async -> RosterCoordinatorState {
        let projection: VerifiedRosterProjection
        do {
            projection = try await store.commitCurrent(
                signerBinding: evidence.signerBinding,
                canonicalSnapshotBody: evidence.canonicalSnapshotBody
            )
        } catch let error as RosterProjectionStoreError {
            // EXHAUSTIVE ON PURPOSE — no `default`. Adding a case to
            // `RosterProjectionStoreError` must break this build until someone
            // classifies it deliberately. The two branches below are not
            // interchangeable: `tamperSuspected` is what gates the re-pairing
            // story, so neither it nor `requiresRePairing` may ever be reached
            // by omission or by a catch-all's convenience.
            switch error {
            case .persistenceFailed, .anchorMissing:
                // The store could not accept or persist the write.
                // `.anchorMissing` means the anchor was gone by the time we
                // committed — it disappeared between the read that chose the
                // basis and this call. That is an availability/ordering
                // condition, not an assertion about the bytes we just verified.
                // Neither case publishes the candidate; `lastKnown` is the
                // projection that was valid when the basis was chosen.
                return publish(.degraded(reason: .storage, lastKnown: lastKnown))
            case .floorRollback, .terminalForkDiverged, .evidenceUnusable:
                // Post-verification semantic refusal: the store contradicted a
                // candidate the verifier had already accepted.
                return publish(.tamperSuspected(.storeRefusedCandidate))
            }
        } catch {
            // Residual, required because `commitCurrent` re-derives internally
            // and can therefore surface authority/wire errors that are not
            // `RosterProjectionStoreError`. Those are re-derivation
            // contradictions, so they stay fail-closed rather than degraded.
            return publish(.tamperSuspected(.storeRefusedCandidate))
        }
        return publish(
            projection.isTerminalFork ? .terminalFork(projection) : .current(projection)
        )
    }

    /// The only path to `requiresRePairing`, and the only place a currency probe
    /// is ever issued — exactly once, never as a retry for any other error.
    ///
    /// The proof is positive and self-contained: an owner-signed revocation for
    /// the pinned signer, in the stored epoch, verified here against the
    /// household root key. It deliberately does NOT require the revocation to
    /// appear in a newer projection or checkpoint — `anchorMismatch` is exactly
    /// the condition that prevents adopting that projection, so demanding it
    /// would make the proof unreachable. Position within the event chain
    /// (`prev_event_hash`, sequence, prefix) is likewise not required, because
    /// intermediate events may legitimately be missing from this device's view.
    private func resolveAnchorMismatch(basis: RefreshBasis) async -> RosterCoordinatorState {
        guard let binding = basis.pinnedBinding,
              let previous = basis.previousProjection else {
            // Pin path: no persisted signer exists to interrogate.
            return publish(.tamperSuspected(.anchorUnproven))
        }
        // A projection with no epoch (no genesis) has no lineage to match
        // against, so no revocation can be tied to it.
        guard let storedEpoch = previous.epoch else {
            return publish(.tamperSuspected(.anchorUnproven))
        }

        let response: RosterCurrencyResponse
        do {
            response = try await probeCurrency(binding.mId)
        } catch {
            return publish(.tamperSuspected(.anchorUnproven))
        }

        guard response.outcome == "revoked", let tombstone = response.tombstone else {
            // active / not_listed / unavailable_*: the signer is not provably
            // retired, so the mismatch stays unexplained.
            return publish(.tamperSuspected(.anchorUnproven))
        }
        guard tombstone.mId == binding.mId, tombstone.hhId == expectedHouseholdId else {
            return publish(.tamperSuspected(.anchorUnproven))
        }
        // Same household and owner but a different epoch is a different
        // lineage, not a retirement of the machine we pinned. `epoch` is inside
        // `revocationUnsignedKeys`, so the owner signature verified below binds
        // exactly these bytes — this is a comparison of signed material, not a
        // second hand-rolled verification.
        guard tombstone.epoch == storedEpoch else {
            return publish(.tamperSuspected(.anchorUnproven))
        }
        do {
            try RosterAuthorityVerifier.verifyRevocationSignature(
                canonicalRevocation: tombstone.canonicalTombstone,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey,
                effectiveNow: UInt64(max(0, now().timeIntervalSince1970))
            )
        } catch {
            return publish(.tamperSuspected(.anchorUnproven))
        }
        // Proven: the owner retired this machine. The store is left intact so
        // the user's existing state survives until they re-pair deliberately.
        return publish(.requiresRePairing(retiredMId: binding.mId))
    }

    @discardableResult
    private func publish(_ next: RosterCoordinatorState) -> RosterCoordinatorState {
        state = next
        return next
    }
}
