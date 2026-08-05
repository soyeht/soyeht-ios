import Foundation
import RelayStreamGuestFFI
import SoyehtCore

/// One target on `ClawSiteRelayStreamOpener`'s persistent session. `close()`
/// ends only this target (`openNextTarget` on the Rust session) — the
/// underlying Noise connection stays live for the next exchange, unless
/// closing itself fails, in which case the owner drops the whole session (see
/// `ClawSiteRelayStreamOpener.targetOperationFailed`).
///
/// The data plane's frame set is shaped for a PTY. `nextFrame()` maps every
/// kind explicitly rather than defaulting, because the ones that look
/// irrelevant here are exactly the ones that must not be silently dropped: an
/// `exitCode` or `exitLost` is the backend going away, and treating it as
/// "keep waiting" would hang the request until the bridge timeout instead of
/// failing fast.
private struct ClawSiteTargetStream: ClawSiteStreamSession {
    let owner: ClawSiteRelayStreamOpener
    let session: RelayStreamGuestDataPlaneSession

    func send(_ data: Data) async throws {
        do {
            try await session.send(data: data)
        } catch {
            await owner.targetOperationFailed()
            throw error
        }
    }

    func close() async throws {
        do {
            try await session.close()
        } catch {
            await owner.targetOperationFailed()
            throw error
        }
        // Only on success: releases the target slot WITHOUT dropping the
        // cached session, so the next `openClawSiteStream()` reuses it via
        // `openNextTarget()` instead of redialing.
        await owner.targetClosed()
    }

    func nextFrame() async throws -> ClawSiteStreamFrame {
        let frame: RelayStreamGuestFrameRecord
        do {
            frame = try await session.nextFrame()
        } catch {
            await owner.targetOperationFailed()
            throw error
        }
        switch frame.kind {
        case .data:
            return .data(frame.data)
        case .close:
            return .closed
        case .error:
            return .failed(frame.text)
        case .exitCode, .exitSignal, .exitLost:
            // This target's own backend process/connection ended. Not a
            // completion signal either way — `ClawSiteHTTPBridge` decides
            // that from the bytes themselves (`Content-Length`/chunked) —
            // because even though each target is a fresh backend connection
            // (only the Noise session is reused across exchanges; see this
            // type's doc), whether THIS one happens to end on its own is
            // still a race against the bridge's own completion check, never
            // a signal to trust. Surfaced as `.closed` so the bridge treats
            // it the same as any other early target end: a failure if seen
            // before a complete response, ignored otherwise.
            return .closed
        case .open, .health, .window:
            // Transport-level chatter that carries no response bytes. Recurse
            // rather than returning, so the caller only ever sees frames that
            // advance the HTTP exchange.
            return try await nextFrame()
        }
    }
}

/// Serializes ClawSite HTTP exchanges onto ONE persistent, Noise-authenticated
/// relay-stream session, reusing the offer/credential obtained once at claim
/// time.
///
/// **Reuse, not one dial per request.** The connection and its auth/PoP are
/// negotiated once (`connectPersistent`), which also opens the FIRST target as
/// part of that same call (see the Rust doc) — the first exchange after a
/// dial uses that target as-is. Every exchange after it opens its own target
/// explicitly (`openNextTarget`) and closes just that target when done. A
/// second HTTP request is not a second relay dial. Redial (a fresh
/// `connectPersistent`) happens only when the session itself has
/// failed — the very first call, or any call after `targetOperationFailed`
/// dropped a broken one. This mirrors the real wire contract (see the Rust
/// `relay_stream_connect_persistent` doc): the server tears down the WHOLE
/// connection on any protocol error, so there is no such thing as "this one
/// target failed, the connection is still fine" to recover from.
///
/// **Concurrency.** WebKit can open several subresource requests at once, but
/// a persistent connection allows exactly one live target at a time — an
/// out-of-turn `OpenPersistent` is a framing violation that kills the whole
/// connection (again, see the Rust doc). Making this type an `actor` is NOT
/// enough by itself: `openClawSiteStream()` awaits real I/O
/// (`openNextTarget()`), and an actor is reentrant at every `await` — a
/// second caller's invocation would run during that suspension and could
/// race its own `openNextTarget()` onto the same session. The target-slot
/// mechanism (`acquireTargetSlot`/`releaseTargetSlot`) closes that gap
/// explicitly: `openClawSiteStream()` cannot proceed past `acquireTargetSlot()`
/// until the previous exchange's `close()` (or its own failure)
/// called `releaseTargetSlot()`, so at most one target is ever in flight
/// regardless of how many callers are waiting. It is also cancellation-safe
/// — see `acquireTargetSlot`'s doc for why that is load-bearing, not
/// defensive polish: an ordinary `[CheckedContinuation<Void, Never>]` queue
/// would let a cancelled (e.g. timed-out) caller's continuation sit queued
/// until naturally dequeued, then resume into opening a target nobody is
/// reading from anymore.
actor ClawSiteRelayStreamOpener: ClawSiteStreamOpening {
    private let offer: RelayStreamOfferContract
    private let credential: GuestCredential
    private let guestIdentity: any ClawShareGuestIdentity
    private let client: RelayStreamGuestDataPlaneClient
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID
    private let ttlSecs: UInt64
    private let connectTimeoutMs: UInt64

    private var session: RelayStreamGuestDataPlaneSession?
    private var targetSlotHeld = false
    private var targetSlotWaiterOrder: [Int] = []
    private var targetSlotWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextTargetSlotWaiterID = 0

    /// Test-only. Called, awaited, exactly once per queued-waiter handoff in
    /// `acquireTargetSlot`, between the continuation resuming and the
    /// cancellation recheck right after it — see that method's doc for why
    /// the window between those two points is exactly the race under test.
    /// `nil` in production: `await nil?()` is a no-op, so this never adds a
    /// suspension point outside tests.
    private let postHandoffCancellationSeam: (@Sendable () async -> Void)?

    /// Test-only. Called SYNCHRONOUSLY, on the actor, immediately after a
    /// queued waiter's continuation is registered in `targetSlotWaiters` —
    /// i.e. right after this waiter has genuinely joined the queue and can
    /// be handed the slot by a subsequent `releaseTargetSlot`. Lets a test
    /// know deterministically "the waiter is now enqueued" without polling
    /// or sleeping. `nil` in production: `nil?()` is a no-op.
    private let targetSlotWaiterEnqueuedSeam: (@Sendable () -> Void)?

    init(
        offer: RelayStreamOfferContract,
        credential: GuestCredential,
        guestIdentity: any ClawShareGuestIdentity,
        client: RelayStreamGuestDataPlaneClient = RelayStreamGuestDataPlaneClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() },
        ttlSecs: UInt64 = 60,
        connectTimeoutMs: UInt64 = 10_000,
        postHandoffCancellationSeam: (@Sendable () async -> Void)? = nil,
        targetSlotWaiterEnqueuedSeam: (@Sendable () -> Void)? = nil
    ) {
        self.offer = offer
        self.credential = credential
        self.guestIdentity = guestIdentity
        self.client = client
        self.now = now
        self.uuid = uuid
        self.ttlSecs = ttlSecs
        self.connectTimeoutMs = connectTimeoutMs
        self.postHandoffCancellationSeam = postHandoffCancellationSeam
        self.targetSlotWaiterEnqueuedSeam = targetSlotWaiterEnqueuedSeam
    }

    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        // If THIS throws (cancellation while queued), propagate immediately
        // without entering the `do` below: the slot was never actually held,
        // so `targetOperationFailed()` (which releases it) must not run —
        // there is nothing this call owns to release.
        try await acquireTargetSlot()
        do {
            let (native, freshlyDialed) = try await activeSession()
            // A fresh dial already negotiated its first target as part of
            // `connectPersistent` (see the Rust doc) — calling
            // `openNextTarget()` again right away would try to open a SECOND
            // target before the first was ever used, which is exactly the
            // out-of-turn framing violation that kills the whole connection.
            // Only a REUSED session needs an explicit next-target call.
            if !freshlyDialed {
                try await native.openNextTarget()
            }
            return ClawSiteTargetStream(owner: self, session: native)
        } catch {
            targetOperationFailed()
            throw error
        }
    }

    /// The live persistent session and whether this call just dialed it.
    /// Dials one if there is none yet (first call) or the last one was
    /// dropped after a failure. Only ever called while `targetSlotHeld`, so a
    /// dial in progress cannot race a second one.
    private func activeSession() async throws -> (session: RelayStreamGuestDataPlaneSession, freshlyDialed: Bool) {
        if let session {
            return (session, false)
        }
        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        // Re-verified on every (re)dial, not just once when the claw was
        // opened: an offer that has since expired must stop working rather
        // than keep serving because an earlier dial happened to succeed.
        try offer.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: nowUnix,
            allowedResources: [.clawSite]
        )

        let dialed = try await client.connectPersistent(
            offerCbor: offer.canonicalBytes(),
            credentialCbor: ClawShareCodec.encode(credential),
            expectedOwnerPub: credential.ownerPublicKey,
            expectedGuestPub: guestIdentity.publicKeyData,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: "ios-clawsite-\(uuid().uuidString.lowercased())",
            signer: ClawSiteSessionSigner(identity: guestIdentity),
            connectTimeoutMs: connectTimeoutMs
        )
        session = dialed
        return (dialed, true)
    }

    /// Blocks until no other target is in flight, then marks the slot held.
    /// The check-and-set is synchronous actor-isolated code with no `await`
    /// between them, so two concurrent callers cannot both observe the slot
    /// free — the loser is queued and resumed directly into "holding" by
    /// `releaseTargetSlot`, never re-checking the flag.
    ///
    /// **Cancellation-safe.** A queued waiter whose `Task` is cancelled (e.g.
    /// `ClawSiteHTTPBridge`'s own timeout race, `withThrowingTaskGroup` +
    /// `cancelAll()`) is removed and resumed with `CancellationError`
    /// IMMEDIATELY, not left queued until naturally dequeued. Leaving it
    /// queued would let an already-abandoned caller resume later, race PAST
    /// this guard once whoever it was queued behind finally releases, and
    /// open a target nobody is reading from — checking `Task.isCancelled`
    /// only after a normal resume is not enough: it would avoid the orphan
    /// but not the delay, since the abandoned caller would still have to be
    /// dequeued in turn before a real one can proceed.
    ///
    /// **Cancel-before-registration is closed too.** `onCancel` can fire (on
    /// any thread) the instant the Task is cancelled, which may be BEFORE
    /// this waiter's continuation is actually registered in
    /// `targetSlotWaiters` — `onCancel`'s own removal would then find
    /// nothing and no-op, leaving the continuation, once registered, with
    /// nobody left to resume it. Registration therefore checks
    /// `Task.isCancelled` itself, in the SAME synchronous actor turn as the
    /// registration, and self-resolves if so — `cancelTargetSlotWaiter` is
    /// idempotent (`removeValue` returns `nil` the second time), so whichever
    /// of the two paths runs first is the one that actually resumes it.
    ///
    /// **Post-handoff recheck closes the one race the above two leave
    /// open.** `onCancel`'s own removal runs on a SPAWNED `Task { await
    /// self.cancelTargetSlotWaiter(id) }` — an async hop, not synchronous —
    /// so `releaseTargetSlot`'s normal (synchronous, actor-isolated) resume
    /// can win that race and hand this already-cancelled waiter the slot
    /// with a SUCCESSFUL resume before the cancellation's own removal ever
    /// runs. Left unchecked, this already-abandoned caller would proceed to
    /// open a real target nobody is reading from. The recheck right after
    /// the resume closes it — and it has to live HERE, inside
    /// `acquireTargetSlot`, because `openClawSiteStream` calls this OUTSIDE
    /// its own `do`/`catch` specifically so a throw here means "never held
    /// anything to release" (see its doc); if this method can resume
    /// holding the slot and only THEN decide to give it up, only this
    /// method can be the one to call `releaseTargetSlot()` for that case
    /// without leaking it or double-releasing.
    private func acquireTargetSlot() async throws {
        try Task.checkCancellation()
        if !targetSlotHeld {
            targetSlotHeld = true
            return
        }
        let id = nextTargetSlotWaiterID
        nextTargetSlotWaiterID += 1
        targetSlotWaiterOrder.append(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                targetSlotWaiters[id] = continuation
                targetSlotWaiterEnqueuedSeam?()
                if Task.isCancelled {
                    cancelTargetSlotWaiter(id)
                }
            }
        } onCancel: {
            Task { await self.cancelTargetSlotWaiter(id) }
        }

        // Test-only pause point, between the handoff above and the
        // recheck below — see `postHandoffCancellationSeam`'s doc.
        await postHandoffCancellationSeam?()

        if Task.isCancelled {
            releaseTargetSlot()
            throw CancellationError()
        }
    }

    /// Removes and resumes-with-error waiter `id` if it is still queued. If
    /// `releaseTargetSlot` already dequeued and resumed it (the two raced),
    /// this is a no-op: that waiter's `acquireTargetSlot()` is not left to
    /// release it through the normal `close()`/failure path on trust —
    /// it is intercepted by the post-handoff recheck right after the
    /// resume (see that method's doc), which releases it there instead.
    private func cancelTargetSlotWaiter(_ id: Int) {
        guard let continuation = targetSlotWaiters.removeValue(forKey: id) else {
            return
        }
        targetSlotWaiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    /// Called by `ClawSiteTargetStream.close()` (success or failure) and by
    /// `openClawSiteStream()` itself if opening the target never succeeded.
    /// Every code path that acquires the slot releases it exactly once —
    /// `ClawSiteTargetStream` has no other exit.
    private func releaseTargetSlot() {
        // Hand the held slot directly to the next waiter instead of freeing
        // and re-acquiring it, so a third caller arriving in between can
        // never jump the queue. Skips ids `cancelTargetSlotWaiter` already
        // removed — their continuations are gone, there is nothing to
        // resume, and they never held the slot to begin with.
        while !targetSlotWaiterOrder.isEmpty {
            let id = targetSlotWaiterOrder.removeFirst()
            guard let continuation = targetSlotWaiters.removeValue(forKey: id) else {
                continue
            }
            continuation.resume()
            return
        }
        targetSlotHeld = false
    }

    /// Drops the cached session so the NEXT `openClawSiteStream()` redials.
    /// Called on any target-level failure (open, send, read, or close) —
    /// deliberately not selective, because the real server does not
    /// distinguish "this target broke" from "this connection broke" either.
    /// Always releases the target slot: whether the session was actually
    /// dropped or not, whatever held the slot is done with it.
    fileprivate func targetOperationFailed() {
        session = nil
        releaseTargetSlot()
    }

    fileprivate func targetClosed() {
        releaseTargetSlot()
    }
}

private struct ClawSiteSessionSigner: RelayStreamGuestSigning {
    let identity: any ClawShareGuestIdentity

    func signRelayStreamAuth(_ bytes: Data) async throws -> Data {
        try identity.sign(bytes)
    }
}
