import AppKit
import os

private let consentLogger = Logger(subsystem: "com.soyeht.mac", category: "pairing")

/// Presents an `NSAlert` asking the user whether to pair an iPhone with this Mac.
///
/// Runs on the main actor; call-sites inside the handoff listener hop via
/// `Task { @MainActor in }` to reach this. `runModal()` blocks the main run
/// loop but the WebSocket traffic lives on a private `DispatchQueue`, so it
/// is unaffected during the prompt.
@MainActor
enum PairingConsentPrompter {
    enum Decision {
        case pair
        case deny
    }

    static func askToPair(deviceName: String, deviceModel: String) async -> Decision {
        consentLogger.log("pair_consent_shown device_name=\(deviceName, privacy: .public) model=\(deviceModel, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = String(localized: "pairing.consent.title", comment: "Alert title asking the user to approve pairing a new iPhone.")
        alert.informativeText = String(
            localized: "pairing.consent.message",
            defaultValue: "“\(deviceName)” (\(deviceModel)) asked to pair with this Mac.\n\nOnce paired, it can open any terminal tab via QR without asking again — until you revoke it in Paired Devices.",
            comment: "Alert body. %1$@ = device display name, %2$@ = device model identifier (e.g. 'iPhone 16,1')."
        )
        alert.alertStyle = .warning
        let pairButton = alert.addButton(withTitle: String(localized: "pairing.consent.button.pair", comment: "Confirm button — approves the pairing request."))
        alert.addButton(withTitle: String(localized: "pairing.consent.button.deny", comment: "Reject button — declines the pairing request."))
        pairButton.keyEquivalent = "\r"

        // Bring app forward so the user actually sees the modal.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        let decision: Decision = (response == .alertFirstButtonReturn) ? .pair : .deny
        consentLogger.log("pair_consent_decision decision=\(String(describing: decision), privacy: .public) device_name=\(deviceName, privacy: .public)")
        return decision
    }
}
