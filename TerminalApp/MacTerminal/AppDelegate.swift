//
//  AppDelegate.swift
//  MacTerminal
//

import Cocoa
import SoyehtCore

@NSApplicationMain
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references to all open window controllers.
    // NSWindow.windowController is weak, so without this the WC is immediately deallocated.
    private var windowControllers: [NSWindowController] = []

    /// Single source of truth for Workspaces. Lives for the process lifetime.
    let workspaceStore = WorkspaceStore()
    let conversationStore = ConversationStore()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppEnvironment.workspaceStore = workspaceStore
        AppEnvironment.conversationStore = conversationStore
        Typography.bootstrap()
        #if DEBUG
        assert(Typography.isRegistered(), "[Typography] JetBrains Mono failed to register. Check SoyehtCore Resources/Fonts bundling.")
        installDebugMenu()
        #endif
        openNewMainWindow()
        // Show login sheet if no server is paired yet
        if SessionStore.shared.pairedServers.isEmpty {
            Task { @MainActor in
                // Yield one run-loop cycle so makeKeyAndOrderFront has time to process
                // before we try to attach a sheet (NSApp.keyWindow needs to be set first).
                await Task.yield()
                self.showLoginSheet()
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        WorkspaceBookmarkStore.shared.releaseAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Terminal apps stay running after last window closes
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false  // Don't present Open dialog on launch
    }

    // MARK: - URL Scheme (theyos://)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let result = QRScanResult.from(url: url) else { return }
        switch result {
        case .pair(let token, let host), .connect(let token, let host), .invite(let token, let host):
            autoConnect(token: token, host: host)
        }
    }

    /// Directly calls pairServer without showing a sheet — used when a theyos:// link
    /// is opened, since the user deliberately triggered it.
    private func autoConnect(token: String, host: String) {
        Task { @MainActor in
            do {
                _ = try await SoyehtAPIClient.shared.pairServer(token: token, host: host)
                // Dismiss any open login windows/sheets
                for window in NSApp.windows {
                    if window.contentViewController is LoginViewController {
                        window.close()
                    }
                    window.sheets.forEach { sheet in
                        if sheet.contentViewController is LoginViewController {
                            window.endSheet(sheet)
                        }
                    }
                }
            } catch {
                // Fall back to pre-filled sheet so the user can retry
                showLoginSheet(prefillHost: host, prefillToken: token)
            }
        }
    }

    // MARK: - Startup

    @MainActor
    private func startupFlow() async {
        let store = SessionStore.shared
        if store.pairedServers.isEmpty {
            openNewMainWindow()
            await Task.yield()
            showLoginSheet()
        } else {
            openNewMainWindow()
        }
    }

    // MARK: - Window Management

    @discardableResult
    func openNewMainWindow(
        initialWindowID: String? = nil,
        initialWorkspaceID: Workspace.ID? = nil
    ) -> SoyehtMainWindowController {
        let wc = SoyehtMainWindowController(
            store: workspaceStore,
            windowID: initialWindowID ?? UUID().uuidString,
            restoredWorkspaceID: initialWorkspaceID
        )
        retain(wc)
        wc.showWindow(nil)
        return wc
    }

    /// Opens (or reuses) the Conversations sidebar window. Used by the menu
    /// item and by `SoyehtWindowRestoration`.
    @discardableResult
    func openConversationsSidebar() -> ConversationsSidebarWindowController {
        if let wc = sidebarWC { return wc }
        let wc = ConversationsSidebarWindowController(
            workspaceStore: workspaceStore,
            conversationStore: conversationStore
        )
        retain(wc)
        sidebarWC = wc
        if let window = wc.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sidebarWC = nil }
            }
        }
        return wc
    }

    private func retain(_ wc: NSWindowController) {
        windowControllers.append(wc)
        if let window = wc.window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self, weak wc] _ in
                self?.windowControllers.removeAll(where: { $0 === wc })
            }
        }
    }

    // MARK: - Debug Menu (Phase 2)

    #if DEBUG
    private func installDebugMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Avoid duplicates if called twice during launch.
        if mainMenu.items.contains(where: { $0.title == "Debug" }) { return }

        let debugMenu = NSMenu(title: "Debug")
        let openPaneItem = NSMenuItem(title: "Open Pane Window", action: #selector(openPaneDebugWindow(_:)), keyEquivalent: "")
        openPaneItem.target = self
        debugMenu.addItem(openPaneItem)

        let sidebarItem = NSMenuItem(
            title: "Open Conversations Sidebar",
            action: #selector(showConversationsSidebar(_:)),
            keyEquivalent: "C"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .shift]
        sidebarItem.target = self
        debugMenu.addItem(sidebarItem)

        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        // Insert before the Help menu (last item).
        let insertIndex = max(0, mainMenu.items.count - 1)
        mainMenu.insertItem(debugItem, at: insertIndex)
    }

    @MainActor @objc private func openPaneDebugWindow(_ sender: Any?) {
        let seedLeaf = UUID()
        let grid = PaneGridController(tree: .leaf(seedLeaf))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pane Grid Debug"
        window.contentViewController = grid
        window.center()

        let wc = NSWindowController(window: window)
        retain(wc)
        wc.showWindow(nil)
    }
    #endif

    @IBAction func showPreferences(_ sender: Any) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @IBAction func newWindow(_ sender: Any) {
        openNewMainWindow()
    }

    private var sidebarWC: ConversationsSidebarWindowController?

    /// Exposed for the main window's toolbar "toggle sidebar" button, so it can
    /// check visibility and flip it. Returns nil when the sidebar has never
    /// been opened this session (or was closed and released).
    var sidebarController: ConversationsSidebarWindowController? { sidebarWC }

    @IBAction func showConversationsSidebar(_ sender: Any?) {
        if sidebarWC == nil {
            let wc = ConversationsSidebarWindowController(
                workspaceStore: workspaceStore,
                conversationStore: conversationStore
            )
            retain(wc)
            sidebarWC = wc
            if let window = wc.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window, queue: .main
                ) { [weak self] _ in self?.sidebarWC = nil }
            }
        }
        sidebarWC?.showWindow(sender)
    }

    @IBAction func logout(_ sender: Any) {
        let store = SessionStore.shared
        guard !store.pairedServers.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Logout from Soyeht Server?"
        alert.informativeText = "This will remove your session. You'll need to enter your host and token again to reconnect."
        alert.addButton(withTitle: "Logout")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let id = store.activeServerId {
            store.removeServer(id: id)
        } else {
            store.clearSession()
        }
        showLoginSheet()
    }

    // MARK: - Auth Sheet

    func showLoginSheet(prefillHost: String? = nil, prefillToken: String? = nil) {
        let loginVC = LoginViewController()
        loginVC.onSuccess = {
            // After successful login, the window is already open
        }

        if let host = prefillHost, let token = prefillToken {
            loginVC.prefill(host: host, token: token)
        }

        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.contentViewController?.presentAsSheet(loginVC)
        } else {
            // No window yet — present as standalone panel
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Connect to Soyeht Server"
            panel.contentViewController = loginVC
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
