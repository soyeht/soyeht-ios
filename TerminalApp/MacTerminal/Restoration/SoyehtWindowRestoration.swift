import AppKit

/// NSWindowRestoration class. AppKit invokes this after launch for each saved
/// window identifier, asking us to rebuild the window controller before the
/// window's saved frame/state is reapplied.
///
/// Scope (Phase 14 MVP): restore the main window with its last-active workspace
/// (per-window via `restoredWindowID`) and the Conversations sidebar.
/// Pane tree already survives via `WorkspaceStore`'s JSON — the layout of the
/// active workspace is looked up from the store, not re-encoded per window.
@objc(SoyehtWindowRestoration)
@MainActor
final class SoyehtWindowRestoration: NSObject, NSWindowRestoration {

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping @Sendable (NSWindow?, Error?) -> Void
    ) {
        let id = identifier.rawValue
        // Hop to main actor because window controllers are @MainActor.
        Task { @MainActor in
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                completionHandler(nil, nil); return
            }
            if id == kSidebarWindowIdentifier {
                let wc = appDelegate.openConversationsSidebar()
                completionHandler(wc.window, nil)
                return
            }
            // Main windows: try to decode the active workspace id and the
            // window's stable id from the coder.
            let restoredWindowID = state.decodeObject(of: NSString.self, forKey: "windowID") as String?
            let restoredActiveWS = state.decodeObject(of: NSString.self, forKey: "activeWorkspaceID") as String?
            let wsUUID = restoredActiveWS.flatMap(UUID.init(uuidString:))
            let wc = appDelegate.openNewMainWindow(
                initialWindowID: restoredWindowID,
                initialWorkspaceID: wsUUID
            )
            completionHandler(wc.window, nil)
        }
    }
}

let kMainWindowIdentifierPrefix = "com.soyeht.mac.mainwindow."
let kSidebarWindowIdentifier = "com.soyeht.mac.sidebar"
