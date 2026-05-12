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
        // Wire the shared deploy monitor to ActivityKit on iOS. macOS keeps
        // the default no-op until Fase 5 adds a status-item replacement.
        ClawDeployMonitor.shared.activityManagerProvider = { ClawDeployActivityManager() }
        #if targetEnvironment(simulator)
        appDelegateLogger.debug("Skipping APNS device-token request on simulator")
        #else
        application.registerForRemoteNotifications()
        #endif
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
        CasaNasceuPushHandler.handle(userInfo)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        routeCasaNasceuPushTap(response.notification.request.content.userInfo)
    }

    @MainActor
    private func routeCasaNasceuPushTap(_ userInfo: [AnyHashable: Any]) {
        CasaNasceuPushHandler.handle(userInfo)
        guard case .casaNasceu(let payload) = CasaNasceuPushHandler.parse(userInfo),
              let url = URL(string: payload.pairQrUri) else {
            return
        }
        SessionStore.shared.pendingDeepLink = url
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        #if DEBUG
        if let url = connectionOptions.urlContexts.first?.url,
           DebugLocalStateResetter.handleIfNeeded(url) {
            return
        }
        #endif

        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = SoyehtTheme.uiBgPrimary
        window.overrideUserInterfaceStyle = SoyehtTheme.userInterfaceStyle
        self.window = window

        let storage = CarouselSeenStorage()
        let restoredFromBackup = RestoredFromBackupDetector().detect()
        if restoredFromBackup {
            window.rootViewController = UIHostingController(rootView:
                RestoredFromBackupView { [weak window] in
                    guard let window else { return }
                    self.showMainStoryboard(in: window)
                }
            )
        } else if storage.shouldShowCarousel(restoredFromBackup: restoredFromBackup) {
            window.rootViewController = UIHostingController(rootView:
                CarouselRootView { [weak window] in
                    guard let window else { return }
                    self.showInstallPicker(in: window)
                }
            )
        } else {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            window.rootViewController = storyboard.instantiateInitialViewController()
        }

        window.makeKeyAndVisible()

        // Cold launch via deep link
        if let url = connectionOptions.urlContexts.first?.url {
            SessionStore.shared.pendingDeepLink = url
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        #if DEBUG
        if DebugLocalStateResetter.handleIfNeeded(url) {
            return
        }
        #endif
        // Foreground delivery can race the SwiftUI subscriber setup, so keep both
        // paths and let the view layer dedupe the same URL if it receives it twice.
        SessionStore.shared.pendingDeepLink = url
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
    }

    private func showInstallPicker(in window: UIWindow) {
        window.rootViewController = UIHostingController(rootView:
            InstallPickerView(
                onMacSelected: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showProximityQuestion(in: window)
                },
                onLater: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showParkingLot(in: window)
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
                    self.showParkingLot(in: window)
                }
            )
        )
    }

    @MainActor
    private func beginMacNearbyFlow(in window: UIWindow) async {
        let invitation = await makeSetupInvitationPayload()
        let presenter = AirDropPresenter(presentingViewController: topViewController(from: window.rootViewController))
        let result = await presenter.present()

        switch result {
        case .success:
            showAwaitingMac(invitation: invitation, in: window)
        case .fallback:
            window.rootViewController = UIHostingController(rootView:
                QRFallbackView(
                    onContinue: { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.showAwaitingMac(invitation: invitation, in: window)
                    },
                    onCancel: { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.showMainStoryboard(in: window)
                    }
                )
            )
        }
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
                onMacFound: { [weak self, weak window] engineURL, tokenBytes in
                    guard let self, let window else { return }
                    self.showHouseNaming(engineURL: engineURL, tokenBytes: tokenBytes, in: window)
                },
                onCancel: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.showMainStoryboard(in: window)
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

private extension Data {
    func soyehtBase64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if DEBUG
private enum DebugLocalStateResetter {
    static func handleIfNeeded(_ url: URL) -> Bool {
        guard url.scheme == "soyeht",
              url.host == "debug",
              url.path == "/reset-local-state" else {
            return false
        }
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

        let ownerKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(ownerKeyQuery as CFDictionary)

        appDelegateLogger.log("debug local state reset completed")
    }
}
#endif
