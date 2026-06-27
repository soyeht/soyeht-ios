import SoyehtCore

#if canImport(AuthenticationServices)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Presentation-anchor provider for the owner-passkey ceremony: returns the app's
/// key window. This is the first app-target use of
/// `PasskeyPresentationAnchorProviding` (the SoyehtCore `PasskeyProvider` anchors
/// the system sheet to whatever this returns).
final class KeyWindowPasskeyAnchorProvider: PasskeyPresentationAnchorProviding {
    func passkeyPresentationAnchor() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first ?? UIWindow()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #endif
    }
}
#endif
