import AppKit
import Foundation

/// Opens a URL in the user's default browser (T073).
/// Used when iPhone QR is scanned by Mac webcam (fallback case B path).
enum SafariOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens the current Soyeht Mac DMG download.
    static func openDownloadPage(token: String? = nil) {
        var components = URLComponents(string: "https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg")!
        _ = token
        guard let url = components.url else { return }
        open(url)
    }
}
