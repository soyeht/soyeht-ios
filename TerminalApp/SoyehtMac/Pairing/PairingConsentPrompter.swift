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
        alert.messageText = "Parear este iPhone com o Mac?"
        alert.informativeText = """
        “\(deviceName)” (\(deviceModel)) pediu para parear com este Mac.

        Depois de pareado, ele pode abrir qualquer aba do terminal via QR sem pedir \
        confirmação de novo — até você revogá-lo em Dispositivos Pareados.
        """
        alert.alertStyle = .warning
        let pairButton = alert.addButton(withTitle: "Parear")
        alert.addButton(withTitle: "Recusar")
        pairButton.keyEquivalent = "\r"

        // Bring app forward so the user actually sees the modal.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        let decision: Decision = (response == .alertFirstButtonReturn) ? .pair : .deny
        consentLogger.log("pair_consent_decision decision=\(String(describing: decision), privacy: .public) device_name=\(deviceName, privacy: .public)")
        return decision
    }
}
