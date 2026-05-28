//
//  AppDelegate.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftUI
import SoyehtCore
import Security
import os
import UserNotifications

private let appDelegateLogger = Logger(subsystem: "com.soyeht.mobile", category: "app-delegate")

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // iOS preserves keychain entries across `devicectl uninstall app`
        // (kSecAttrAccessibleWhenUnlocked default). If the user uninstalled
        // and reinstalled the app — or if devicectl/Xcode wiped the
        // sandbox container but the keychain survived — we need to detect
        // the fresh install and purge orphaned household / owner-identity
        // entries. Without this, `HouseholdSessionStore.load()` returns
        // a stale `ActiveHouseholdState` whose hh_id no longer matches
        // any live engine, and `QRScannerDispatcher` then rejects new
        // pair-device URIs with `firstOwnerAlreadyPaired`.
        //
        // Heuristic: an "install marker" in UserDefaults. UserDefaults
        // is wiped on app uninstall (container nuked); keychain is not.
        // Missing marker + non-empty keychain household entry = fresh
        // install with orphan keychain → purge.
        FreshInstallKeychainSweeper.sweepIfNeeded()

        Typography.bootstrap()
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        assert(Typography.isRegistered(), "[Typography] JetBrains Mono failed to register. Check SoyehtCore Resources/Fonts bundling.")
        #endif
        // Lazily create (or read) this phone's stable pairing identity before any
        // QR scan can run. Lives in the Keychain; no network call.
        _ = PairedMacsStore.shared.ensureDeviceID()
        // Bootstrap presence clients for every already-paired Mac so the home
        // list starts populating as soon as the user opens the app.
        PairedMacRegistry.shared.bootstrap()
        // One-shot legacy import into the unified ServerStore (Phase 3 of the
        // Server-unification plan). Idempotent: a sentinel inside
        // `ServerStore` makes this a no-op after the first successful run,
        // so it is safe to call on every launch. Legacy stores
        // (`PairedMacsStore.macs`, `SessionStore.pairedServers`) stay
        // authoritative until Phase 7 cleanup; this just mirrors them into
        // the new model so future views can consume `ServerRegistry`.
        let legacyMacSeed = PairedMacsStore.shared.macs.map { $0.toServer() }
        let legacyServerSeed = SessionStore.shared.pairedServers.map { $0.toServer() }
        ServerRegistry.shared.migrateLegacy(seed: legacyMacSeed + legacyServerSeed)
        // Keep the unified registry in sync with subsequent mutations
        // against either legacy store. After this call, any new pair
        // / rename / remove against `PairedMacsStore` or `SessionStore`
        // fires the registry's reconcile path so every UI consumer of
        // `ServerRegistry.shared.servers` stays truthful without each
        // mutation call site having to know about the mirror.
        ServerRegistry.shared.installLegacyMirror()
        // Wire the shared deploy monitor to ActivityKit on iOS. macOS keeps
        // the default no-op until Fase 5 adds a status-item replacement.
        ClawDeployMonitor.shared.activityManagerProvider = { ClawDeployActivityManager() }
        #if targetEnvironment(simulator)
        appDelegateLogger.debug("Skipping APNS device-token request on simulator")
        #else
        application.registerForRemoteNotifications()
        #endif
        if let url = launchOptions?[.url] as? URL {
            SessionStore.shared.pendingDeepLink = url
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
            }
        }
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        #if DEBUG
        if DebugLocalStateResetter.handleIfNeeded(url) {
            return true
        }
        if DebugPasteboardInjector.handleIfNeeded(url) {
            return true
        }
        #endif
        SessionStore.shared.pendingDeepLink = url
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task {
            do {
                _ = try await APNSRegistrationCoordinator.shared.handleForeground()
            } catch {
                appDelegateLogger.error("APNS foreground registration recovery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        APNsTokenRegistrar.shared.didRegister(deviceToken: deviceToken)
        Task {
            do {
                _ = try await APNSRegistrationCoordinator.shared.receiveDeviceToken(deviceToken)
            } catch {
                appDelegateLogger.error("APNS device-token registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        APNsTokenRegistrar.shared.didFailToRegister(error: error)
        appDelegateLogger.error("APNS device-token request failed: \(String(describing: error), privacy: .public)")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        HouseCreatedPushHandler.handle(userInfo)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        routeHouseCreatedPushTap(response.notification.request.content.userInfo)
    }

    @MainActor
    private func routeHouseCreatedPushTap(_ userInfo: [AnyHashable: Any]) {
        HouseCreatedPushHandler.handle(userInfo)
        guard case .houseCreated(let payload) = HouseCreatedPushHandler.parse(userInfo),
              let url = URL(string: payload.pairQrUri) else {
            return
        }
        SessionStore.shared.pendingDeepLink = url
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var installPickerRequestObserver: NSObjectProtocol?
    /// Lives for the scene's lifetime. Observes
    /// `ClawShareInviteCenter.shared.$state` and presents / dismisses
    /// the invite sheet over the current top view controller as deep
    /// links flow in.
    private var clawSharePresenter: ClawShareInviteSheetCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        #if DEBUG
        if let url = connectionOptions.urlContexts.first?.url {
            if DebugLocalStateResetter.handleIfNeeded(url) {
                return
            }
            if DebugPasteboardInjector.handleIfNeeded(url) {
                return
            }
        }
        #endif

        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = SoyehtTheme.uiBgPrimary
        window.overrideUserInterfaceStyle = SoyehtTheme.userInterfaceStyle
        self.window = window
        // Bind the claw-share invite sheet so it can rise above any
        // root view controller the rest of the scene flow installs.
        self.clawSharePresenter = ClawShareInviteSheetCoordinator(window: window)

        installPickerRequestObserver = NotificationCenter.default.addObserver(
            forName: .soyehtRequestInstallPicker,
            object: nil,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.showInstallPicker(in: window)
        }

        let launchURL = connectionOptions.urlContexts.first?.url ?? SessionStore.shared.pendingDeepLink
        if let launchURL {
            SessionStore.shared.pendingDeepLink = launchURL
        }

        let storage = CarouselSeenStorage()
        let restoredFromBackup = RestoredFromBackupDetector().detect()
        if restoredFromBackup {
            window.rootViewController = UIHostingController(rootView:
                RestoredFromBackupView { [weak window] in
                    guard let window else { return }
                    self.showMainStoryboard(in: window)
                }
            )
        } else if let launchURL, OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: launchURL) {
            showMainStoryboard(in: window)
        } else if storage.shouldShowCarousel(restoredFromBackup: restoredFromBackup) {
            showCarousel(in: window)
        } else if !Self.hasAnySetupState() {
            // Carousel already seen but the user never finished pairing —
            // re-enter the platform-pick flow instead of dumping them into
            // a no-cancel QR scanner.
            showInstallPicker(in: window)
        } else {
            showMainStoryboard(in: window)
        }

        window.makeKeyAndVisible()

        // Cold-launch subscribers may not be installed before the root view is
        // visible, so replay the URL once on the next runloop. The view layer
        // dedupes this against the persisted pending URL.
        if let launchURL {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .soyehtDeepLink, object: launchURL)
            }
        }
    }

    deinit {
        if let installPickerRequestObserver {
            NotificationCenter.default.removeObserver(installPickerRequestObserver)
        }
    }

    @MainActor
    private static func hasAnySetupState() -> Bool {
        // Single read for "is there any paired host?" — the registry
        // is the authoritative count after PR-2; the previous
        // `pairedServers || macs` OR-pair could (and did) disagree
        // with itself when the two stores diverged. Don't silently
        // re-onboard on decode failure: log loudly so a corrupted
        // keychain entry doesn't masquerade as "no household".
        // Routing still falls through to InstallPicker if no other
        // state exists, but the operator now has a breadcrumb. The
        // `.unavailable(.protectedDataUnavailable)` case is intentionally
        // not logged — pre-first-unlock cold launch is normal and the
        // `protectedDataDidBecomeAvailable` observer in `SoyehtIdentity`
        // resolves it without operator intervention.
        let hasPairedServers = ServerRegistry.shared.count > 0
        let identity = SoyehtIdentity.shared
        if case .unavailable(.decodingFailed) = identity.state {
            appDelegateLogger.error(
                "soyeht_diag household_decode_failed_in_hasAnySetupState"
            )
        }
        return hasPairedServers || identity.isActive
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        // `soyeht://debug/reset-local-state` is the canonical no-limbo
        // escape hatch from the household home view: Settings →
        // "Leave this household" calls it to wipe local membership and
        // bounce back to the welcome carousel. Keep the handler live in
        // release builds too so the user always has a way out.
        if DebugLocalStateResetter.handleIfNeeded(url) {
            return
        }
        #if DEBUG
        if DebugPasteboardInjector.handleIfNeeded(url) {
            return
        }
        if DebugLocalStateReporter.handleIfNeeded(
            url,
            presenter: topViewController(from: window?.rootViewController)
        ) {
            return
        }
        #endif
        // Claw-share invite deep links land here. The center forwards
        // to `ClawShareInviteRouter`, persists the pending invite, and
        // publishes the acceptance state — the SwiftUI host attaches
        // `.clawShareInvitePresenter` to surface the sheet.
        if url.scheme == "soyeht", url.host == "claw-share" {
            Task { @MainActor in
                _ = await ClawShareInviteCenter.shared.handleDeepLink(url)
            }
            return
        }
        // Foreground delivery can race the SwiftUI subscriber setup, so keep both
        // paths and let the view layer dedupe the same URL if it receives it twice.
        SessionStore.shared.pendingDeepLink = url
        if OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url),
           !(window?.rootViewController is ViewController),
           let window {
            showMainStoryboard(in: window)
        }
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
    }

    private func showInstallPicker(in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            InstallPickerView(
                onMacSelected: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showProximityQuestion(in: window)
                },
                onLinuxSelected: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showLinuxPairingGuide(in: window)
                },
                onLater: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showParkingLot(in: window)
                }
            )
        )
    }

    private func showLinuxPairingGuide(in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            LinuxPairingGuideView(
                onScanPairingLink: { [weak self, weak window] in
                    guard let self, let window else { return }
                    OnboardingLaunchIntent.requestQRScanner()
                    self.showMainStoryboard(in: window)
                },
                onBack: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        )
    }

    private func showCarousel(in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            CarouselRootView { [weak self, weak window] in
                guard let self, let window else { return }
                self.showInstallPicker(in: window)
            }
        )
    }

    @MainActor
    private func showMacDownloadLink(in window: UIWindow) async {
        let invitation = await makeSetupInvitationPayload()
        window.rootViewController = UIHostingController(rootView:
            QRFallbackView(
                onContinue: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showAwaitingMac(invitation: invitation, in: window)
                },
                onCancel: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        )
    }

    private func showProximityQuestion(in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            ProximityQuestionView(
                onNearby: { [weak self, weak window] in
                    guard let self, let window else { return }
                    Task { @MainActor in
                        await self.beginMacNearbyFlow(in: window)
                    }
                },
                onLater: { [weak self, weak window] in
                    guard let self, let window else { return }
                    Task { @MainActor in
                        await self.showMacDownloadLink(in: window)
                    }
                },
                onBack: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        )
    }

    @MainActor
    private func beginMacNearbyFlow(in window: UIWindow) async {
        let invitation = await makeSetupInvitationPayload()
        showAwaitingMac(invitation: invitation, in: window)
    }

    @MainActor
    private func makeSetupInvitationPayload() async -> SetupInvitationPayload {
        let apnsToken = await captureAPNsTokenForInvitation()
        return SetupInvitationPayload(
            token: SetupInvitationToken(),
            ownerDisplayName: nil,
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600,
            iphoneApnsToken: apnsToken,
            iphoneDeviceID: PairedMacsStore.shared.deviceID,
            iphoneDeviceName: PairedMacsStore.shared.deviceName,
            iphoneDeviceModel: PairedMacsStore.shared.deviceModel
        )
    }

    @MainActor
    private func captureAPNsTokenForInvitation() async -> Data? {
        if let cached = APNsTokenRegistrar.shared.persistedToken() {
            return cached
        }
        #if targetEnvironment(simulator)
        return nil
        #else
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await APNsTokenRegistrar.shared.requestAndCapture() }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CancellationError()
                }
                guard let token = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return token
            }
        } catch {
            appDelegateLogger.warning("Continuing setup without APNS token: \(String(describing: error), privacy: .public)")
            return APNsTokenRegistrar.shared.persistedToken()
        }
        #endif
    }

    private func showAwaitingMac(invitation: SetupInvitationPayload, in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            AwaitingMacView(
                invitation: invitation,
                onMacFound: { [weak self, weak window] result in
                    guard let self, let window else { return }
                    switch result {
                    case .needsNaming(let engineURL, let tokenBytes):
                        self.showHouseNaming(engineURL: engineURL, tokenBytes: tokenBytes, in: window)
                    case .connectedToExistingMac:
                        self.showMainStoryboard(in: window)
                    }
                },
                onCancel: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                },
                onUseDownloadLink: { [weak self, weak window] in
                    guard let self, let window else { return }
                    Task { @MainActor in
                        await self.showMacDownloadLink(in: window)
                    }
                },
                onSwitchToLinux: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showLinuxPairingGuide(in: window)
                }
            )
        )
    }

    private func showHouseNaming(engineURL: URL, tokenBytes: Data, in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            HouseNamingFromiPhoneView(
                macEngineBaseURL: engineURL,
                claimToken: tokenBytes,
                onNamed: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showMainStoryboard(in: window)
                },
                onBack: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        )
    }

    private func showParkingLot(in window: UIWindow) {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: "parking_lot_visited_at")
        window.rootViewController = UIHostingController(rootView:
            LaterParkingLotView(
                onDismiss: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showMainStoryboard(in: window)
                },
                onBack: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        )
    }

    private func showMainStoryboard(in window: UIWindow) {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        window.rootViewController = storyboard.instantiateInitialViewController()
    }

    private func topViewController(from root: UIViewController?) -> UIViewController {
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return root ?? UIViewController()
    }
}

enum OnboardingDeepLinkRouter {
    static func shouldOpenMainStoryboard(for url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else {
            return false
        }

        if scheme == "soyeht",
           components.host == "household",
           components.path == "/pair-device" {
            return true
        }

        guard scheme == "theyos" else {
            return false
        }

        switch components.host {
        case "pair", "connect", "invite":
            return true
        default:
            return false
        }
    }
}

private extension Data {
    func soyehtBase64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Handles `soyeht://debug/reset-local-state`. Originally a developer
/// tool gated behind `#if DEBUG`, now ungated so Settings →
/// "Leave this household" has a real exit path in release builds too.
///
/// `soyeht://` is a public CFBundleURLScheme — any installed app can
/// `UIApplication.open` this URL, and Shortcuts / AirDrop'd `.url` files
/// can deliver it without user prompt. To prevent any external caller
/// from wiping membership + SE keys + `exit(0)`'ing the app, the
/// destructive path is gated by `armedFromSettings` which only the
/// in-app Settings "Leave household" confirmation flips on. Each arm
/// is one-shot: consumed by the next URL delivery, then cleared.
///
/// The flow: wipe UserDefaults + keychain (mobile + household services
/// + Secure Enclave EC keys), then `exit(0)` so the next launch starts
/// from the welcome carousel.
/// Detects fresh-install scenarios where the iOS app's sandbox
/// container was wiped (devicectl uninstall, App Store reinstall, Xcode
/// destroy-then-reinstall) but the system keychain retained
/// `kSecAttrAccessibleWhenUnlocked` entries from a previous install.
/// On detection, purges household session + owner identity P-256 keys
/// so the first launch starts truly fresh.
///
/// Marker key lives in `UserDefaults.standard` (which IS wiped with the
/// sandbox container). Presence of the marker = container has been
/// initialized before; absence = first launch in this container.
///
/// Why this matters: without the sweep, after
/// `devicectl uninstall app && devicectl install app`,
/// `HouseholdSessionStore.load()` returns the previous install's
/// `ActiveHouseholdState`. The QRScannerDispatcher then rejects new
/// pair-device URIs with `firstOwnerAlreadyPaired`, and the iPhone
/// signing path produces "This iPhone could not sign the join approval"
/// because the keychain references no-longer-loadable owner keys.
///
/// Scope: runs in BOTH release and debug. The sweep is non-destructive
/// in the legitimate fresh-install path (no real user data to lose),
/// and it eliminates a class of "I uninstalled and reinstalled, why am
/// I still in the old household?" support tickets.
enum FreshInstallKeychainSweeper {
    private static let installMarkerKey = "soyeht.install.markerV1"

    static func sweepIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: installMarkerKey) != nil {
            return
        }
        appDelegateLogger.log("fresh-install detected: sweeping orphan keychain entries")
        KeychainHelper(service: "com.soyeht.mobile").deleteAll()
        KeychainHelper(service: "com.soyeht.household").deleteAll()
        for tokenID in [kSecAttrTokenIDSecureEnclave, nil as CFString?] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if let tokenID {
                query[kSecAttrTokenID as String] = tokenID
            }
            var status = errSecSuccess
            var iterations = 0
            repeat {
                status = SecItemDelete(query as CFDictionary)
                iterations += 1
            } while status == errSecSuccess && iterations < 8
        }
        defaults.set(UUID().uuidString, forKey: installMarkerKey)
        defaults.synchronize()
        appDelegateLogger.log("fresh-install sweep completed")
    }

    /// Test seam: lets unit tests force a "fresh install" by clearing
    /// the marker without going through a real uninstall cycle.
    static func clearMarkerForTesting() {
        UserDefaults.standard.removeObject(forKey: installMarkerKey)
    }
}

/// Debug-only helper that injects a string into `UIPasteboard.general`
/// via deep link. Lets e2e automation seed the iPhone's clipboard with a
/// specific pair-device / pair-machine URI before the user lands on the
/// paste-link screen — bypasses the iOS Universal Clipboard + system
/// pasteboard caching that otherwise serves stale prior content.
///
/// URL format: `soyeht://debug/set-pasteboard?url=<percent-encoded payload>`
///
/// Release builds completely ignore this URL (`#if DEBUG` gates the
/// caller). No security surface added in release.
///
/// Justification under PR fix/post-merge-recovery 2026-05-21: 8-flow
/// validation required injecting distinct pair-device / pair-machine
/// URIs in sequence into the iPhone's paste field. iOS UIPasteboard is
/// system-wide and survives app uninstall + appium clipboard set, so
/// neither `pbcopy` (Universal Clipboard) nor
/// `mobile: setPasteboard` reliably overwrites stale prior content.
/// This handler is the minimal-surface workaround.
enum DebugPasteboardInjector {
    @MainActor static func handleIfNeeded(_ url: URL) -> Bool {
        #if DEBUG
        guard url.scheme == "soyeht",
              url.host == "debug",
              url.path == "/set-pasteboard",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "url" })?.value
        else {
            return false
        }
        UIPasteboard.general.string = payload
        appDelegateLogger.log("debug pasteboard injection: wrote \(payload.count, privacy: .public) chars")
        return true
        #else
        _ = url
        return false
        #endif
    }
}

enum DebugLocalStateResetter {
    /// Set to `true` by Settings → "Leave household" immediately before
    /// `UIApplication.open(soyeht://debug/reset-local-state)`. The first
    /// URL delivery that finds it `true` consumes it and runs the reset;
    /// anything else (external caller, replayed URL) is refused.
    @MainActor static var armedFromSettings = false

    @MainActor static func handleIfNeeded(_ url: URL) -> Bool {
        guard url.scheme == "soyeht",
              url.host == "debug",
              url.path == "/reset-local-state" else {
            return false
        }
        #if DEBUG
        // Debug builds bypass the armed-from-Settings gate so e2e
        // automation can wipe keychain + UserDefaults between household
        // flow runs without driving Settings → "Leave household" in the
        // simulator/appium. Release builds keep the gate intact — see
        // PR #109 security fix #4 (silent membership wipe attack via
        // attacker-delivered URL). Documented under
        // docs/post-merge-recovery-plan.md (2026-05-21).
        armedFromSettings = false
        #else
        guard armedFromSettings else {
            appDelegateLogger.log("debug reset URL refused: not armed from Settings")
            return false
        }
        armedFromSettings = false
        #endif
        reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(0)
        }
        return true
    }

    private static func reset() {
        let defaults = UserDefaults.standard
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        defaults.synchronize()

        KeychainHelper(service: "com.soyeht.mobile").deleteAll()
        KeychainHelper(service: "com.soyeht.household").deleteAll()

        // Delete BOTH Secure-Enclave-resident and software-keychain owner
        // identity P-256 keys. Two separate queries because `kSecAttrTokenID`
        // is a match criterion — a single query without it matches only
        // software keys; with `kSecAttrTokenIDSecureEnclave` it matches only
        // SE-resident keys. The prior single-query reset left SE-resident
        // owner keys behind, which caused `loadOwnerIdentity` to find a
        // stale key after subsequent pair-device runs and produced
        // "This iPhone could not sign the join approval" because the
        // signing path returned `keyCreationFailed("key reference not found")`
        // when the cached personId pointer no longer matched any live key.
        //
        // Loop until `errSecItemNotFound` so multiple entries (one per
        // historical pair) are all purged in this debug-reset pass.
        deleteAllOwnerKeys(tokenID: kSecAttrTokenIDSecureEnclave)
        deleteAllOwnerKeys(tokenID: nil)

        appDelegateLogger.log("local state reset completed")
    }

    private static func deleteAllOwnerKeys(tokenID: CFString?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let tokenID {
            query[kSecAttrTokenID as String] = tokenID
        }
        var status = errSecSuccess
        var iterations = 0
        repeat {
            status = SecItemDelete(query as CFDictionary)
            iterations += 1
        } while status == errSecSuccess && iterations < 8
        if iterations > 1 {
            appDelegateLogger.log("deleted \(iterations - 1, privacy: .public) batch(es) of owner P-256 keys (tokenID=\(tokenID != nil ? "secureEnclave" : "software", privacy: .public))")
        }
    }
}

#if DEBUG

private enum DebugLocalStateReporter {
    @MainActor
    static func handleIfNeeded(_ url: URL, presenter: UIViewController) -> Bool {
        guard url.scheme == "soyeht",
              url.host == "debug",
              url.path == "/local-state" else {
            return false
        }

        let householdDescription: String
        switch SoyehtIdentity.shared.state {
        case .active(let snapshot):
            householdDescription = "household=present delegated=\(snapshot.isDelegatedDevice)"
        case .inactive:
            householdDescription = "household=missing"
        case .unknown:
            householdDescription = "household=unknown"
        case .unavailable(.protectedDataUnavailable):
            householdDescription = "household=unavailable reason=protected_data_unavailable"
        case .unavailable(.decodingFailed):
            householdDescription = "household=unavailable reason=decoding_failed"
        }

        let message = "\(householdDescription) macs=\(ServerRegistry.shared.macs.count)"
        appDelegateLogger.log("soyeht_diag debug_local_state \(message, privacy: .public)")
        let alert = UIAlertController(
            title: "Debug local state",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
        return true
    }
}
#endif
