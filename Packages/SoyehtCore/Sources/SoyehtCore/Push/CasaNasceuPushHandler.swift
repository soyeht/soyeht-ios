import Foundation

/// Handles the incoming `casa_nasceu` APNs push payload (T067, FR-contracts push-events.md).
///
/// Parses the `soyeht` JSON section; on foreground tap, routes to PairingConfirmation flow
/// (shared with US1 T053-T055). Unknown `type` values are ignored for forward-extensibility.
public final class CasaNasceuPushHandler: Sendable {
    public struct Payload: Sendable {
        public let hhId: String
        public let hhName: String
        public let machineId: String
        public let machineLabel: String
        public let pairQrUri: String
        public let timestamp: UInt64

        public init(hhId: String, hhName: String, machineId: String, machineLabel: String, pairQrUri: String, timestamp: UInt64) {
            self.hhId = hhId
            self.hhName = hhName
            self.machineId = machineId
            self.machineLabel = machineLabel
            self.pairQrUri = pairQrUri
            self.timestamp = timestamp
        }
    }

    public enum ParseResult: Sendable {
        case casaNasceu(Payload)
        case unknownType(String)
        case notSoyehtPayload
        case malformed
    }

    // MARK: - Parsing

    /// Parses an APNs notification userInfo dictionary.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> ParseResult {
        guard let soyeht = userInfo["soyeht"] as? [String: Any] else {
            return .notSoyehtPayload
        }

        guard let type = soyeht["type"] as? String else {
            return .malformed
        }

        guard type == "casa_nasceu" else {
            return .unknownType(type)
        }

        guard
            let hhId = soyeht["hh_id"] as? String,
            let hhName = soyeht["hh_name"] as? String,
            let machineId = soyeht["machine_id"] as? String,
            let machineLabel = soyeht["machine_label"] as? String,
            let pairQrUri = soyeht["pair_qr_uri"] as? String,
            let ts = soyeht["ts"] as? UInt64
                ?? (soyeht["ts"] as? Int).flatMap(UInt64.init(exactly:))
        else {
            return .malformed
        }

        return .casaNasceu(Payload(
            hhId: hhId,
            hhName: hhName,
            machineId: machineId,
            machineLabel: machineLabel,
            pairQrUri: pairQrUri,
            timestamp: ts
        ))
    }

    // MARK: - Notification name

    /// Posted on main queue when a `casa_nasceu` push is received while app is in foreground.
    /// UserInfo key `.payload` contains the parsed `Payload`.
    public static let casaNasceuReceived = Notification.Name("com.soyeht.casaNasceuReceived")

    public static let payloadKey = "payload"

    /// Handles a received push notification (call from AppDelegate or UNUserNotificationCenterDelegate).
    /// Posts `casaNasceuReceived` if type matches; ignores all other types.
    public static func handle(_ userInfo: [AnyHashable: Any]) {
        switch parse(userInfo) {
        case .casaNasceu(let payload):
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: casaNasceuReceived,
                    object: nil,
                    userInfo: [payloadKey: payload]
                )
            }
        case .unknownType, .notSoyehtPayload, .malformed:
            break
        }
    }
}
