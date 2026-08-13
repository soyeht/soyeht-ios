import Foundation
import SoyehtCore
import XCTest

@testable import Soyeht

private enum SentinelError: Error, Equatable {
    case boom
}

private struct StubActiveSharesReader: ActiveSharesReading {
    let shares: [ActiveShareDescriptor]
    let error: Error?

    init(shares: [ActiveShareDescriptor] = [], error: Error? = nil) {
        self.shares = shares
        self.error = error
    }

    func listActiveShares() async throws -> [ActiveShareDescriptor] {
        if let error { throw error }
        return shares
    }
}

private actor RecordingRevoker: ActiveShareRevoking {
    private(set) var calls: [Data] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func revokeActiveShare(slotID: Data) async throws {
        calls.append(slotID)
        if let error { throw error }
    }
}

/// In-memory, no real Keychain — same reasoning as `ActiveShareLinkCacheTests`
/// in the SoyehtCore package: these VM tests exist to prove the VIEW MODEL
/// calls its cache dependency correctly (store/prune/remove at the right
/// moments with the right slot ids), not to re-prove the cache's own
/// Keychain semantics, which are covered separately.
private final class InMemoryLinkCache: ActiveShareLinkCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data: String] = [:]
    private(set) var pruneCalls: [Set<Data>] = []
    private(set) var removeCalls: [Data] = []

    func seed(_ uri: String, forSlotID slotID: Data) {
        lock.lock(); entries[slotID] = uri; lock.unlock()
    }

    func store(uri: String, forSlotID slotID: Data) -> Bool {
        lock.lock(); entries[slotID] = uri; lock.unlock()
        return true
    }

    func uri(forSlotID slotID: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[slotID]
    }

    func remove(forSlotID slotID: Data) {
        lock.lock()
        entries.removeValue(forKey: slotID)
        removeCalls.append(slotID)
        lock.unlock()
    }

    func prune(keeping keepSlotIDs: Set<Data>) {
        lock.lock()
        pruneCalls.append(keepSlotIDs)
        entries = entries.filter { keepSlotIDs.contains($0.key) }
        lock.unlock()
    }
}

private final class RecordingClipboard: ClipboardWriting, @unchecked Sendable {
    let requiresMainThread = false
    private(set) var written: [String] = []

    func writeString(_ value: String) {
        written.append(value)
    }
}

@MainActor
final class ActiveSharesViewModelTests: XCTestCase {
    private func descriptor(
        slotId: Data,
        appId: String = "app_" + String(repeating: "1", count: 32),
        displayName: String = "Study",
        status: ActiveShareStatus,
        readiness: ShareReadiness = .running,
        createdAt: UInt64 = 1_000,
        expiresAt: UInt64 = 9_000,
        acceptedAt: UInt64? = nil,
        revokedAt: UInt64? = nil
    ) -> ActiveShareDescriptor {
        ActiveShareDescriptor(
            slotId: slotId, appId: appId, displayName: displayName, status: status,
            readiness: readiness, createdAt: createdAt, expiresAt: expiresAt,
            acceptedAt: acceptedAt, revokedAt: revokedAt
        )
    }

    private func makeModel(
        shares: [ActiveShareDescriptor] = [],
        readerError: Error? = nil,
        revoker: RecordingRevoker = RecordingRevoker(),
        linkCache: InMemoryLinkCache = InMemoryLinkCache(),
        clipboard: RecordingClipboard = RecordingClipboard(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 5_000) }
    ) -> ActiveSharesViewModel {
        ActiveSharesViewModel(
            reader: StubActiveSharesReader(shares: shares, error: readerError),
            revoker: revoker,
            linkCache: linkCache,
            clipboard: clipboard,
            now: now
        )
    }

    // MARK: - Load

    func test_loadPopulatesRowsFromTheReader() async {
        let slotId = Data(repeating: 0x01, count: 16)
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .waiting)])

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].id, slotId)
        XCTAssertEqual(model.rows[0].status, .waiting)
    }

    func test_loadFailureSurfacesACuratedMessage() async {
        let model = makeModel(readerError: SentinelError.boom)

        await model.load()

        guard case .failed(let message) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, "boom")
    }

    // MARK: - Copy Link eligibility

    func test_copyLinkEligibleOnlyWhenWaitingUnexpiredAndCached() async {
        let waitingCached = Data(repeating: 0x02, count: 16)
        let waitingUncached = Data(repeating: 0x03, count: 16)
        let acceptedCached = Data(repeating: 0x04, count: 16)
        let expiredCached = Data(repeating: 0x05, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=w", forSlotID: waitingCached)
        linkCache.seed("soyeht://claw-share/v1?e=a", forSlotID: acceptedCached)
        linkCache.seed("soyeht://claw-share/v1?e=e", forSlotID: expiredCached)
        let model = makeModel(
            shares: [
                descriptor(slotId: waitingCached, status: .waiting, expiresAt: 9_000),
                descriptor(slotId: waitingUncached, status: .waiting, expiresAt: 9_000),
                descriptor(slotId: acceptedCached, status: .accepted, expiresAt: 9_000),
                // Status says waiting but expiresAt is already past `now` (5_000) —
                // the VM must re-check the clock, not trust status alone.
                descriptor(slotId: expiredCached, status: .waiting, expiresAt: 4_000),
            ],
            linkCache: linkCache
        )
        await model.load()

        let byId = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })

        XCTAssertTrue(model.canCopyLink(byId[waitingCached]!))
        XCTAssertFalse(model.canCopyLink(byId[waitingUncached]!), "no cached link")
        XCTAssertFalse(model.canCopyLink(byId[acceptedCached]!), "not waiting")
        XCTAssertFalse(model.canCopyLink(byId[expiredCached]!), "expiry already passed `now`")
    }

    func test_copyLinkWritesTheCachedUriAndFailsSilentlyWhenIneligible() async {
        let slotId = Data(repeating: 0x06, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=copy-me", forSlotID: slotId)
        let clipboard = RecordingClipboard()
        let model = makeModel(
            shares: [descriptor(slotId: slotId, status: .waiting)],
            linkCache: linkCache,
            clipboard: clipboard
        )
        await model.load()

        let copied = model.copyLink(model.rows[0])

        XCTAssertTrue(copied)
        XCTAssertEqual(clipboard.written, ["soyeht://claw-share/v1?e=copy-me"])
    }

    // MARK: - Pruning: absence and convergence

    func test_loadPrunesCacheKeepingOnlyWaitingSlotIds() async {
        let waiting = Data(repeating: 0x07, count: 16)
        let accepted = Data(repeating: 0x08, count: 16)
        let linkCache = InMemoryLinkCache()
        let model = makeModel(
            shares: [
                descriptor(slotId: waiting, status: .waiting),
                descriptor(slotId: accepted, status: .accepted),
            ],
            linkCache: linkCache
        )

        await model.load()

        XCTAssertEqual(linkCache.pruneCalls.count, 1)
        XCTAssertEqual(linkCache.pruneCalls[0], [waiting], "only the Waiting slot id must be kept")
    }

    func test_loadPruneAlsoDropsASlotAbsentFromTheFreshList() async {
        // Simulates: a slot the cache remembers from an earlier load, but the
        // fresh response no longer mentions at all (deleted/rotated away).
        // Both slots are seeded up front — `stillWaiting` must be present
        // BEFORE `load()` for its survival to actually prove prune preserves
        // a kept slot, rather than trivially reporting nil because it was
        // never cached in the first place.
        let stillWaiting = Data(repeating: 0x09, count: 16)
        let nowAbsent = Data(repeating: 0x0A, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=waiting", forSlotID: stillWaiting)
        linkCache.seed("soyeht://claw-share/v1?e=absent", forSlotID: nowAbsent)
        let model = makeModel(
            shares: [descriptor(slotId: stillWaiting, status: .waiting)],
            linkCache: linkCache
        )

        await model.load()

        XCTAssertNil(linkCache.uri(forSlotID: nowAbsent), "a slot missing from the list must be pruned")
        XCTAssertNotNil(linkCache.uri(forSlotID: stillWaiting), "a slot that IS in the fresh Waiting list must survive")
    }

    func test_loadPrunesAWaitingButAlreadyExpiredCachedLink() async {
        // status is still Waiting on the wire, but expiresAt has already
        // passed `now` — the keep-set must match `canCopyLink`'s own
        // expiry check, not just the status word, or an unusable bearer
        // link lingers in the cache indefinitely.
        let expiredWaiting = Data(repeating: 0x0F, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=expired", forSlotID: expiredWaiting)
        let model = makeModel(
            shares: [descriptor(slotId: expiredWaiting, status: .waiting, expiresAt: 4_000)],
            linkCache: linkCache
        )

        await model.load()

        XCTAssertNil(linkCache.uri(forSlotID: expiredWaiting), "an expired Waiting share's cached link must still be pruned")
    }

    func test_loadClearsHasCachedLinkForAShareThatConvergedAwayFromWaiting() async {
        let slotId = Data(repeating: 0x11, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=stale", forSlotID: slotId)
        let model = makeModel(
            shares: [descriptor(slotId: slotId, status: .accepted)],
            linkCache: linkCache
        )

        await model.load()

        XCTAssertFalse(model.rows[0].hasCachedLink, "prune already removed this slot's link before rows were built")
        XCTAssertNil(linkCache.uri(forSlotID: slotId))
    }

    // MARK: - Revoke: confirm and cancel

    func test_requestRevokeSetsPendingRevokeWithoutCallingTheRevoker() async {
        let slotId = Data(repeating: 0x0B, count: 16)
        let revoker = RecordingRevoker()
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .waiting)], revoker: revoker)
        await model.load()

        model.requestRevoke(model.rows[0])

        XCTAssertEqual(model.pendingRevoke?.id, slotId)
        let calls = await revoker.calls
        XCTAssertTrue(calls.isEmpty, "requesting must not itself revoke")
    }

    func test_cancelRevokeClearsPendingRevokeWithoutCallingTheRevoker() async {
        let slotId = Data(repeating: 0x0C, count: 16)
        let revoker = RecordingRevoker()
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .waiting)], revoker: revoker)
        await model.load()
        model.requestRevoke(model.rows[0])

        model.cancelRevoke()

        XCTAssertNil(model.pendingRevoke)
        let calls = await revoker.calls
        XCTAssertTrue(calls.isEmpty, "cancelling must never call revoke")
        XCTAssertEqual(model.rows[0].status, .waiting, "row must be untouched after cancel")
    }

    func test_confirmRevokeCallsTheRevokerMarksRowRevokedAndRemovesTheCachedLink() async {
        let slotId = Data(repeating: 0x0D, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=revoke-me", forSlotID: slotId)
        let revoker = RecordingRevoker()
        let model = makeModel(
            shares: [descriptor(slotId: slotId, status: .waiting)],
            revoker: revoker,
            linkCache: linkCache
        )
        await model.load()
        model.requestRevoke(model.rows[0])

        await model.confirmRevoke(model.rows[0])

        let calls = await revoker.calls
        XCTAssertEqual(calls, [slotId])
        XCTAssertNil(model.pendingRevoke)
        XCTAssertEqual(model.rows[0].status, .revoked, "optimistic update — no refetch needed")
        XCTAssertFalse(model.rows[0].hasCachedLink)
        XCTAssertNil(linkCache.uri(forSlotID: slotId), "cache must be pruned immediately on success, not on the next load")
        XCTAssertFalse(model.canCopyLink(model.rows[0]))
    }

    /// THE ORDERING SwiftUI ACTUALLY USES, which is what shipped broken.
    ///
    /// `confirmationDialog` dismisses *before* running the button's action.
    /// Dismissal drives `isPresented` to false, and that setter calls
    /// `cancelRevoke()`. So by the time the action runs, `pendingRevoke` is
    /// already nil.
    ///
    /// While `confirmRevoke` read `pendingRevoke` and returned early on nil,
    /// a confirmed revoke was a silent no-op: no request, no error message,
    /// dialog gone, row still Accepted. Measured on hardware 2026-08-12 — the
    /// owner confirmed a dialog promising "Whoever has this link loses access"
    /// and the guest went on interacting with the shared app.
    ///
    /// Every other test here sets `pendingRevoke` and leaves it set, so none
    /// of them could see this. This one reproduces the dismissal first.
    func test_confirmRevokeStillCallsRevokerWhenDismissalAlreadyClearedPendingRevoke() async {
        let slotId = Data(repeating: 0x1A, count: 16)
        let revoker = RecordingRevoker()
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .accepted)], revoker: revoker)
        await model.load()
        model.requestRevoke(model.rows[0])
        let target = model.rows[0]

        // The dialog's dismissal, verbatim: `isPresented` false -> cancelRevoke.
        model.cancelRevoke()
        XCTAssertNil(model.pendingRevoke, "precondition: dismissal ran first")

        await model.confirmRevoke(target)

        let calls = await revoker.calls
        XCTAssertEqual(
            calls, [slotId],
            "a confirmed revoke must reach the revocation boundary even though dismissal cleared the pending row first"
        )
        XCTAssertEqual(model.rows[0].status, .revoked)
    }

    func test_confirmRevokeFailureLeavesTheRowUnchanged() async {
        let slotId = Data(repeating: 0x0E, count: 16)
        let revoker = RecordingRevoker(error: SentinelError.boom)
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .waiting)], revoker: revoker)
        await model.load()
        model.requestRevoke(model.rows[0])

        await model.confirmRevoke(model.rows[0])

        XCTAssertNil(model.pendingRevoke)
        XCTAssertEqual(model.rows[0].status, .waiting, "a failed revoke must not change the row")
    }

    func test_confirmRevokeFailureSurfacesACuratedMessageWithoutTouchingRowOrCache() async {
        let slotId = Data(repeating: 0x12, count: 16)
        let linkCache = InMemoryLinkCache()
        linkCache.seed("soyeht://claw-share/v1?e=untouched", forSlotID: slotId)
        let revoker = RecordingRevoker(error: SentinelError.boom)
        let model = makeModel(
            shares: [descriptor(slotId: slotId, status: .waiting)],
            revoker: revoker,
            linkCache: linkCache
        )
        await model.load()
        model.requestRevoke(model.rows[0])

        await model.confirmRevoke(model.rows[0])

        let message = model.revokeFailureMessage
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.isEmpty ?? true)
        XCTAssertNotEqual(message, "boom", "must never surface the raw/localizedDescription error")
        XCTAssertEqual(model.rows[0].status, .waiting)
        XCTAssertTrue(model.rows[0].hasCachedLink, "the cache must not be touched on a failed revoke")
        XCTAssertNotNil(linkCache.uri(forSlotID: slotId))
        XCTAssertEqual(linkCache.removeCalls, [], "remove must never be called on a failed revoke")
    }

    func test_dismissRevokeFailureClearsTheMessageAndRevokeCanBeRetried() async {
        let slotId = Data(repeating: 0x13, count: 16)
        let revoker = RecordingRevoker(error: SentinelError.boom)
        let model = makeModel(shares: [descriptor(slotId: slotId, status: .waiting)], revoker: revoker)
        await model.load()
        model.requestRevoke(model.rows[0])
        await model.confirmRevoke(model.rows[0])
        XCTAssertNotNil(model.revokeFailureMessage)

        model.dismissRevokeFailure()
        XCTAssertNil(model.revokeFailureMessage)

        // Retry: the row is still intact, so requesting/confirming again
        // must be possible and must reach the revoker a second time.
        model.requestRevoke(model.rows[0])
        await model.confirmRevoke(model.rows[0])

        let calls = await revoker.calls
        XCTAssertEqual(calls, [slotId, slotId])
    }

    // MARK: - Duplicate app, independent by slot id

    func test_duplicateAppTwoSharesRevokeIndependently() async {
        let appId = "app_" + String(repeating: "9", count: 32)
        let firstSlot = Data(repeating: 0x0F, count: 16)
        let secondSlot = Data(repeating: 0x10, count: 16)
        let revoker = RecordingRevoker()
        let model = makeModel(
            shares: [
                descriptor(slotId: firstSlot, appId: appId, status: .waiting),
                descriptor(slotId: secondSlot, appId: appId, status: .waiting),
            ],
            revoker: revoker
        )
        await model.load()
        XCTAssertEqual(model.rows.count, 2, "same app, two independent rows")

        let target = model.rows.first { $0.id == secondSlot }!
        model.requestRevoke(target)
        await model.confirmRevoke(target)

        let calls = await revoker.calls
        XCTAssertEqual(calls, [secondSlot], "only the targeted slot must be revoked")
        let untouched = model.rows.first { $0.id == firstSlot }!
        XCTAssertEqual(untouched.status, .waiting, "the other share for the SAME app must be unaffected")
        let revoked = model.rows.first { $0.id == secondSlot }!
        XCTAssertEqual(revoked.status, .revoked)
    }
}
