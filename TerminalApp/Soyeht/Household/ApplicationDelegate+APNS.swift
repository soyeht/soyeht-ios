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
            NotificationCenter.default.post(name: .soyehtHouseholdAPNSTickle, object: nil)
            completionHandler(.newData)
        } catch {
            NotificationCenter.default.post(
                name: .soyehtHouseholdAPNSIntegrityError,
                object: error
            )
            completionHandler(.failed)
        }
    }
}
