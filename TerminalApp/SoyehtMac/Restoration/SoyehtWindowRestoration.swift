@preconcurrency import AppKit

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
        // Hop to main actor because window controllers are @MainActor.
        Task { @MainActor in
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                completionHandler(nil, nil); return
            }
            // Sidebar was previously a separate NSWindow (kSidebarWindowIdentifier);
            // it's now a floating overlay inside the main window, so there's
            // nothing to restore for it — dropped the branch. Any legacy
            // restoration record falls through to the main-window path below
            // (which is safe: it creates a fresh main window with seeded state).
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
