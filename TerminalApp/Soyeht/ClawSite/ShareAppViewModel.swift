import Foundation
import SoyehtCore

/// One of the owner's apps, as offered for sharing.
struct ShareableApp: Identifiable, Equatable, Sendable {
    /// The identifier the invite carries as `claw_id`.
    ///
    /// This is the app's **name**, not its instance id, and that is
    /// deliberate: the engine treats `claw_id` as an opaque label (it does
    /// not validate it against anything), and it is literally what the guest
    /// is shown — `ClawSiteViewModel(clawName: invite.clawId)` and "Connect
    /// to \(invite.clawId)?". Sending an opaque instance id would put a UUID
    /// in front of the person you are sharing with.
    let clawID: String
    let displayName: String
    let isRunning: Bool

    var id: String { clawID }
}

/// Reads the owner's apps. Injectable so the screen is testable without a
/// live engine.
protocol ShareableAppsReading: Sendable {
    func shareableApps() async throws -> [ShareableApp]
}

/// Mints an invite for one app. Injectable for the same reason.
protocol ShareInviteMinting: Sendable {
    func mintInvite(clawID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite
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
        let instances = try await client.getHouseholdInstances()
        return instances.map { instance in
            ShareableApp(
                clawID: instance.name,
                displayName: instance.name,
                // Shown, not enforced: a stopped app can still be shared —
                // the link outlives this moment and the app may be running
                // by the time the guest opens it. Blocking the share here
                // would be guessing about the future on the owner's behalf.
                isRunning: instance.status == .active
            )
        }
    }
}

struct EngineShareInviteMinter: ShareInviteMinting {
    let client: SoyehtAPIClient

    init(client: SoyehtAPIClient = .shared) {
        self.client = client
    }

    func mintInvite(clawID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite {
        try await client.mintClawShareInvite(clawID: clawID, ttlSeconds: ttlSeconds)
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

    init(
        reader: any ShareableAppsReading = EngineShareableAppsReader(),
        minter: any ShareInviteMinting = EngineShareInviteMinter()
    ) {
        self.reader = reader
        self.minter = minter
    }

    var selectedApp: ShareableApp? {
        guard let selectedAppID else { return nil }
        return apps.first { $0.clawID == selectedAppID }
    }

    var canShare: Bool {
        if case .minting = phase { return false }
        return selectedApp != nil
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
                selectedAppID = loaded[0].clawID
            } else if let selectedAppID, !loaded.contains(where: { $0.clawID == selectedAppID }) {
                // The previously chosen app is gone; do not keep a stale
                // selection that would mint an invite for something the
                // owner can no longer see.
                self.selectedAppID = nil
            }
            phase = .picking
        } catch {
            phase = .failed(error.localizedDescription)
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
                clawID: app.clawID,
                ttlSeconds: duration.seconds
            )
            phase = .shared(
                link: invite.uri,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAt))
            )
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Back to the picker after a successful share, so the owner can send a
    /// second link without leaving. The previous link stays valid — it is a
    /// separate slot, and revoking is a different action.
    func shareAnother() {
        phase = .picking
    }
}
