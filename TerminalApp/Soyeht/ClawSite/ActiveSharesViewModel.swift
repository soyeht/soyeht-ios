import Foundation
import SoyehtCore
import os

private let activeSharesLogger = Logger(subsystem: "com.soyeht.mobile", category: "active-shares")

/// One row the Active Shares screen renders — the server descriptor plus
/// whether THIS device has a cached bearer link for it. `hasCachedLink` is
/// never sent by the server; it is purely a local fact about this device's
/// Keychain.
struct ActiveShareRow: Identifiable, Equatable {
    let descriptor: ActiveShareDescriptor
    let hasCachedLink: Bool

    var id: Data { descriptor.slotId }
    var displayName: String { descriptor.displayName }
    var status: ActiveShareStatus { descriptor.status }
    var readiness: ShareReadiness { descriptor.readiness }

    /// Copy Link only for a share that is still Waiting, still has time left
    /// (checked again against `now` rather than trusting `status == .waiting`
    /// alone — the list may be a little stale by the time this renders), and
    /// that this device actually holds a cached bearer link for.
    func canCopyLink(now: Date) -> Bool {
        status == .waiting
            && hasCachedLink
            && Date(timeIntervalSince1970: TimeInterval(descriptor.expiresAt)) > now
    }

    /// Only a still-active share is worth offering to stop — Expired/Revoked
    /// already ended, and re-revoking them from this screen has nothing to
    /// confirm.
    var canStopSharing: Bool {
        status == .waiting || status == .accepted
    }

    /// "Created <label> · Expires <label>" — shown on every row regardless
    /// of status, per §5.3's requirement that creation and expiration are
    /// always unambiguous, not just implied by the status word.
    func lifetimeText(formatter: any ActiveShareDateFormatting, now: Date) -> String {
        let created = formatter.label(
            for: Date(timeIntervalSince1970: TimeInterval(descriptor.createdAt)), now: now)
        let expires = formatter.label(
            for: Date(timeIntervalSince1970: TimeInterval(descriptor.expiresAt)), now: now)
        return "Created \(created) · Expires \(expires)"
    }

    /// The status word, augmented with the status-defining timestamp where
    /// one exists: Accepted always carries `accepted_at` (the server sets it
    /// the instant status flips to accepted), Revoked carries `revoked_at`
    /// only when present (a stale read can observe Revoked before that
    /// timestamp arrives — "Revoked" alone is still correct, just less
    /// precise). Never a guest key or any other identifier — only the status
    /// word and a timestamp.
    func statusText(formatter: any ActiveShareDateFormatting, now: Date) -> String {
        switch status {
        case .waiting:
            return "Waiting"
        case .expired:
            return "Expired"
        case .accepted:
            guard let acceptedAt = descriptor.acceptedAt else { return "Accepted" }
            let label = formatter.label(
                for: Date(timeIntervalSince1970: TimeInterval(acceptedAt)), now: now)
            return "Accepted · \(label)"
        case .revoked:
            guard let revokedAt = descriptor.revokedAt else { return "Revoked" }
            let label = formatter.label(
                for: Date(timeIntervalSince1970: TimeInterval(revokedAt)), now: now)
            return "Revoked · \(label)"
        }
    }
}

protocol ActiveSharesReading: Sendable {
    func listActiveShares() async throws -> [ActiveShareDescriptor]
}

protocol ActiveShareRevoking: Sendable {
    func revokeActiveShare(slotID: Data) async throws
}

struct EngineActiveSharesReader: ActiveSharesReading {
    let client: SoyehtAPIClient

    init(client: SoyehtAPIClient = .shared) {
        self.client = client
    }

    func listActiveShares() async throws -> [ActiveShareDescriptor] {
        try await client.listActiveShares()
    }
}

struct EngineActiveShareRevoker: ActiveShareRevoking {
    let client: SoyehtAPIClient

    init(client: SoyehtAPIClient = .shared) {
        self.client = client
    }

    func revokeActiveShare(slotID: Data) async throws {
        try await client.revokeActiveShare(slotID: slotID)
    }
}

/// The owner's "who has, had, or could still get to my stuff" screen —
/// lists the owner's presentation-backed share records (Waiting/Accepted/
/// Expired/Revoked, a revocable lifecycle history, not only the currently
/// reachable ones) and lets the owner stop one.
@MainActor
final class ActiveSharesViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var rows: [ActiveShareRow] = []
    /// Set by the view when the owner taps Stop Sharing; presenting the
    /// destructive confirmation is the view's job, this only tracks WHICH
    /// row so the decision (confirm/cancel) is testable without SwiftUI.
    @Published var pendingRevoke: ActiveShareRow?
    /// A curated (never `error.localizedDescription`, never raw) message the
    /// view shows after a failed `confirmRevoke()`. The row and cache are
    /// untouched on this path, so dismissing just clears the message — the
    /// owner retries by tapping Stop Sharing again on the still-intact row.
    @Published var revokeFailureMessage: String?

    private let reader: any ActiveSharesReading
    private let revoker: any ActiveShareRevoking
    private let linkCache: any ActiveShareLinkCaching
    private let clipboard: any ClipboardWriting
    private let now: @Sendable () -> Date

    init(
        reader: any ActiveSharesReading = EngineActiveSharesReader(),
        revoker: any ActiveShareRevoking = EngineActiveShareRevoker(),
        linkCache: any ActiveShareLinkCaching = KeychainActiveShareLinkCache(),
        clipboard: any ClipboardWriting = UIPasteboardClipboard(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.revoker = revoker
        self.linkCache = linkCache
        self.clipboard = clipboard
        self.now = now
    }

    func load() async {
        phase = .loading
        do {
            let descriptors = try await reader.listActiveShares()
            let loadedAt = now()
            // The keep-set must match the cache's own contract exactly — the
            // same "still Waiting AND not yet expired" test `canCopyLink`
            // applies — otherwise a share whose clock has already run out
            // client-side, but whose wire status hasn't flipped to Expired
            // yet, keeps its bearer link cached indefinitely. A single
            // `loadedAt` (not `now()` called per-descriptor) keeps the whole
            // pass consistent against one instant. Converged-away statuses
            // and slots absent from the fresh list are both simply outside
            // this set — nothing else needs to be kept.
            let waitingSlotIDs = Set(
                descriptors
                    .filter { $0.status == .waiting && Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) > loadedAt }
                    .map(\.slotId)
            )
            // Prune BEFORE reading `hasCachedLink` for the rows below —
            // otherwise a share that just converged away (or expired) would
            // report a cached link for the instant between the read and the
            // prune that removes it, which is a lie about local state even
            // though today's Copy Link gating happens to mask it.
            linkCache.prune(keeping: waitingSlotIDs)
            rows = descriptors.map { descriptor in
                ActiveShareRow(
                    descriptor: descriptor,
                    hasCachedLink: linkCache.uri(forSlotID: descriptor.slotId) != nil
                )
            }
            phase = .loaded
        } catch {
            activeSharesLogger.error("loading active shares failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(String(
                localized: "activeShares.error.loadFailed",
                defaultValue: "Couldn't load your active shares. Check your connection and try again.",
                comment: "Shown when the Active Shares list fails to load."
            ))
        }
    }

    func requestRevoke(_ row: ActiveShareRow) {
        pendingRevoke = row
    }

    func cancelRevoke() {
        pendingRevoke = nil
    }

    /// Revokes `target`. On success: removes the cached link immediately (not
    /// waiting for the next `load()` to prune it) and marks the row Revoked
    /// optimistically — the device that just revoked already knows the
    /// outcome, no refetch needed. On failure, the row is left exactly as it
    /// was so the owner can just try again.
    ///
    /// TAKES THE ROW RATHER THAN READING `pendingRevoke`. It used to read it,
    /// and `guard let target = pendingRevoke else { return }` made the whole
    /// call a silent no-op: SwiftUI dismisses a `confirmationDialog` before
    /// running the button's action, the dismissal drives `isPresented` to
    /// false, and that setter calls `cancelRevoke()` — so by the time this ran,
    /// `pendingRevoke` was already nil. No request, no error, dialog gone, row
    /// untouched. Measured on hardware 2026-08-12: the owner confirmed a
    /// dialog promising "Whoever has this link loses access" and the guest
    /// kept interacting with the shared app.
    ///
    /// Acting on the value the dialog displayed removes the dependence on
    /// mutable state that dismissal races, and is what the caller means: revoke
    /// the share this dialog named.
    func confirmRevoke(_ target: ActiveShareRow) async {
        pendingRevoke = nil
        do {
            try await revoker.revokeActiveShare(slotID: target.descriptor.slotId)
            linkCache.remove(forSlotID: target.descriptor.slotId)
            guard let index = rows.firstIndex(where: { $0.id == target.id }) else { return }
            let revoked = target.descriptor
            rows[index] = ActiveShareRow(
                descriptor: ActiveShareDescriptor(
                    slotId: revoked.slotId,
                    appId: revoked.appId,
                    displayName: revoked.displayName,
                    status: .revoked,
                    readiness: revoked.readiness,
                    createdAt: revoked.createdAt,
                    expiresAt: revoked.expiresAt,
                    acceptedAt: revoked.acceptedAt,
                    revokedAt: UInt64(max(0, now().timeIntervalSince1970))
                ),
                hasCachedLink: false
            )
        } catch {
            activeSharesLogger.error("revoking share failed: \(error.localizedDescription, privacy: .private)")
            revokeFailureMessage = String(
                localized: "activeShares.error.revokeFailed",
                defaultValue: "Couldn't stop sharing. Check your connection and try again.",
                comment: "Shown when Stop Sharing fails; the share stays active and can be retried."
            )
        }
    }

    func dismissRevokeFailure() {
        revokeFailureMessage = nil
    }

    func canCopyLink(_ row: ActiveShareRow) -> Bool {
        row.canCopyLink(now: now())
    }

    @discardableResult
    func copyLink(_ row: ActiveShareRow) -> Bool {
        guard canCopyLink(row), let uri = linkCache.uri(forSlotID: row.descriptor.slotId) else { return false }
        clipboard.writeString(uri)
        return true
    }
}
