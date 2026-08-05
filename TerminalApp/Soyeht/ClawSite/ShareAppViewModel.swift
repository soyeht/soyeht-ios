import Foundation
import SoyehtCore
import os

/// Diagnostic-only sink for raw load/mint errors. Plan §5.4: "Raw
/// localizedDescription is diagnostics-only" — logged for support/debugging,
/// never rendered in the owner-facing UI.
private let shareAppLogger = Logger(subsystem: "com.soyeht.mobile", category: "share-app")

/// One of the owner's apps, as offered for sharing.
///
/// Identified by `appID` — the D6 `shareable_apps` binding's own CSPRNG
/// identity, never the app's display name or `SoyehtInstance.id`. Two apps
/// may legitimately share a `displayName`; `appID` is what keeps their rows,
/// selection, and minted invites independent.
struct ShareableApp: Identifiable, Equatable, Sendable {
    let appID: String
    let displayName: String
    let readiness: ShareReadiness

    var id: String { appID }

    /// D1 shorthand: everything except `.running` is "not usable right now,"
    /// shown as a warning, never as a block on sharing.
    var isRunning: Bool { readiness.isRunning }
}

/// Reads the owner's apps. Injectable so the screen is testable without a
/// live engine.
protocol ShareableAppsReading: Sendable {
    func shareableApps() async throws -> [ShareableApp]
}

/// Mints an invite for one app, identified by its D6 `appID` — never a
/// `claw_id`/instance name. Injectable for the same reason as the reader.
protocol ShareInviteMinting: Sendable {
    func mintInvite(appID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite
}

struct EngineShareableAppsReader: ShareableAppsReading {
    let client: SoyehtAPIClient

    init(client: SoyehtAPIClient = .shared) {
        self.client = client
    }

    func shareableApps() async throws -> [ShareableApp] {
        // No endpoint argument on purpose: the client resolves the active
        // household itself, the same way the mint call does. Passing one in
        // would mean reading `ActiveHouseholdState.endpoint` at the call site,
        // which is ratcheted so endpoint resolution stays behind one seam.
        let descriptors = try await client.listShareableApps()
        return descriptors.map { descriptor in
            ShareableApp(
                appID: descriptor.appId,
                displayName: descriptor.displayName,
                readiness: descriptor.readiness
            )
        }
    }
}

struct EngineShareInviteMinter: ShareInviteMinting {
    let client: SoyehtAPIClient

    init(client: SoyehtAPIClient = .shared) {
        self.client = client
    }

    func mintInvite(appID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite {
        try await client.mintClawShareInvite(appID: appID, ttlSeconds: ttlSeconds)
    }
}

/// Owner-side "share one of my apps with someone" flow.
///
/// This lives on iOS, not on the Mac, because minting requires a
/// proof-of-possession signed by the **owner person** key
/// (`household_auth::authorize_request` compares `pop.p_id` against
/// `owner_auth.owner_person_cert.p_id`), and that key is in this device's
/// Secure Enclave. The Mac is the household *machine*; it cannot sign as the
/// owner *person*, which is why the Mac-side share window could never
/// authenticate for a household paired from an iPhone.
@MainActor
final class ShareAppViewModel: ObservableObject {
    enum Duration: String, CaseIterable, Identifiable {
        case fifteenMinutes, oneHour, oneDay

        var id: String { rawValue }

        /// Each value is annotated rather than left to inference: an
        /// integer expression in a `UInt64` position is accepted by some
        /// Swift toolchains and rejected by others, and CI runs a different
        /// Xcode than this repo's local default.
        var seconds: UInt64 {
            switch self {
            case .fifteenMinutes:
                let value: UInt64 = 15 * 60
                return value
            case .oneHour:
                let value: UInt64 = 60 * 60
                return value
            case .oneDay:
                let value: UInt64 = 24 * 60 * 60
                return value
            }
        }

        var label: String {
            switch self {
            case .fifteenMinutes:
                return String(localized: "shareApp.duration.15min", defaultValue: "15 minutes",
                              comment: "How long a share link stays valid.")
            case .oneHour:
                return String(localized: "shareApp.duration.1hour", defaultValue: "1 hour",
                              comment: "How long a share link stays valid.")
            case .oneDay:
                return String(localized: "shareApp.duration.1day", defaultValue: "24 hours",
                              comment: "How long a share link stays valid.")
            }
        }
    }

    /// Which day an expiry falls on, relative to now — pure `Calendar` day
    /// arithmetic, no formatting or localized text involved. Kept separate
    /// from `unambiguousExpiryLabel` so tests can assert on this (locale-
    /// independent) instead of matching substrings of localized output.
    enum ExpiryDayQualifier: Equatable {
        case today
        case tomorrow
        case other
    }

    static func expiryDayQualifier(
        for expiresAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ExpiryDayQualifier {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfExpiryDay = calendar.startOfDay(for: expiresAt)
        let dayOffset = calendar.dateComponents([.day], from: startOfToday, to: startOfExpiryDay).day ?? 0
        switch dayOffset {
        case 0: return .today
        case 1: return .tomorrow
        default: return .other
        }
    }

    /// A clock time alone is ambiguous the moment the expiry is not today — "5:00 PM"
    /// could be in three hours or in twenty-three. Always resolve the day first so a
    /// 24-hour invitation never renders as a bare, dateless time.
    static func unambiguousExpiryLabel(
        for expiresAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let time = expiresAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        )

        switch expiryDayQualifier(for: expiresAt, now: now, calendar: calendar) {
        case .today:
            let dayWord = String(
                localized: "shareApp.expiry.today",
                defaultValue: "Today",
                comment: "Day qualifier for a link that expires later today."
            )
            return "\(dayWord) at \(time)"
        case .tomorrow:
            let dayWord = String(
                localized: "shareApp.expiry.tomorrow",
                defaultValue: "Tomorrow",
                comment: "Day qualifier for a link that expires tomorrow."
            )
            return "\(dayWord) at \(time)"
        case .other:
            // Far enough out (or, for a negative offset, already past) that
            // "Today"/"Tomorrow" would stop being unambiguous on their own —
            // spell out the date instead.
            return expiresAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
            )
        }
    }

    enum Phase: Equatable {
        case loading
        case picking
        /// Minting is its own phase so the button cannot be tapped twice —
        /// each mint consumes a fresh slot on the engine, and a double tap
        /// would silently burn one.
        case minting
        case shared(link: String, expiresAt: Date)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var apps: [ShareableApp] = []
    @Published var selectedAppID: String?
    @Published var duration: Duration = .oneHour

    private let reader: any ShareableAppsReading
    private let minter: any ShareInviteMinting
    private let clipboard: any ClipboardWriting
    private let linkCache: any ActiveShareLinkCaching

    init(
        reader: any ShareableAppsReading = EngineShareableAppsReader(),
        minter: any ShareInviteMinting = EngineShareInviteMinter(),
        clipboard: any ClipboardWriting = UIPasteboardClipboard(),
        linkCache: any ActiveShareLinkCaching = KeychainActiveShareLinkCache()
    ) {
        self.reader = reader
        self.minter = minter
        self.clipboard = clipboard
        self.linkCache = linkCache
    }

    var selectedApp: ShareableApp? {
        guard let selectedAppID else { return nil }
        return apps.first { $0.appID == selectedAppID }
    }

    var canShare: Bool {
        if case .minting = phase { return false }
        return selectedApp != nil
    }

    /// D1 (warn-and-allow): whether the stopped-app warning should be shown
    /// for the currently selected app. Exposed as VM state — not recomputed
    /// inline in the view — so the condition, and that it never blocks
    /// `canShare`/minting, can be tested without rendering SwiftUI.
    var showsStoppedAppWarning: Bool {
        guard let selectedApp else { return false }
        return !selectedApp.isRunning
    }

    func load() async {
        phase = .loading
        do {
            let loaded = try await reader.shareableApps()
            apps = loaded
            // Preselect when there is exactly one app: with a single choice
            // there is nothing to choose, and making the person tap it first
            // is friction, not confirmation.
            if loaded.count == 1 {
                selectedAppID = loaded[0].appID
            } else if let selectedAppID, !loaded.contains(where: { $0.appID == selectedAppID }) {
                // The previously chosen app is gone; do not keep a stale
                // selection that would mint an invite for something the
                // owner can no longer see.
                self.selectedAppID = nil
            }
            phase = .picking
        } catch {
            shareAppLogger.error("loading shareable apps failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(String(
                localized: "shareApp.error.loadFailed",
                defaultValue: "Couldn't load your apps. Check your connection and try again.",
                comment: "Shown when the owner's app list fails to load."
            ))
        }
    }

    func share() async {
        guard let app = selectedApp else { return }
        // Refuse a second concurrent mint: each one consumes a fresh slot on
        // the engine, so a double tap would silently burn one.
        if case .minting = phase { return }

        phase = .minting
        do {
            let invite = try await minter.mintInvite(
                appID: app.appID,
                ttlSeconds: duration.seconds
            )
            // Immediately, before the phase even changes: the bearer link
            // exists nowhere else once minted (the server wire never carries
            // it back out, and it must not — see `ActiveShareLinkCaching`),
            // so failing to cache it here means Copy Link can never work for
            // this share again from Active Shares. The link on THIS screen,
            // right now, is unaffected either way — only future Copy Link
            // from Active Shares depends on the write succeeding.
            if !linkCache.store(uri: invite.uri, forSlotID: invite.slotId) {
                // Never log `invite.uri` itself here — only that the write
                // failed, matching the diagnostics-only discipline (§5.4)
                // this file already follows for every other raw value.
                shareAppLogger.error("caching the minted share link failed; Copy Link will be unavailable for this share from Active Shares")
            }
            phase = .shared(
                link: invite.uri,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAt))
            )
        } catch {
            shareAppLogger.error("minting invite failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(String(
                localized: "shareApp.error.mintFailed",
                defaultValue: "Couldn't create the link. Check your connection and try again.",
                comment: "Shown when creating a share invite fails."
            ))
        }
    }

    /// Back to the picker after a successful share, so the owner can send a
    /// second link without leaving. The previous link stays valid — it is a
    /// separate slot, and revoking is a different action.
    func shareAnother() {
        phase = .picking
    }

    /// The link is the credential, so it stays reachable even once it is no
    /// longer the primary thing on screen (§5.2: "Do not show the bearer link
    /// as the primary content. Provide Copy Link ... as secondary actions.").
    @discardableResult
    func copyLink() -> Bool {
        guard case .shared(let link, _) = phase else { return false }
        clipboard.writeString(link)
        return true
    }
}
