import Foundation
import UIKit
import SoyehtCore

enum APNSOpaqueTickleError: Error, Equatable {
    case payloadBytesNotCanonical
    case invalidAPSShape
    case forbiddenPayloadKey(String)
}

struct APNSOpaqueTickle {
    static let canonicalPayloadBytes = Data(#"{"aps":{"content-available":1}}"#.utf8)

    static func validatePayloadBytes(_ data: Data) throws {
        guard data == canonicalPayloadBytes else {
            throw APNSOpaqueTickleError.payloadBytesNotCanonical
        }
    }

    static func validateUserInfo(_ userInfo: [AnyHashable: Any]) throws {
        for key in userInfo.keys where key.description != "aps" {
            throw APNSOpaqueTickleError.forbiddenPayloadKey(key.description)
        }
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else {
            throw APNSOpaqueTickleError.invalidAPSShape
        }
        for key in aps.keys where key.description != "content-available" {
            throw APNSOpaqueTickleError.forbiddenPayloadKey("aps.\(key.description)")
        }
        guard aps.count == 1, isContentAvailableOne(aps["content-available"]) else {
            throw APNSOpaqueTickleError.invalidAPSShape
        }
    }

    private static func isContentAvailableOne(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue == 1
        }
        if let int = value as? Int {
            return int == 1
        }
        return false
    }
}

enum APNSTickleDelivery {
    private static let lock = NSLock()
    private static var pendingTickleCount = 0

    static func deliverTickle(notificationCenter: NotificationCenter = .default) {
        lock.lock()
        pendingTickleCount += 1
        lock.unlock()

        notificationCenter.post(name: .soyehtHouseholdAPNSTickle, object: nil)
    }

    static func consumePendingTickle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingTickleCount > 0 else { return false }
        pendingTickleCount -= 1
        return true
    }

    #if DEBUG
    static func resetForTests() {
        lock.lock()
        pendingTickleCount = 0
        lock.unlock()
    }
    #endif
}

#if DEBUG
enum APNSWakeProbe {
    private static let devBundleIdentifier = "com.soyeht.app.dev"
    private static let directoryName = "SoyehtDevDiagnostics"
    private static let fileName = "apns-wake-probe.json"

    static func record(_ event: String) {
        guard Bundle.main.bundleIdentifier == devBundleIdentifier else { return }
        guard let diagnosticsRootURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let directoryURL = diagnosticsRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            var counts: [String: Int] = [:]
            if let data = try? Data(contentsOf: fileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let existingCounts = json["counts"] as? [String: Any] {
                counts = existingCounts.reduce(into: [String: Int]()) { partial, item in
                    if let value = item.value as? NSNumber {
                        partial[item.key] = value.intValue
                    }
                }
            }

            counts[event, default: 0] += 1
            let payload: [String: Any] = [
                "v": 1,
                "last_event": event,
                "last_updated_unix": Date().timeIntervalSince1970,
                "counts": counts,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Best-effort Dev-only diagnostic; APNs delivery must never depend on this probe.
        }
    }
}
#endif

extension Notification.Name {
    static let soyehtHouseholdAPNSTickle = Notification.Name("soyeht.household.apns.tickle")
    static let soyehtHouseholdAPNSIntegrityError = Notification.Name("soyeht.household.apns.integrityError")
}

extension AppDelegate {
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if case .houseCreated = HouseCreatedPushHandler.parse(userInfo) {
            HouseCreatedPushHandler.handle(userInfo)
            completionHandler(.newData)
            return
        }

        do {
            try APNSOpaqueTickle.validateUserInfo(userInfo)
            #if DEBUG
            APNSWakeProbe.record("tickle_received")
            #endif
            APNSTickleDelivery.deliverTickle()
            completionHandler(.newData)
        } catch {
            #if DEBUG
            APNSWakeProbe.record("tickle_rejected")
            #endif
            NotificationCenter.default.post(
                name: .soyehtHouseholdAPNSIntegrityError,
                object: error
            )
            completionHandler(.failed)
        }
    }
}
