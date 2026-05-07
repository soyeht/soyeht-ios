//
//  AppDelegate.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SoyehtCore
import os

private let appDelegateLogger = Logger(subsystem: "com.soyeht.mobile", category: "app-delegate")

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Typography.bootstrap()
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
        Task {
            do {
                _ = try await APNSRegistrationCoordinator.shared.receiveDeviceToken(deviceToken)
            } catch {
                appDelegateLogger.error("APNS device-token registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        appDelegateLogger.error("APNS device-token request failed: \(String(describing: error), privacy: .public)")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = storyboard.instantiateInitialViewController()
        window.backgroundColor = SoyehtTheme.uiBgPrimary
        window.overrideUserInterfaceStyle = SoyehtTheme.userInterfaceStyle
        self.window = window
        window.makeKeyAndVisible()

        // Cold launch via deep link
        if let url = connectionOptions.urlContexts.first?.url {
            SessionStore.shared.pendingDeepLink = url
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        // Foreground delivery can race the SwiftUI subscriber setup, so keep both
        // paths and let the view layer dedupe the same URL if it receives it twice.
        SessionStore.shared.pendingDeepLink = url
        NotificationCenter.default.post(name: .soyehtDeepLink, object: url)
    }
}
