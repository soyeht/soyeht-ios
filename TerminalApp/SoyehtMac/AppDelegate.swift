//
//  AppDelegate.swift
//  Soyeht
//

import Cocoa
import SoyehtCore

@NSApplicationMain
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    // Strong references to all open window controllers.
    // NSWindow.windowController is weak, so without this the WC is immediately deallocated.
    private var windowControllers: [NSWindowController] = []

    /// Single source of truth for Workspaces. Lives for the process lifetime.
    let workspaceStore = WorkspaceStore()
    let conversationStore = ConversationStore()

    /// Lazy command palette (Fase 3.2). Built on first ⌘P invocation so
    /// launch time isn't affected by NSPanel instantiation + view build.
    private var commandPalette: CommandPaletteWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        normalizeInheritedWorkingDirectory()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppEnvironment.workspaceStore = workspaceStore
        AppEnvironment.conversationStore = conversationStore
        // Wire the dual-store persistence bridge:
        //  1. ConversationStore signals WorkspaceStore to schedule a save on
        //     every user mutation (rename, commander swap, etc.) so the
        //     combined v2 snapshot stays fresh.
        //  2. WorkspaceStore serializes/deserializes conversations through
        //     the bridge, producing a single atomic file write per save.
        // Wire dirty signal BEFORE bootstrap so the load's own notification
        // doesn't trigger a save. `bootstrap` re-delivers any conversations
        // that were already parsed from disk during `WorkspaceStore.init`.
        conversationStore.onDirty = { [weak workspaceStore] in
            workspaceStore?.scheduleSave()
        }
        workspaceStore.bootstrap(bridge: WorkspaceStore.ConversationBridge(
            snapshot: { [weak conversationStore] in conversationStore?.all ?? [] },
            bootstrap: { [weak conversationStore] in conversationStore?.bootstrap($0) },
            reinsert: { [weak conversationStore] in conversationStore?.reinsert($0) },
            remove: { [weak conversationStore] ids in
                ids.forEach { conversationStore?.remove($0) }
            }
        ))
        Typography.bootstrap()
        #if DEBUG
        assert(Typography.isRegistered(), "[Typography] JetBrains Mono failed to register. Check SoyehtCore Resources/Fonts bundling.")
        installDebugMenu()
        #endif
        installPairingMenu()
        installClawStoreMenu()
        installCommandPaletteMenu()
        installPaneMenuEnhancements()
        installEditMenuEnhancements()
        installWorkspaceMenuEnhancements()
        // Boot the app-level WebSocket server so paired iPhones can reach us
        // as soon as the app launches, without a QR scan. Presence + pane
        // attach listeners; ports are cached in UserDefaults.
        PairingPresenceServer.shared.start()
        // Touch PaneStatusTracker early so it starts listening to
        // ConversationStore changes before any pane is created.
        _ = PaneStatusTracker.shared
        // When the app has no paired server yet, open the dedicated Welcome
        // window instead of the main workspace. The main window only appears
        // after pairing completes — avoids the old "empty workspace behind a
        // sheet" UX. When the user already has a session, skip straight to
        // the main window. See Fase 2 / US-01..US-04 in the roadmap.
        if SessionStore.shared.pairedServers.isEmpty {
            openWelcomeWindow()
        } else {
            openNewMainWindow()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Flush debounced persistence BEFORE AppKit tears everything down,
        // otherwise the last ~300ms of mutations (renames, focus changes,
        // new conversations) are lost on normal quit.
        workspaceStore.flushPendingSave()
        WorkspaceBookmarkStore.shared.releaseAll()
        PairingPresenceServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Terminal apps stay running after last window closes
    }

    /// Disable AppKit's app-level state restoration. Without this, quitting
    /// or killing the app causes the next launch to reopen N copies of the
    /// main window — each running `applicationDidFinishLaunching`'s
    /// `openNewMainWindow()` path and re-creating PaneViewControllers.
    /// `LivePaneRegistry` then gets double-registered with the same
    /// conversation id and the first pane is orphaned when the duplicate
    /// closes. We persist workspace state via `WorkspaceStore.json`
    /// already; AppKit-level restoration is redundant.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false  // Don't present Open dialog on launch
    }

    // MARK: - URL Scheme (theyos://)

    /// Strong reference to the Welcome window while it's visible. AppKit
    /// keeps the window's own controller weak, and NSHostingController owns
    /// the SwiftUI view, so without this the whole window deallocates the
    /// moment the SwiftUI callback fires.
    private var welcomeWindowController: WelcomeWindowController?

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
                dismissWelcomeAndLoginIfNeeded()
                if NSApp.windows.compactMap({ $0.windowController as? SoyehtMainWindowController }).isEmpty {
                    openNewMainWindow()
                }
            } catch {
                // Fall back to pre-filled sheet so the user can retry
                showLoginSheet(prefillHost: host, prefillToken: token)
            }
        }
    }

    /// Opens (or re-focuses) the onboarding window. Called on first launch
    /// and again after the user logs out of the last server.
    private func openWelcomeWindow() {
        if let existing = welcomeWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = WelcomeWindowController()
        wc.onComplete = { [weak self] in
            self?.finishWelcome()
        }
        welcomeWindowController = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    /// Invoked by the Welcome window after a successful pair. Closes the
    /// welcome window and opens the main workspace so the user lands on a
    /// live terminal environment.
    private func finishWelcome() {
        welcomeWindowController?.close()
        welcomeWindowController = nil
        openNewMainWindow()
    }

    /// Closes any stale Welcome/Login surfaces left over from a previous
    /// flow. Used when the user resolves pairing through an orthogonal
    /// channel (deep link, second app instance, etc.).
    private func dismissWelcomeAndLoginIfNeeded() {
        welcomeWindowController?.close()
        welcomeWindowController = nil
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

    private func retain(_ wc: NSWindowController) {
        windowControllers.append(wc)
        if let window = wc.window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self, weak wc] _ in
                self?.windowControllers.removeAll(where: { $0 === wc })
            }
        }
    }

    /// Debug builds are commonly launched from a shell inside the repo under
    /// `~/Documents`, which makes the app inherit a TCC-protected cwd and
    /// triggers the recurring "access files in your Documents folder" prompt
    /// before the user intentionally picks any workspace folder. Move the
    /// process to Application Support up front so only explicit folder choices
    /// or stored workspace bookmarks touch protected locations.
    private func normalizeInheritedWorkingDirectory() {
        let safeDirectory = WorkspaceStore.defaultStorageURL().deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: safeDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[AppDelegate] failed to create safe cwd \(safeDirectory.path): \(error)")
            return
        }
        guard FileManager.default.changeCurrentDirectoryPath(safeDirectory.path) else {
            NSLog("[AppDelegate] failed to switch cwd to \(safeDirectory.path)")
            return
        }
        setenv("PWD", safeDirectory.path, 1)
        unsetenv("OLDPWD")
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

    @IBAction func showPairedDevices(_ sender: Any) {
        PairedDevicesWindowController.shared.showWindow(nil)
    }

    @IBAction func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
        target?.moveFocusedPaneToWorkspaceByTag(sender)
    }

    @IBAction func toggleWorkspaceSelectionByTag(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
        target?.toggleWorkspaceSelectionByTag(sender)
    }

    @IBAction func selectWorkspaceByTag(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
        target?.selectWorkspaceByTag(sender)
    }

    @IBAction func moveActiveWorkspaceLeft(_ sender: Any?) {
        activeMainWindowController?.moveActiveWorkspaceLeft(sender)
    }

    @IBAction func moveActiveWorkspaceRight(_ sender: Any?) {
        activeMainWindowController?.moveActiveWorkspaceRight(sender)
    }

    @IBAction func splitPaneVertical(_ sender: Any?) { withActivePaneGrid { $0.splitPaneVertical(sender) } }
    @IBAction func splitPaneHorizontal(_ sender: Any?) { withActivePaneGrid { $0.splitPaneHorizontal(sender) } }
    @IBAction func closeFocusedPane(_ sender: Any?) { withActivePaneGrid { $0.closeFocusedPane(sender) } }
    @IBAction func undoWindowAction(_ sender: Any?) {
        activeUndoManager?.undo()
    }
    @IBAction func redoWindowAction(_ sender: Any?) {
        activeUndoManager?.redo()
    }
    @IBAction func focusPaneLeft(_ sender: Any?) { withActivePaneGrid { $0.focusPaneLeft(sender) } }
    @IBAction func focusPaneRight(_ sender: Any?) { withActivePaneGrid { $0.focusPaneRight(sender) } }
    @IBAction func focusPaneUp(_ sender: Any?) { withActivePaneGrid { $0.focusPaneUp(sender) } }
    @IBAction func focusPaneDown(_ sender: Any?) { withActivePaneGrid { $0.focusPaneDown(sender) } }
    @IBAction func toggleZoomFocusedPane(_ sender: Any?) { withActivePaneGrid { $0.toggleZoomFocusedPane(sender) } }
    @IBAction func exitZoom(_ sender: Any?) { withActivePaneGrid { $0.exitZoom(sender) } }
    @IBAction func swapPaneLeft(_ sender: Any?) { withActivePaneGrid { $0.swapPaneLeft(sender) } }
    @IBAction func swapPaneRight(_ sender: Any?) { withActivePaneGrid { $0.swapPaneRight(sender) } }
    @IBAction func swapPaneUp(_ sender: Any?) { withActivePaneGrid { $0.swapPaneUp(sender) } }
    @IBAction func swapPaneDown(_ sender: Any?) { withActivePaneGrid { $0.swapPaneDown(sender) } }
    @IBAction func rotateFocusedSplit(_ sender: Any?) { withActivePaneGrid { $0.rotateFocusedSplit(sender) } }
    @IBAction func closeSelectedWorkspaces(_ sender: Any?) {
        guard let controller = activeMainWindowController else {
            NSSound.beep()
            return
        }
        controller.closeSelectedWorkspacesFromMenu(sender)
    }
    @IBAction func newGroupForActiveWorkspace(_ sender: Any?) {
        guard let controller = activeMainWindowController else {
            NSSound.beep()
            return
        }
        controller.promptCreateGroupForActiveWorkspace(sender)
    }
    @IBAction func assignActiveWorkspaceToGroup(_ sender: NSMenuItem) {
        guard let controller = activeMainWindowController else {
            NSSound.beep()
            return
        }
        controller.assignActiveWorkspaceToGroup(sender.representedObject as? Group.ID)
    }

    /// Adds a "Dispositivos pareados…" item under the app menu, right after
    /// Preferences (Cmd-,). Cmd-Shift-D opens the window.
    private func installPairingMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenu.items.contains(where: { $0.action == #selector(showPairedDevices(_:)) }) { return }

        let item = NSMenuItem(
            title: "Dispositivos pareados…",
            action: #selector(showPairedDevices(_:)),
            keyEquivalent: "D"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self

        // Insert right after "Preferences…" if present, else near the top.
        let insertAfter = appMenu.items.firstIndex(where: {
            $0.title.lowercased().contains("preferences") || $0.title.lowercased().contains("settings")
        })
        let index = insertAfter.map { $0 + 1 } ?? min(2, appMenu.items.count)
        appMenu.insertItem(item, at: index)
    }

    @IBAction func newWindow(_ sender: Any) {
        openNewMainWindow()
    }

    // MARK: - Claw Store (Fase 3)

    /// Strong reference to the Claw Store window so NSHostingController's
    /// SwiftUI view model stays alive for the full session. NSWindow holds
    /// its controller weakly.
    private var clawStoreWindowController: ClawStoreWindowController?

    @IBAction func showClawStore(_ sender: Any?) {
        // Claw Store requires an active paired server — the ViewModels are
        // pinned to a `ServerContext`. Fall back to the login sheet if the
        // user somehow reaches this item without a session.
        guard let context = SessionStore.shared.currentContext() else {
            showLoginSheet()
            return
        }
        if let existing = clawStoreWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ClawStoreWindowController(context: context)
        retain(wc)
        // When the window closes, drop our strong ref so the next
        // invocation builds a fresh controller (and picks up any context
        // change since).
        if let window = wc.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.clawStoreWindowController = nil
            }
        }
        clawStoreWindowController = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    /// Adds "Claw Store…" to the app menu with ⌘⇧S. Mirrors the same
    /// insertion pattern used for Paired Devices so both entries sit near
    /// Preferences.
    private func installClawStoreMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenu.items.contains(where: { $0.action == #selector(showClawStore(_:)) }) { return }
        let item = NSMenuItem(
            title: "Claw Store…",
            action: #selector(showClawStore(_:)),
            keyEquivalent: "S"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        let insertAfter = appMenu.items.firstIndex(where: {
            $0.title.lowercased().contains("preferences") || $0.title.lowercased().contains("settings")
        })
        let index = insertAfter.map { $0 + 1 } ?? min(2, appMenu.items.count)
        appMenu.insertItem(item, at: index)
    }

    // MARK: - Command palette (Fase 3.2)

    @IBAction func showCommandPalette(_ sender: Any?) {
        let palette: CommandPaletteWindowController
        if let existing = commandPalette {
            palette = existing
        } else {
            palette = CommandPaletteWindowController(
                workspaceStore: workspaceStore,
                conversationStore: conversationStore
            )
            palette.onSelect = { [weak self] item in
                self?.jump(to: item)
            }
            commandPalette = palette
        }
        let parent = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)?.window
            ?? NSApp.windows.first(where: { $0.windowController is SoyehtMainWindowController })
        palette.present(from: parent)
    }

    /// Resolve a palette selection: switch to the key main window (or any
    /// main window), activate the workspace, and — if a pane was selected —
    /// focus it. Mirrors the sidebar's `focusPane(workspaceID:conversationID:)`
    /// path so the behaviour is identical whichever entry point the user
    /// uses.
    private func jump(to item: CommandPaletteItem) {
        let target = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
        guard let target else { return }
        if let paneID = item.paneID {
            target.focusPane(workspaceID: item.workspaceID, conversationID: paneID)
        } else {
            target.activate(workspaceID: item.workspaceID)
        }
    }

    /// Add a menu item under the View menu (or the app menu as fallback)
    /// that triggers `showCommandPalette(_:)` with `⌘P`.
    private func installCommandPaletteMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // `Print…` ships from the storyboard with the standard `⌘P`, which
        // collides with the command palette's entry point. The workspace QA
        // contract expects `⌘P` to open the palette, so demote Print to a
        // click-only menu item and free the shortcut before installing ours.
        if let printItem = findMenuItem(in: mainMenu, titled: "Print…") {
            printItem.keyEquivalent = ""
            printItem.keyEquivalentModifierMask = []
        }
        // Try to find a View menu first (standard location for palettes);
        // fall back to appending at the end of the app menu.
        let targetMenu: NSMenu
        if let viewItem = mainMenu.items.first(where: { $0.title == "View" }),
           let submenu = viewItem.submenu {
            targetMenu = submenu
        } else if let appItem = mainMenu.items.first, let submenu = appItem.submenu {
            targetMenu = submenu
        } else {
            return
        }
        if targetMenu.items.contains(where: { $0.action == #selector(showCommandPalette(_:)) }) {
            return
        }
        let item = NSMenuItem(
            title: "Go to Pane…",
            action: #selector(showCommandPalette(_:)),
            keyEquivalent: "p"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        targetMenu.addItem(item)
    }

    /// Normalize conflicting storyboard shortcuts and install the phase-2
    /// pane commands that still lack menu wiring (`zoom`, `swap`, `rotate`).
    /// We do this programmatically so the runtime menu always matches the
    /// product contract, even if the storyboard lags behind.
    private func installPaneMenuEnhancements() {
        guard let mainMenu = NSApp.mainMenu,
              let paneMenu = mainMenu.items.first(where: { $0.title == "Pane" })?.submenu
        else { return }

        if let splitVertical = paneMenu.items.first(where: { $0.title == "Split Vertical" }) {
            splitVertical.target = self
            splitVertical.action = #selector(splitPaneVertical(_:))
        }
        if let splitHorizontal = paneMenu.items.first(where: { $0.title == "Split Horizontal" }) {
            splitHorizontal.target = self
            splitHorizontal.action = #selector(splitPaneHorizontal(_:))
        }
        if let focusLeft = paneMenu.items.first(where: { $0.title == "Focus Left" }) {
            focusLeft.target = self
            focusLeft.action = #selector(focusPaneLeft(_:))
            focusLeft.keyEquivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            focusLeft.keyEquivalentModifierMask = [.command, .shift]
        }
        if let focusRight = paneMenu.items.first(where: { $0.title == "Focus Right" }) {
            focusRight.target = self
            focusRight.action = #selector(focusPaneRight(_:))
            focusRight.keyEquivalent = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            focusRight.keyEquivalentModifierMask = [.command, .shift]
        }
        if let focusUp = paneMenu.items.first(where: { $0.title == "Focus Up" }) {
            focusUp.target = self
            focusUp.action = #selector(focusPaneUp(_:))
            focusUp.keyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            focusUp.keyEquivalentModifierMask = [.command, .shift]
        }
        if let focusDown = paneMenu.items.first(where: { $0.title == "Focus Down" }) {
            focusDown.target = self
            focusDown.action = #selector(focusPaneDown(_:))
            focusDown.keyEquivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            focusDown.keyEquivalentModifierMask = [.command, .shift]
        }
        if let closePane = paneMenu.items.first(where: { $0.title == "Close Pane" }) {
            // `⌘⇧W` belongs to Close Workspace. Sharing it with Close Pane made
            // the responder routing ambiguous and blocked the pane undo flow.
            closePane.target = self
            closePane.action = #selector(closeFocusedPane(_:))
            closePane.keyEquivalent = ""
            closePane.keyEquivalentModifierMask = []
        }

        if let redo = findMenuItem(in: mainMenu, titled: "Redo") {
            // `⌘⇧Z` is the zoom toggle per the workspace/pane lifecycle spec.
            // Keep redo available on the equally standard `⌘Y`.
            redo.keyEquivalent = "y"
            redo.keyEquivalentModifierMask = [.command]
        }

        ensureMenuItem(
            titled: "Zoom Focused Pane",
            in: paneMenu,
            action: #selector(toggleZoomFocusedPane(_:)),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        )
        ensureMenuItem(
            titled: "Exit Zoom",
            in: paneMenu,
            action: #selector(exitZoom(_:)),
            keyEquivalent: "\u{1b}",
            modifiers: []
        )
        ensureMenuItem(
            titled: "Swap Pane Left",
            in: paneMenu,
            action: #selector(swapPaneLeft(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.option, .shift]
        )
        ensureMenuItem(
            titled: "Swap Pane Right",
            in: paneMenu,
            action: #selector(swapPaneRight(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.option, .shift]
        )
        ensureMenuItem(
            titled: "Swap Pane Up",
            in: paneMenu,
            action: #selector(swapPaneUp(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.option, .shift]
        )
        ensureMenuItem(
            titled: "Swap Pane Down",
            in: paneMenu,
            action: #selector(swapPaneDown(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.option, .shift]
        )
        ensureMenuItem(
            titled: "Rotate Focused Split",
            in: paneMenu,
            action: #selector(rotateFocusedSplit(_:)),
            keyEquivalent: "r",
            modifiers: [.option, .shift]
        )
        installMoveFocusedPaneMenu(in: paneMenu)
    }

    /// Route Edit > Undo/Redo directly to the active main window's
    /// workspace-level UndoManager. Relying on the responder chain left the
    /// menu item titles updating correctly while the items stayed disabled
    /// whenever focus was inside a terminal or custom pane view.
    private func installEditMenuEnhancements() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let undo = findMenuItem(in: mainMenu, titled: "Undo") {
            undo.target = self
            undo.action = #selector(undoWindowAction(_:))
            undo.keyEquivalent = "z"
            undo.keyEquivalentModifierMask = [.command]
        }
        if let redo = findMenuItem(in: mainMenu, titled: "Redo") {
            redo.target = self
            redo.action = #selector(redoWindowAction(_:))
            redo.keyEquivalent = "y"
            redo.keyEquivalentModifierMask = [.command]
        }
    }

    private func installMoveFocusedPaneMenu(in paneMenu: NSMenu) {
        let title = "Move Focused Pane To"
        let header: NSMenuItem
        if let existing = paneMenu.items.first(where: { $0.title == title }) {
            header = existing
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.submenu = NSMenu(title: title)
            paneMenu.addItem(.separator())
            paneMenu.addItem(header)
        }
        guard let submenu = header.submenu else { return }
        for tag in 1...9 {
            let itemTitle = "Workspace \(tag)"
            let item: NSMenuItem
            if let existing = submenu.items.first(where: { $0.tag == tag || $0.title == itemTitle }) {
                item = existing
            } else {
                item = NSMenuItem(title: itemTitle, action: #selector(moveFocusedPaneToWorkspaceByTag(_:)), keyEquivalent: "\(tag)")
                submenu.addItem(item)
            }
            item.title = itemTitle
            item.tag = tag
            item.action = #selector(moveFocusedPaneToWorkspaceByTag(_:))
            item.keyEquivalent = "\(tag)"
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
        }
    }

    private func installWorkspaceMenuEnhancements() {
        guard let workspaceMenu = NSApp.mainMenu?
            .items
            .first(where: { $0.title == "Workspaces" })?
            .submenu
        else { return }

        workspaceMenu.delegate = self
        for tag in 1...9 {
            let itemTitle = "Workspace \(tag)"
            guard let item = workspaceMenu.items.first(where: { $0.title == itemTitle }) else { continue }
            item.tag = tag
            item.target = self
            item.action = #selector(selectWorkspaceByTag(_:))
            item.keyEquivalent = "\(tag)"
            item.keyEquivalentModifierMask = [.command]
        }
        if workspaceMenu.items.last?.isSeparatorItem != true {
            workspaceMenu.addItem(.separator())
        }
        ensureMenuItem(
            titled: "Close Selected Workspaces",
            in: workspaceMenu,
            action: #selector(closeSelectedWorkspaces(_:)),
            keyEquivalent: "",
            modifiers: []
        )
        ensureMenuItem(
            titled: "Move Active Workspace Left",
            in: workspaceMenu,
            action: #selector(moveActiveWorkspaceLeft(_:)),
            keyEquivalent: "[",
            modifiers: [.control, .command]
        )
        ensureMenuItem(
            titled: "Move Active Workspace Right",
            in: workspaceMenu,
            action: #selector(moveActiveWorkspaceRight(_:)),
            keyEquivalent: "]",
            modifiers: [.control, .command]
        )
        installToggleWorkspaceSelectionMenu(in: workspaceMenu)

        let title = "Group Active Workspace"
        let header: NSMenuItem
        if let existing = workspaceMenu.items.first(where: { $0.title == title }) {
            header = existing
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.submenu = NSMenu(title: title)
            workspaceMenu.addItem(header)
        }
        refreshWorkspaceMenuEnhancements(in: workspaceMenu)
    }

    private func refreshWorkspaceMenuEnhancements(in workspaceMenu: NSMenu) {
        if let closeSelected = workspaceMenu.items.first(where: { $0.action == #selector(closeSelectedWorkspaces(_:)) }) {
            let count = activeMainWindowController?.selectedWorkspaceIDsInVisualOrder.count ?? 0
            closeSelected.title = count > 1 ? "Close \(count) Workspaces" : "Close Selected Workspaces"
            closeSelected.isEnabled = count > 1
            closeSelected.target = self
        }

        guard let header = workspaceMenu.items.first(where: { $0.title == "Group Active Workspace" }),
              let submenu = header.submenu else { return }

        let currentGroupID = activeMainWindowController?.activeWorkspaceGroupID
        let hasActiveWorkspace = activeMainWindowController != nil
        submenu.removeAllItems()

        let none = NSMenuItem(title: "None", action: #selector(assignActiveWorkspaceToGroup(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = nil
        none.state = currentGroupID == nil ? .on : .off
        none.isEnabled = hasActiveWorkspace
        submenu.addItem(none)

        if !workspaceStore.orderedGroups.isEmpty {
            submenu.addItem(.separator())
            for group in workspaceStore.orderedGroups {
                let item = NSMenuItem(title: group.name, action: #selector(assignActiveWorkspaceToGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id
                item.state = currentGroupID == group.id ? .on : .off
                item.isEnabled = hasActiveWorkspace
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let newGroup = NSMenuItem(title: "New Group…", action: #selector(newGroupForActiveWorkspace(_:)), keyEquivalent: "")
        newGroup.target = self
        newGroup.isEnabled = hasActiveWorkspace
        submenu.addItem(newGroup)
    }

    private func ensureMenuItem(
        titled title: String,
        in menu: NSMenu,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        if let existing = menu.items.first(where: { $0.action == action || $0.title == title }) {
            existing.title = title
            existing.action = action
            existing.keyEquivalent = keyEquivalent
            existing.keyEquivalentModifierMask = modifiers
            existing.target = self
            return
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    private func installToggleWorkspaceSelectionMenu(in workspaceMenu: NSMenu) {
        let title = "Toggle Workspace Selection"
        let header: NSMenuItem
        if let existing = workspaceMenu.items.first(where: { $0.title == title }) {
            header = existing
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.submenu = NSMenu(title: title)
            workspaceMenu.addItem(header)
        }
        guard let submenu = header.submenu else { return }
        for tag in 1...9 {
            let itemTitle = "Workspace \(tag)"
            let item: NSMenuItem
            if let existing = submenu.items.first(where: { $0.tag == tag || $0.title == itemTitle }) {
                item = existing
            } else {
                item = NSMenuItem(title: itemTitle, action: #selector(toggleWorkspaceSelectionByTag(_:)), keyEquivalent: "\(tag)")
                submenu.addItem(item)
            }
            item.title = itemTitle
            item.tag = tag
            item.action = #selector(toggleWorkspaceSelectionByTag(_:))
            item.keyEquivalent = "\(tag)"
            item.keyEquivalentModifierMask = [.option, .command]
            item.target = self
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Workspaces" else { return }
        refreshWorkspaceMenuEnhancements(in: menu)
    }

    private var activeMainWindowController: SoyehtMainWindowController? {
        (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
    }

    private var activeUndoManager: UndoManager? {
        activeMainWindowController?.window?.undoManager
    }

    private func withActivePaneGrid(_ body: (PaneGridController) -> Void) {
        guard let grid = activeMainWindowController?.activeGridController else {
            NSSound.beep()
            return
        }
        body(grid)
    }

    private func findMenuItem(in menu: NSMenu, titled title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let submenu = item.submenu, let match = findMenuItem(in: submenu, titled: title) {
                return match
            }
        }
        return nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoWindowAction(_:)):
            let title = activeUndoManager?.undoMenuItemTitle ?? "Undo"
            menuItem.title = title.isEmpty ? "Undo" : title
            return activeUndoManager?.canUndo == true
        case #selector(redoWindowAction(_:)):
            let title = activeUndoManager?.redoMenuItemTitle ?? "Redo"
            menuItem.title = title.isEmpty ? "Redo" : title
            return activeUndoManager?.canRedo == true
        case #selector(moveActiveWorkspaceLeft(_:)):
            return activeMainWindowController?.canMoveActiveWorkspace(by: -1) == true
        case #selector(moveActiveWorkspaceRight(_:)):
            return activeMainWindowController?.canMoveActiveWorkspace(by: 1) == true
        case #selector(showClawStore(_:)):
            // Gate the Claw Store on an active pairing — the views pin a
            // ServerContext and there is nothing meaningful to render
            // otherwise.
            return SessionStore.shared.currentContext() != nil
        default:
            return true
        }
    }

    /// Menu item / `⌘⇧C` target. Toggles the floating sidebar overlay on
    /// the key main window (or first main window if none is key). The
    /// overlay lives inside the main window via
    /// `WindowChromeViewController`, NOT as a separate NSWindow — matches
    /// SXnc2 V2 `floatSidebar`.
    @IBAction func showConversationsSidebar(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? SoyehtMainWindowController)
            ?? NSApp.windows
                .compactMap { $0.windowController as? SoyehtMainWindowController }
                .first
        target?.toggleSidebarOverlay()
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
        // Product decision (Fase 2 Opção A): the last logout returns to the
        // same onboarding flow the first launch uses, instead of the legacy
        // LoginViewController sheet. If the user still has other paired
        // servers, the main window stays and the sheet is never opened.
        if store.pairedServers.isEmpty {
            closeAllMainWindows()
            openWelcomeWindow()
        }
    }

    private func closeAllMainWindows() {
        for wc in windowControllers.compactMap({ $0 as? SoyehtMainWindowController }) {
            wc.close()
        }
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
