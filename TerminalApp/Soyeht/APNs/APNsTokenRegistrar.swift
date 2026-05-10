import Foundation
import UserNotifications
import UIKit
import SoyehtCore

/// Captures the device APNs token from UNUserNotificationCenter and persists it (T066).
///
/// The token is:
/// 1. Persisted in UserDefaults for retrieval across sessions.
/// 2. Carried into the `_soyeht-setup._tcp.` Bonjour TXT via SetupInvitationPublisher.
/// 3. Included in `ClaimSetupInvitationRequest.iphone_apns_token` (Caso B).
@MainActor
public final class APNsTokenRegistrar: NSObject {
    private static let storageKey = "com.soyeht.apns_token"

    public static let shared = APNsTokenRegistrar()

    private var continuation: CheckedContinuation<Data, Error>?
    private let continuationQueue = DispatchQueue(label: "com.soyeht.apns-registrar")

    private override init() { super.init() }

    // MARK: - Public API

    /// Requests authorization and returns the APNs token.
    /// Subsequent calls re-use the persisted token if available.
    @discardableResult
    public func requestAndCapture() async throws -> Data {
        if let cached = persistedToken() {
            return cached
        }
        try await requestAuthorization()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Handles the token data from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didRegister(deviceToken: Data) {
        persist(token: deviceToken)
        let c = continuation
        continuation = nil
        c?.resume(returning: deviceToken)
    }

    /// Handles registration failure from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public func didFailToRegister(error: Error) {
        let c = continuation
        continuation = nil
        c?.resume(throwing: error)
    }

    /// Returns the persisted APNs token if available.
    public func persistedToken() -> Data? {
        UserDefaults.standard.data(forKey: Self.storageKey)
    }

    // MARK: - Private

    private func requestAuthorization() async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else {
            throw APNsRegistrationError.authorizationDenied
        }
    }

    private func persist(token: Data) {
        UserDefaults.standard.set(token, forKey: Self.storageKey)
    }
}

// MARK: - Error

public enum APNsRegistrationError: Error, Sendable {
    case authorizationDenied
    case registrationFailed(Error)
}
