import AppKit
import Foundation
import SoyehtCore
import os

private let forgetHomeLogger = Logger(subsystem: "com.soyeht.mac", category: "forget-home")

/// "Forget this home" — the way out of a household this Mac can no longer
/// hand to anyone.
///
/// Adding a new iPhone to a paired home needs approval from an iPhone that
/// already belongs to it. When that iPhone is lost, wiped, or replaced, the
/// new one waits for an approval that can never arrive — five minutes of
/// spinner and then a timeout, measured 2026-09-01. The recovery used to be
/// "Start over…", which opened the whole uninstaller: a window about removing
/// Soyeht, to fix a problem about a phone.
///
/// This does the same work under its own name, and stops where the honesty
/// runs out: it forgets the home **on this Mac**. On the ordinary route this
/// Mac never holds the owner signing key — the iPhone does — so there is
/// nothing here that can sign a revocation the engine would accept. The
/// household stays alive on any iPhone that still has it until someone leaves
/// it from there, and the copy says so.
///
/// Every step is injectable because the interesting thing about this service
/// is its order, and the order is worth testing without wiping a real Mac.
@MainActor
struct ForgetHomeService {

    /// What actually happened, so the caller can say it rather than guess.
    enum Outcome: Equatable {
        case forgotten(revokedRemotely: Bool)
        case failed(String)
    }

    var loadHousehold: () -> ActiveHouseholdState?
    var revokeRemotely: (ActiveHouseholdState) async -> Bool
    var unregisterLoginItem: () throws -> Void
    var stopServices: () async -> Void
    var resetLocalEngineState: () async -> Void
    var forgetLocalServers: () -> Void
    var clearHouseholdSession: () -> Void
    var revokeLocalPairings: @MainActor () -> Void
    var reopenWelcome: () -> Void

    init(
        loadHousehold: @escaping () -> ActiveHouseholdState? = { try? HouseholdSessionStore().load() },
        revokeRemotely: @escaping (ActiveHouseholdState) async -> Bool = Self.revokeRemotelyIfSignable,
        unregisterLoginItem: @escaping () throws -> Void = { try SMAppServiceInstaller.unregister() },
        stopServices: @escaping () async -> Void = { await ExistingSoyehtStopper.stopKnownServices() },
        resetLocalEngineState: @escaping () async -> Void = { await ExistingSoyehtStateResetter.resetLocalEngineState() },
        forgetLocalServers: @escaping () -> Void = Self.forgetEveryLocalServer,
        clearHouseholdSession: @escaping () -> Void = { HouseholdSessionStore().clear() },
        revokeLocalPairings: @escaping @MainActor () -> Void = { _ = PairingStore.shared.revokeAll() },
        reopenWelcome: @escaping () -> Void = Self.reopenWelcomeWindow
    ) {
        self.loadHousehold = loadHousehold
        self.revokeRemotely = revokeRemotely
        self.unregisterLoginItem = unregisterLoginItem
        self.stopServices = stopServices
        self.resetLocalEngineState = resetLocalEngineState
        self.forgetLocalServers = forgetLocalServers
        self.clearHouseholdSession = clearHouseholdSession
        self.revokeLocalPairings = revokeLocalPairings
        self.reopenWelcome = reopenWelcome
    }

    func run() async -> Outcome {
        forgetHomeLogger.log("forget_home.begin")

        // 1. Ask the engine to tear the household down properly, but only when
        //    this Mac can sign for it. On the ordinary route it cannot, and a
        //    failed revocation must not stop a local forget — otherwise the
        //    Mac stays wedged in a home whose only key is gone.
        var revokedRemotely = false
        if let household = loadHousehold() {
            revokedRemotely = await revokeRemotely(household)
            forgetHomeLogger.log("forget_home.remote_revoke succeeded=\(revokedRemotely, privacy: .public)")
        } else {
            forgetHomeLogger.log("forget_home.remote_revoke skipped=no_session")
        }

        // 2. Stop the engine the Apple way, then the launchctl fallback for
        //    legacy registrations. Before the files, so nothing is rewritten
        //    underneath the delete.
        do {
            try unregisterLoginItem()
        } catch {
            forgetHomeLogger.error("forget_home.unregister_failed error=\(String(describing: error), privacy: .public)")
        }
        await stopServices()

        // 3. Household state on disk, then the credential rows that point at
        //    it, then the iPhones paired to this Mac locally.
        await resetLocalEngineState()
        forgetLocalServers()
        clearHouseholdSession()
        revokeLocalPairings()

        // 4. The Mac has no home now, so the only honest window is the one
        //    that offers to make one.
        reopenWelcome()
        forgetHomeLogger.log("forget_home.done revoked_remotely=\(revokedRemotely, privacy: .public)")
        return .forgotten(revokedRemotely: revokedRemotely)
    }

    // MARK: - Defaults

    /// The same request the uninstaller makes. The engine refuses a teardown
    /// it cannot verify, and on the ordinary route this Mac holds no owner
    /// key to sign with — so a refusal here is an expected outcome, not an
    /// error, and it must never stop the local forget. Without that the Mac
    /// stays wedged in a home whose only key is on a phone that is gone.
    static func revokeRemotelyIfSignable(_ household: ActiveHouseholdState) async -> Bool {
        _ = household
        do {
            try await BootstrapTeardownClient(baseURL: TheyOSEnvironment.bootstrapBaseURL).teardown()
            return true
        } catch {
            forgetHomeLogger.log("forget_home.remote_revoke refused error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func forgetEveryLocalServer() {
        for id in SessionStore.shared.pairedServers.map(\.id) {
            SessionStore.shared.removeServer(id: id)
        }
        SessionStore.shared.clearSession()
        // The credential row is gone, so the id that pointed at it is a
        // dangling reference: the next launch would try to reuse a server
        // that no longer exists rather than minting a fresh one.
        LocalEngineContext.DefaultsIdentityStore().clearVerifiedServerID()
    }

    static func reopenWelcomeWindow() {
        NSApp.sendAction(#selector(AppDelegate.reopenWelcomeAfterForget(_:)), to: nil, from: nil)
    }
}
