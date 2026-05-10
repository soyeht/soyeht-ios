import AppKit
import Foundation

/// Opens a URL in the user's default browser (T073).
/// Used when iPhone QR is scanned by Mac webcam (fallback Caso B path).
enum SafariOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens the Soyeht Mac download page with an optional pre-auth token.
    static func openDownloadPage(token: String? = nil) {
        var components = URLComponents(string: "https://soyeht.com/mac")!
        if let token {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else { return }
        open(url)
    }
}
