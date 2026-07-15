//
//  AppDelegate.swift
//  Soyeht
//

import Cocoa
import ApplicationServices
import AuthenticationServices
import Darwin
import SoyehtCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, MainMenuRuntimeProviding, MainMenuActionHandling {

    // Strong references to all open window controllers.
    // NSWindow.windowController is weak, so without this the WC is immediately deallocated.
    private var windowControllers: [NSWindowController] = []

    /// Single source of truth for Workspaces. Lives for the process lifetime.
    let workspaceStore = WorkspaceStore()
    let conversationStore = ConversationStore()

    /// Lazy command palette (Fase 3.2). Built on first ⌘P invocation so
    /// launch time isn't affected by NSPanel instantiation + view build.
    private var commandPalette: CommandPaletteWindowController?
    private var automationService: SoyehtAutomationService?
    private lazy var automationRequestRouter = SoyehtAutomationRequestRouter(
        workspaceStore: workspaceStore,
        conversationStore: conversationStore,
        mainWindowControllers: { [weak self] in
            self?.mainWindowControllers ?? []
        },
        activeMainWindowController: { [weak self] in
            self?.activeMainWindowController
        },
        openNewMainWindow: { [weak self] in
            guard let self else {
                preconditionFailure("AppDelegate must outlive an active automation request.")
            }
            return self.openNewMainWindow()
        }
    )
    private lazy var windowCommandPerformer = UICommandWindowActionPerformer(
        targetProvider: { [weak self] in self?.uiMainWindowController }
    )
    private lazy var appCommandActionRouter = AppCommandActionRouter(
        applicationActions: self,
        windowActions: windowCommandPerformer
    )
    private lazy var mainMenuController = MainMenuController(runtime: self, actionHandler: self)
    private var isTerminating = false

    var isTerminatingForWindowRestoration: Bool { isTerminating }

    func applicationWillFinishLaunching(_ notification: Notification) {
        mainMenuController.installProgrammaticMainMenu()
        // Kick off the login-shell PATH probe immediately so it's ready by
        // the time the user opens the first bash pane. Async; never blocks
        // launch.
        LoginShellEnvironmentResolver.shared.warmup()
        normalizeInheritedWorkingDirectory()
        WorkspaceBookmarkStore.shared.forgetPersistedDocumentWorkspacePaths()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if DEBUG
        if DevEmbeddedEngineSmokeRunner.startIfRequested() {
            return
        }
        if DevLocalAppleAttestationCaptureRunner.startIfRequested() {
            return
        }
        #endif

        mainMenuController.installProgrammaticMainMenuIfNeeded()
        AppEnvironment.workspaceStore = workspaceStore
        AppEnvironment.conversationStore = conversationStore
        workspaceStore.bootstrap(paneTransferBridge: WorkspaceStore.PaneTransferBridge(
            begin: { [weak self] transfers in
                self?.preparePaneTransfers(transfers)
            }
        ))
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
        WorkspaceSwitchBenchmark.scheduleIfRequestedByEnvironment()
        #endif
        // One-shot import of legacy macOS paired servers into the
        // unified ServerStore. SessionStore remains the credential and
        // active-context adapter, but the machine inventory must be
        // present in ServerStore even for servers paired before this
        // migration shipped.
        ServerInventoryWriter().migrateLegacyIfNeeded(
            seed: SessionStore.shared.pairedServers.map { $0.toServer() }
        )
        SoyehtUpdater.shared.startIfConfigured()
        // Boot the app-level WebSocket server so paired iPhones can reach us
        // as soon as the app launches, without a QR scan. Presence + pane
        // attach listeners; ports are cached in UserDefaults.
        PairingPresenceServer.shared.start()
        MacAutomaticIPhoneDiscoveryService.shared.start()
        do {
            let automationRootURL = try SoyehtAutomationService.defaultRootURL()
            automationService = SoyehtAutomationService(rootURL: automationRootURL) { [weak self] request in
                guard let self else { return SoyehtAutomationResult() }
                return try await self.handleAutomationRequest(request)
            }
            automationService?.start()
        } catch {
            NSLog("Soyeht automation disabled: \(error.localizedDescription)")
        }
        // Touch PaneStatusTracker early so it starts listening to
        // ConversationStore changes before any pane is created.
        _ = PaneStatusTracker.shared
        // When the app has no paired server yet, open the dedicated Welcome
        // window instead of the main workspace. The main window only appears
        // after pairing completes — avoids the old "empty workspace behind a
        // sheet" UX. When the user already has a session, skip straight to
        // the main window. See Fase 2 / US-01..US-04 in the roadmap.
        Task { [weak self] in
            await self?.openInitialWindow()
        }

        #if DEBUG
        // Cursor-policy audit: after the initial window paints, walk the
        // hierarchy and report any custom NSView that isn't a
        // `MacCursor.ChromeView` (or in the AppKit safe-list). Catches
        // regressions where new chrome views forget to opt into the shared
        // cursor utility. Production builds skip this entirely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            for window in NSApp.windows {
                guard let root = window.contentView else { continue }
                MacCursor.auditHierarchy(root) {
                    Swift.print("[MacCursor:\(window.title.isEmpty ? "untitled" : window.title)] \($0)")
                }
            }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Flush debounced persistence BEFORE AppKit tears everything down,
        // otherwise the last ~300ms of mutations (renames, focus changes,
        // new conversations) are lost on normal quit.
        workspaceStore.flushPendingSave()
        WorkspaceBookmarkStore.shared.releaseAll()
        automationService?.stop()
        MacAutomaticIPhoneDiscoveryService.shared.stop()
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
    private var uninstallWindowController: UninstallWindowController?
    private var uninstallCloseObserver: NSObjectProtocol?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let result = QRScanResult.from(url: url) else { return }
        switch result {
        case .pair(let token, let host), .connect(let token, let host), .invite(let token, let host):
            autoConnect(token: token, host: host)
        case .householdPairDevice:
            // Founder-pair URI from a peer household (typically Linux engine
            // running `theyos install`). Mac becomes the first owner device.
            // The URI carries a `host` fallback when the founder's Bonjour
            // publisher does not interoperate (Linux mdns-sd). Pair via the
            // same SoyehtCore service the iPhone uses; Secure Enclave handles
            // biometric prompt (Touch ID).
            autoHouseholdPairDevice(url: url)
        case .clawShareInvite, .householdDevicePairing, .householdPairMachine:
            // Claw-share is an iPhone-only flow; the Mac app does not redeem
            // claw-share invites via the URL handler.
            return
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Keep the programmatic builder as the runtime source before layering
        // development-only menu items onto it.
        mainMenuController.installProgrammaticMainMenuIfNeeded()
        mainMenuController.installInternalDebugMenuIfNeeded()
    }

    private func autoHouseholdPairDevice(url: URL) {
        Task { @MainActor in
            let displayName = Host.current().localizedName ?? "Mac"
            NSLog("autoHouseholdPairDevice url=%@", url.absoluteString)
            // Runtime SE probe: prefer biometry-bound Secure Enclave residency,
            // fall back to the software keychain only when the actual signing
            // path rejects SE persistence (Debug builds signed with Apple
            // Development hit errSecMissingEntitlement -34018; Mac Studio /
            // Mac mini without Touch ID and without Apple Watch unlock hit
            // errSecAuthFailed when the ACL evaluates). The fallback key is
            // bound to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so it
            // still resists Migration Assistant and unencrypted backups
            // (see OwnerIdentityKey.swift `.softwareKeychain` branch).
            let protection = SecureEnclaveOwnerIdentityKeyProvider.preferredProtection()
            NSLog("autoHouseholdPairDevice protection=%@", String(describing: protection))
            let provider = SecureEnclaveOwnerIdentityKeyProvider(protection: protection)
            do {
                let state = try await HouseholdPairingService(keyProvider: provider)
                    .pair(url: url, displayName: displayName)
                NSLog("household.pair_device.success hh_id=\(state.householdId)")
                dismissWelcomeAndLoginIfNeeded()
                if NSApp.windows.compactMap({ $0.windowController as? SoyehtMainWindowController }).isEmpty {
                    openNewMainWindow()
                }
            } catch {
                NSLog("household.pair_device.failed error=\(error)")
                let alert = NSAlert()
                alert.messageText = "Couldn't join household"
                alert.informativeText = String(describing: error)
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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

    private func openInitialWindow() async {
        if !SessionStore.shared.credentialedCanonicalServers().isEmpty {
            restoreMainWindowsOrOpenDefault()
            return
        }

        openWelcomeWindow()
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
        initialWorkspaceID: Workspace.ID? = nil,
        createFreshWorkspace: Bool = false
    ) -> SoyehtMainWindowController {
        let windowID = initialWindowID ?? UUID().uuidString
        let workspaceID: Workspace.ID?
        if let initialWorkspaceID {
            workspaceID = initialWorkspaceID
        } else if createFreshWorkspace {
            workspaceID = workspaceStore.addAdhocWorkspace(toWindow: windowID).id
        } else {
            workspaceID = nil
        }

        let wc = SoyehtMainWindowController(
            store: workspaceStore,
            windowID: windowID,
            restoredWorkspaceID: workspaceID
        )
        retain(wc)
        wc.showWindow(nil)
        return wc
    }

    private func restoreMainWindowsOrOpenDefault() {
        let sessions = workspaceStore.restorableWindowSessions()
        guard !sessions.isEmpty else {
            openNewMainWindow()
            return
        }
        for session in sessions {
            openNewMainWindow(
                initialWindowID: session.windowID,
                initialWorkspaceID: session.activeWorkspaceID
            )
        }
    }

    private func retain(_ wc: NSWindowController) {
        windowControllers.append(wc)
        if let window = wc.window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self, weak wc] _ in
                Task { @MainActor in
                    self?.windowControllers.removeAll(where: { $0 === wc })
                }
            }
        }
    }

    private func handleAutomationRequest(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        return try await automationRequestRouter.handle(request)
    }
    private var mainWindowControllers: [SoyehtMainWindowController] {
        var seen: Set<String> = []
        var result: [SoyehtMainWindowController] = []
        let candidates = windowControllers.compactMap { $0 as? SoyehtMainWindowController }
            + NSApp.windows.compactMap { $0.windowController as? SoyehtMainWindowController }
        for controller in candidates where !seen.contains(controller.windowID) {
            result.append(controller)
            seen.insert(controller.windowID)
        }
        return result
    }

    private func preparePaneTransfers(_ transfers: [WorkspaceStore.PaneTransfer]) {
        for transfer in transfers where transfer.source != transfer.destination {
            let controllers = mainWindowControllers
            let destinationController = controllers.first {
                workspaceStore.workspace(transfer.destination, isInWindow: $0.windowID)
            }
            let sourceController = controllers.first {
                workspaceStore.workspace(transfer.source, isInWindow: $0.windowID)
            }
            _ = (sourceController ?? destinationController)?.prepareLivePaneHandoff(
                paneID: transfer.paneID,
                from: transfer.source,
                to: transfer.destination,
                destinationController: destinationController
            )
        }
    }

    /// Debug builds are commonly launched from a shell inside the repo under
    /// `~/Documents`, which makes the app inherit a TCC-protected cwd and
    /// triggers the recurring "access files in your Documents folder" prompt
    /// before the user intentionally picks any workspace folder. Move the
    /// process to the user's home directory up front so the default shell cwd
    /// is stable and not tied to a protected project folder.
    private func normalizeInheritedWorkingDirectory() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        guard FileManager.default.changeCurrentDirectoryPath(homeDirectory.path) else {
            NSLog("[AppDelegate] failed to switch cwd to \(homeDirectory.path)")
            return
        }
        setenv("PWD", homeDirectory.path, 1)
        unsetenv("OLDPWD")
    }

    @IBAction func showPreferences(_ sender: Any) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @IBAction func showAgentVisualPermissions(_ sender: Any?) {
        runAgentVisualPermissionsFlow()
    }

    @IBAction func showPairedDevices(_ sender: Any) {
        PreferencesWindowController.shared.showDevicesTab()
    }

    @IBAction func showConnectedServers(_ sender: Any?) {
        ConnectedServersWindowController.shared.showWindow(nil)
    }

    private struct AgentVisualPermissionState {
        let screenRecording: Bool
        let accessibility: Bool

        var isComplete: Bool {
            screenRecording && accessibility
        }
    }

    private func runAgentVisualPermissionsFlow() {
        let initial = currentAgentVisualPermissionState()

        if !initial.screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }

        if !initial.accessibility {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        let current = currentAgentVisualPermissionState()
        showAgentVisualPermissionsResult(current)
    }

    private func currentAgentVisualPermissionState() -> AgentVisualPermissionState {
        AgentVisualPermissionState(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    private func showAgentVisualPermissionsResult(_ state: AgentVisualPermissionState) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Soyeht"
        let screenStatus = state.screenRecording ? "Granted" : "Needs approval"
        let accessibilityStatus = state.accessibility ? "Granted" : "Needs approval"

        let alert = NSAlert()
        alert.messageText = "Agent Visual Permissions"
        alert.informativeText = """
        Native Tools uses these macOS permissions for agents launched inside \(appName).

        Screen Recording: \(screenStatus)
        Accessibility: \(accessibilityStatus)

        These permissions are granted separately for Soyeht and Soyeht Dev. After changing them, quit and reopen \(appName) so new agent processes inherit the updated access.
        """
        alert.alertStyle = state.isComplete ? .informational : .warning
        if state.isComplete {
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
        }

        let response = alert.runModal()
        if !state.isComplete && response == .alertFirstButtonReturn {
            openAgentVisualPermissionsSettings(for: state)
        }
    }

    private func openAgentVisualPermissionsSettings(for state: AgentVisualPermissionState) {
        let screenRecordingURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")

        let url: URL?
        if !state.screenRecording {
            url = screenRecordingURL ?? fallbackURL
        } else if !state.accessibility {
            url = accessibilityURL ?? fallbackURL
        } else {
            url = fallbackURL
        }

        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {
        windowCommandPerformer.performMoveFocusedPaneToWorkspaceCommand(sender)
    }

    func performAppCommand(_ commandID: AppCommandID, sender: Any?) {
        appCommandActionRouter.performAppCommand(commandID, sender: sender)
    }

    @IBAction func selectWorkspaceByTag(_ sender: Any?) {
        windowCommandPerformer.performSelectWorkspaceCommand(sender)
    }

    @IBAction func moveActiveWorkspaceLeft(_ sender: Any?) {
        windowCommandPerformer.performMoveActiveWorkspaceLeftCommand(sender)
    }

    @IBAction func moveActiveWorkspaceRight(_ sender: Any?) {
        windowCommandPerformer.performMoveActiveWorkspaceRightCommand(sender)
    }

    @IBAction func splitPaneVertical(_ sender: Any?) { windowCommandPerformer.performSplitPaneVerticalCommand(sender) }
    @IBAction func splitPaneHorizontal(_ sender: Any?) { windowCommandPerformer.performSplitPaneHorizontalCommand(sender) }
    @IBAction func closeFocusedPane(_ sender: Any?) { windowCommandPerformer.performCloseFocusedPaneCommand(sender) }
    @IBAction func undoWindowAction(_ sender: Any?) {
        windowCommandPerformer.performUndoWindowActionCommand(sender)
    }
    @IBAction func redoWindowAction(_ sender: Any?) {
        windowCommandPerformer.performRedoWindowActionCommand(sender)
    }
    @IBAction func focusPaneLeft(_ sender: Any?) { windowCommandPerformer.performFocusPaneLeftCommand(sender) }
    @IBAction func focusPaneRight(_ sender: Any?) { windowCommandPerformer.performFocusPaneRightCommand(sender) }
    @IBAction func focusPaneUp(_ sender: Any?) { windowCommandPerformer.performFocusPaneUpCommand(sender) }
    @IBAction func focusPaneDown(_ sender: Any?) { windowCommandPerformer.performFocusPaneDownCommand(sender) }
    @IBAction func toggleZoomFocusedPane(_ sender: Any?) { windowCommandPerformer.performToggleZoomFocusedPaneCommand(sender) }
    @IBAction func exitZoom(_ sender: Any?) { windowCommandPerformer.performExitZoomCommand(sender) }
    @IBAction func swapPaneLeft(_ sender: Any?) { windowCommandPerformer.performSwapPaneLeftCommand(sender) }
    @IBAction func swapPaneRight(_ sender: Any?) { windowCommandPerformer.performSwapPaneRightCommand(sender) }
    @IBAction func swapPaneUp(_ sender: Any?) { windowCommandPerformer.performSwapPaneUpCommand(sender) }
    @IBAction func swapPaneDown(_ sender: Any?) { windowCommandPerformer.performSwapPaneDownCommand(sender) }
    @IBAction func rotateFocusedSplit(_ sender: Any?) { windowCommandPerformer.performRotateFocusedSplitCommand(sender) }
    @IBAction func newGroupForActiveWorkspace(_ sender: Any?) {
        windowCommandPerformer.performNewGroupForActiveWorkspaceCommand(sender)
    }
    @IBAction func assignActiveWorkspaceToGroup(_ sender: NSMenuItem) {
        windowCommandPerformer.performAssignActiveWorkspaceToGroupCommand(sender)
    }

    @IBAction func newWindow(_ sender: Any) {
        openNewMainWindow(createFreshWorkspace: true)
    }

    @IBAction func closeActiveWorkspace(_ sender: Any?) {
        windowCommandPerformer.performCloseActiveWorkspaceCommand(sender)
    }

    @IBAction func defaultFontSize(_ sender: Any?) {
        setTerminalFontSize(TerminalPreferences.defaultFontSize)
    }

    @IBAction func biggerFont(_ sender: Any?) {
        setTerminalFontSize(TerminalPreferences.shared.fontSize + 1)
    }

    @IBAction func smallerFont(_ sender: Any?) {
        setTerminalFontSize(TerminalPreferences.shared.fontSize - 1)
    }

    private func setTerminalFontSize(_ size: CGFloat) {
        TerminalPreferences.shared.fontSize = size
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        SoyehtUpdater.shared.checkForUpdates(sender)
    }

    @IBAction func uninstallSoyeht(_ sender: Any?) {
        showUninstallWindow(context: .inApp)
    }

    private func showUninstallWindow(context: SoyehtUninstallPresentationContext) {
        if let existing = uninstallWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = UninstallWindowController(context: context)
        uninstallWindowController = wc
        if let window = wc.window {
            uninstallCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let token = self.uninstallCloseObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.uninstallCloseObserver = nil
                    }
                    self.uninstallWindowController = nil
                }
            }
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @IBAction func newConversation(_ sender: Any?) {
        windowCommandPerformer.performNewConversationCommand(sender)
    }

    // MARK: - Claw Store (Fase 3)

    /// Strong reference to the Claw Store window so NSHostingController's
    /// SwiftUI view model stays alive for the full session. NSWindow holds
    /// its controller weakly.
    private var clawStoreWindowController: ClawStoreWindowController?

    /// Token for the `NSWindow.willCloseNotification` observer wired when
    /// the Claw Store opens. Stored so we can remove it explicitly on close
    /// — the block-based API returns a token that must be passed to
    /// `removeObserver` or the registration leaks forever.
    private var clawStoreCloseObserver: NSObjectProtocol?

    @IBAction func showClawStore(_ sender: Any?) {
        guard SoyehtFeatureFlags.clawStoreEnabled else {
            showClawStoreComingSoonAlert()
            return
        }
        if let target = uiMainWindowController {
            target.openClawDrawerOverlay()
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard MacActiveServerContextResolver.activeContext() != nil else {
            openWelcomeWindow()
            return
        }
        let target = openNewMainWindow()
        target.openClawDrawerOverlay()
        target.window?.makeKeyAndOrderFront(nil)
    }

    @IBAction func showStandaloneClawStore(_ sender: Any?) {
        guard SoyehtFeatureFlags.clawStoreEnabled else {
            showClawStoreComingSoonAlert()
            return
        }
        guard let context = MacActiveServerContextResolver.activeContext() else {
            openWelcomeWindow()
            return
        }
        showStandaloneClawStore(context: context)
    }

    private func showStandaloneClawStore(context: ServerContext) {
        if let existing = clawStoreWindowController {
            existing.rebind(to: context)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ClawStoreWindowController(
            context: context,
            onOpenTerminal: { [weak self] clawName in
                self?.openClawTerminalFromStore(clawName: clawName)
            },
            onConnectThisMac: { [weak self] in
                self?.connectThisMacFromClawStore()
            },
            onShowConnectedServers: { [weak self] in
                self?.showConnectedServers(nil)
            }
        )
        // Singleton window: the property is the only strong reference.
        // Don't also call `retain(_:)` — that would double-register close
        // observers (array + the one below) and leak both.
        clawStoreWindowController = wc
        if let window = wc.window {
            clawStoreCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let token = self.clawStoreCloseObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.clawStoreCloseObserver = nil
                    }
                    self.clawStoreWindowController = nil
                }
            }
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    private func connectThisMacFromClawStore() {
        guard let localServer = SessionStore.shared.credentialedCanonicalServers().first(where: isLocalEngineServer) else {
            openWelcomeWindow()
            return
        }

        SessionStore.shared.setActiveServer(id: localServer.id)
        DispatchQueue.main.async { [weak self] in
            guard let context = MacActiveServerContextResolver.activeContext() else { return }
            self?.showStandaloneClawStore(context: context)
        }
    }

    private func closeStandaloneClawStoreWindow() {
        guard let wc = clawStoreWindowController else { return }
        if let token = clawStoreCloseObserver {
            NotificationCenter.default.removeObserver(token)
            clawStoreCloseObserver = nil
        }
        clawStoreWindowController = nil
        wc.close()
    }

    private func isLocalEngineServer(_ server: PairedServer) -> Bool {
        guard server.kind == .engine else { return false }
        guard let host = normalizedServerHost(server.host) else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func normalizedServerHost(_ rawHost: String) -> String? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let host = URLComponents(string: trimmed)?.host {
            return host.lowercased()
        }

        return URLComponents(string: "soyeht://\(trimmed)")?.host?.lowercased()
    }

    private func openClawTerminalFromStore(clawName: String) {
        let target = uiMainWindowController ?? mainWindowControllers.first ?? openNewMainWindow()
        target.openClawTerminal(clawName: clawName)
    }

    private func showClawStoreComingSoonAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "clawStore.comingSoon.title", comment: "Alert title shown while Claw Store is disabled for launch.")
        alert.addButton(withTitle: String(localized: "common.button.ok"))
        if let window = NSApp.keyWindow ?? uiMainWindowController?.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
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
        let parent = uiMainWindowController?.window
        palette.present(from: parent)
    }

    /// Resolve a palette selection against the public UI command target,
    /// activate the workspace, and — if a pane was selected —
    /// focus it. Mirrors the sidebar's `focusPane(workspaceID:conversationID:)`
    /// path so the behaviour is identical whichever entry point the user
    /// uses.
    private func jump(to item: CommandPaletteItem) {
        guard let target = uiMainWindowController else {
            NSSound.beep()
            return
        }
        if let paneID = item.paneID {
            target.focusPane(workspaceID: item.workspaceID, conversationID: paneID)
        } else {
            target.activate(workspaceID: item.workspaceID)
        }
    }

    var uiMainWindowController: SoyehtMainWindowController? {
        Self.uiMainWindowController()
    }

    /// Automation/headless requests may target the active UI window or fall
    /// back to an existing retained main window when no UI window is key/main.
    /// Public menu and shortcut paths must use `uiMainWindowController`.
    var activeMainWindowController: SoyehtMainWindowController? {
        automationMainWindowController
    }

    private var automationMainWindowController: SoyehtMainWindowController? {
        Self.mainWindowCommandTargetResolver(
            automationFallback: mainWindowControllers.first
        ).automationTarget
    }

    func retainMenuWindowController(_ windowController: NSWindowController) {
        retain(windowController)
    }

    fileprivate static func uiMainWindowController() -> SoyehtMainWindowController? {
        mainWindowCommandTargetResolver().uiTarget
    }

    fileprivate static func mainWindowCommandTargetResolver(
        automationFallback: SoyehtMainWindowController? = nil
    ) -> MainWindowCommandTargetResolver<SoyehtMainWindowController> {
        MainWindowCommandTargetResolver(
            keyWindowTarget: mainWindowController(owning: NSApp.keyWindow),
            mainWindowTarget: mainWindowController(owning: NSApp.mainWindow),
            automationFallbackTarget: automationFallback
        )
    }

    fileprivate static func mainWindowController(owning window: NSWindow?) -> SoyehtMainWindowController? {
        var current = window
        while let window = current {
            if let controller = window.windowController as? SoyehtMainWindowController {
                return controller
            }
            current = window.sheetParent ?? window.parent
        }
        return nil
    }

    /// Menu item / `⌘⇧C` target. Toggles the floating sidebar overlay on
    /// the public UI command target. The
    /// overlay lives inside the main window via
    /// `WindowChromeViewController`, NOT as a separate NSWindow — matches
    /// SXnc2 V2 `floatSidebar`.
    @IBAction func showConversationsSidebar(_ sender: Any?) {
        windowCommandPerformer.performShowConversationsSidebarCommand(sender)
    }

    @IBAction func logout(_ sender: Any) {
        let store = SessionStore.shared
        guard !store.credentialedCanonicalServers().isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "appMenu.logout.alert.title", comment: "Logout confirmation alert title.")
        alert.informativeText = String(localized: "appMenu.logout.alert.message", comment: "Logout confirmation alert body — explains the user will need to re-authenticate.")
        alert.addButton(withTitle: String(localized: "appMenu.logout.alert.button.logout", comment: "Destructive button that performs logout."))
        alert.addButton(withTitle: String(localized: "common.button.cancel", comment: "Generic Cancel."))
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
        if store.credentialedCanonicalServers().isEmpty {
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
            panel.title = String(localized: "auth.login.title", comment: "Title above the login form.")
            panel.contentViewController = loginVC
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension AppDelegate: AppCommandApplicationActionPerforming {
    func performNewWindowCommand(_ sender: Any?) {
        newWindow(sender ?? self)
    }

    func performShowCommandPaletteCommand(_ sender: Any?) {
        showCommandPalette(sender)
    }

    func performCheckForUpdatesCommand(_ sender: Any?) {
        checkForUpdates(sender)
    }

    func performShowPreferencesCommand(_ sender: Any?) {
        showPreferences(sender ?? self)
    }

    func performShowAgentVisualPermissionsCommand(_ sender: Any?) {
        showAgentVisualPermissions(sender)
    }

    func performShowPairedDevicesCommand(_ sender: Any?) {
        showPairedDevices(sender ?? self)
    }

    func performShowConnectedServersCommand(_ sender: Any?) {
        showConnectedServers(sender)
    }

    func performUninstallSoyehtCommand(_ sender: Any?) {
        uninstallSoyeht(sender)
    }

    func performShowClawStoreCommand(_ sender: Any?) {
        showStandaloneClawStore(sender)
    }
}

@MainActor
private final class UICommandWindowActionPerformer: AppCommandWindowActionPerforming {
    private let targetProvider: () -> SoyehtMainWindowController?

    init(targetProvider: @escaping () -> SoyehtMainWindowController?) {
        self.targetProvider = targetProvider
    }

    @discardableResult
    func performNewConversationCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.newConversation(sender)
        return true
    }

    @discardableResult
    func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.toggleSidebarOverlay()
        return true
    }

    @discardableResult
    func performUndoWindowActionCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.window?.undoManager?.undo()
        target.refreshWorkspaceChromeFromStore()
        return true
    }

    @discardableResult
    func performRedoWindowActionCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.window?.undoManager?.redo()
        target.refreshWorkspaceChromeFromStore()
        return true
    }

    @discardableResult
    func performSplitPaneVerticalCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.splitPaneVertical(sender) }
    }

    @discardableResult
    func performSplitPaneHorizontalCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.splitPaneHorizontal(sender) }
    }

    @discardableResult
    func performCloseFocusedPaneCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.closeFocusedPane(sender) }
    }

    @discardableResult
    func performFocusPaneLeftCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneLeft(sender) }
    }

    @discardableResult
    func performFocusPaneRightCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneRight(sender) }
    }

    @discardableResult
    func performFocusPaneUpCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneUp(sender) }
    }

    @discardableResult
    func performFocusPaneDownCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneDown(sender) }
    }

    @discardableResult
    func performToggleZoomFocusedPaneCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.toggleZoomFocusedPane(sender) }
    }

    @discardableResult
    func performExitZoomCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.exitZoom(sender) }
    }

    @discardableResult
    func performSwapPaneLeftCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneLeft(sender) }
    }

    @discardableResult
    func performSwapPaneRightCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneRight(sender) }
    }

    @discardableResult
    func performSwapPaneUpCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneUp(sender) }
    }

    @discardableResult
    func performSwapPaneDownCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneDown(sender) }
    }

    @discardableResult
    func performRotateFocusedSplitCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.rotateFocusedSplit(sender) }
    }

    @discardableResult
    func performSelectWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.selectWorkspaceByTag(sender)
        return true
    }

    @discardableResult
    func performMoveFocusedPaneToWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveFocusedPaneToWorkspaceByTag(sender)
        return true
    }

    @discardableResult
    func performMoveActiveWorkspaceLeftCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveActiveWorkspaceLeft(sender)
        return true
    }

    @discardableResult
    func performMoveActiveWorkspaceRightCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveActiveWorkspaceRight(sender)
        return true
    }

    @discardableResult
    func performNewGroupForActiveWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.promptCreateGroupForActiveWorkspace(sender)
        return true
    }

    @discardableResult
    func performAssignActiveWorkspaceToGroupCommand(_ sender: NSMenuItem) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.assignActiveWorkspaceToGroup(sender.representedObject as? Group.ID)
        return true
    }

    @discardableResult
    func performCloseActiveWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.closeActiveWorkspace(sender)
        return true
    }

    @discardableResult
    private func withActivePaneGrid(_ body: (PaneGridController) -> Void) -> Bool {
        guard let grid = targetProvider()?.activeGridController else {
            NSSound.beep()
            return false
        }
        body(grid)
        return true
    }
}

// MARK: - WorkspaceSwitchBenchmark (DEBUG-only)
#if DEBUG

/// Drives a deterministic round-robin of `activate(workspaceID:)` calls on the
/// currently-key main window, accumulates `PerfTrace` samples, and writes a
/// JSON report to disk. Two entry points:
///
/// 1. **Env var.** Launching the app with `SOYEHT_BENCH_SWITCH=N` (where N is
///    the cycle count) triggers a run automatically 5 seconds after the main
///    window opens, then writes JSON to `/tmp/soyeht-switch-bench.json` and
///    logs the path. Used by the script that wraps build → launch → measure.
/// 2. **Debug menu item.** "Debug → Benchmark Workspace Switching (50 cycles)"
///    runs the same flow and shows an alert with the path + p50/p95/max of the
///    `activate.total` checkpoint.
///
/// Each "cycle" iterates every workspace once (round-robin), so a 50-cycle run
/// against a 4-workspace window produces 200 `activate.total` samples. Between
/// switches the runner yields ~50ms via `DispatchQueue.main.asyncAfter` so the
/// async tail of `reapplyPersistedFocus` (a `DispatchQueue.main.async` second
/// pass at `WorkspaceContainerViewController.swift:161`) and any observation-
/// driven `tabs.rebuild` invalidations get measured in the same window.
@MainActor
enum WorkspaceSwitchBenchmark {

    private static let envVar = "SOYEHT_BENCH_SWITCH"
    private static var defaultOutputURL: URL {
        // Soyeht/Debug/workspace-switch-bench.json — replaces the legacy
        // `/tmp/soyeht-switch-bench.json` so a benchmark run survives an
        // OS-driven `/tmp` purge, and so the file isn't world-readable
        // alongside other apps' temp files.
        AppSupportDirectory.debugDirectory()
            .appendingPathComponent("workspace-switch-bench.json")
    }
    private static var inFlight = false

    static func scheduleIfRequestedByEnvironment() {
        guard let raw = ProcessInfo.processInfo.environment[envVar],
              let cycles = Int(raw), cycles > 0 else { return }
        NSLog("[bench] %@=%d → benchmark scheduled in 5s", envVar, cycles)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            run(cycles: cycles, settleDelay: 0.05) { result in
                if let result {
                    NSLog("[bench] DONE — %d samples → %@", result.totalSamples, result.outputPath.path)
                    NSLog("[bench] activate.total p50=%.2fms p95=%.2fms max=%.2fms",
                          result.activateTotalP50, result.activateTotalP95, result.activateTotalMax)
                } else {
                    NSLog("[bench] FAILED — no main window or <2 workspaces")
                }
            }
        }
    }

    struct RunResult {
        let outputPath: URL
        let totalSamples: Int
        let activateTotalP50: Double
        let activateTotalP95: Double
        let activateTotalMax: Double
    }

    static func run(
        cycles: Int,
        settleDelay: TimeInterval = 0.05,
        completion: @escaping (RunResult?) -> Void
    ) {
        guard !inFlight else {
            NSLog("[bench] already running, ignoring re-entry")
            completion(nil)
            return
        }
        guard let mainWC = activeMainWindowController() else {
            NSLog("[bench] no SoyehtMainWindowController available")
            completion(nil)
            return
        }
        let workspaceIDs = mainWC.store.orderedWorkspaces.map(\.id)
        guard workspaceIDs.count >= 2 else {
            NSLog("[bench] need at least 2 workspaces, found %d", workspaceIDs.count)
            completion(nil)
            return
        }

        // Start from a known workspace so the very first activate() actually
        // does work (skipping the same-id guard at SoyehtMainWindowController.swift:502).
        // We aim for `mainWC.activeWorkspaceID == workspaceIDs[0]`. If we're
        // already there, great; if not, do a one-off activate that we don't
        // sample (PerfTrace.startCollecting comes after).
        if mainWC.activeWorkspaceID != workspaceIDs[0] {
            mainWC.activate(workspaceID: workspaceIDs[0])
        }

        inFlight = true
        PerfTrace.startCollecting()

        let plan = (0..<(cycles * workspaceIDs.count)).map { idx -> Workspace.ID in
            // Always step to a different workspace so the activate guard never
            // short-circuits. With at least 2 workspaces, (idx + 1) % count
            // gives us a strict round-robin starting at workspaceIDs[1].
            workspaceIDs[(idx + 1) % workspaceIDs.count]
        }

        var index = 0
        func step() {
            guard index < plan.count else { finalizeRun(mainWC: mainWC, workspaceCount: workspaceIDs.count, cycles: cycles, completion: completion); return }
            let target = plan[index]
            mainWC.activate(workspaceID: target)
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { step() }
        }
        step()
    }

    private static func finalizeRun(
        mainWC: SoyehtMainWindowController,
        workspaceCount: Int,
        cycles: Int,
        completion: @escaping (RunResult?) -> Void
    ) {
        let samples = PerfTrace.stopCollecting()
        inFlight = false

        let stats = samples
            .mapValues { Stats.from($0) }
            .sorted { $0.key < $1.key }
        let totalSamples = samples.values.reduce(0) { $0 + $1.count }

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "workspaceCount": workspaceCount,
            "cyclesPerWorkspace": cycles,
            "totalSwitches": cycles * workspaceCount,
            "totalSamples": totalSamples,
            "checkpoints": Dictionary(uniqueKeysWithValues: stats.map { ($0.key, $0.value.dictionary) })
        ]

        let path = ProcessInfo.processInfo.environment["SOYEHT_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
            ?? defaultOutputURL

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: path, options: .atomic)
        } catch {
            NSLog("[bench] write failed: %@", String(describing: error))
            completion(nil)
            return
        }

        let activateTotal = samples["activate.total"] ?? []
        let s = Stats.from(activateTotal)
        completion(RunResult(
            outputPath: path,
            totalSamples: totalSamples,
            activateTotalP50: s.p50,
            activateTotalP95: s.p95,
            activateTotalMax: s.max
        ))
    }

    static func presentResult(_ result: RunResult?, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        if let result {
            alert.messageText = String(localized: "debug.benchmark.result.title")
            alert.informativeText = """
                activate.total p50: \(String(format: "%.2f", result.activateTotalP50)) ms
                activate.total p95: \(String(format: "%.2f", result.activateTotalP95)) ms
                activate.total max: \(String(format: "%.2f", result.activateTotalMax)) ms
                Total samples: \(result.totalSamples)

                Full report: \(result.outputPath.path)
                """
            alert.alertStyle = .informational
        } else {
            alert.messageText = String(localized: "debug.benchmark.failed.title")
            alert.informativeText = String(localized: "debug.benchmark.failed.message")
            alert.alertStyle = .warning
        }
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func activeMainWindowController() -> SoyehtMainWindowController? {
        AppDelegate.uiMainWindowController()
    }

    struct Stats {
        let count: Int
        let min: Double
        let p50: Double
        let p90: Double
        let p95: Double
        let max: Double
        let mean: Double
        let totalMs: Double

        static func from(_ samples: [Double]) -> Stats {
            guard !samples.isEmpty else {
                return Stats(count: 0, min: 0, p50: 0, p90: 0, p95: 0, max: 0, mean: 0, totalMs: 0)
            }
            let sorted = samples.sorted()
            let total = sorted.reduce(0, +)
            return Stats(
                count: sorted.count,
                min: sorted.first!,
                p50: percentile(sorted, 0.50),
                p90: percentile(sorted, 0.90),
                p95: percentile(sorted, 0.95),
                max: sorted.last!,
                mean: total / Double(sorted.count),
                totalMs: total
            )
        }

        var dictionary: [String: Any] {
            [
                "count": count,
                "min": round2(min),
                "p50": round2(p50),
                "p90": round2(p90),
                "p95": round2(p95),
                "max": round2(max),
                "mean": round2(mean),
                "totalMs": round2(totalMs),
            ]
        }

        private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
            // Nearest-rank percentile, clamped — sufficient for a benchmark report
            // (HdrHistogram interpolation would be overkill here).
            let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
            let idx = Swift.max(0, Swift.min(sorted.count - 1, rank))
            return sorted[idx]
        }

        private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    }
}

private enum DevEmbeddedEngineSmokeRunner {
    static func startIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let profile = SoyehtInstallProfile.current

        switch DevEmbeddedEngineSmokeGate.decision(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            profile: profile
        ) {
        case .notRequested:
            return false
        case .refused(let reason):
            finish(
                result: result(
                    status: "refused",
                    reason: reason,
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                ),
                exitCode: 0,
                environment: environment
            )
            return true
        case .run:
            Task {
                await run(
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                )
            }
            return true
        }
    }

    private static func run(
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile
    ) async {
        let strict = DevEmbeddedEngineSmokeGate.strictMode(environment: environment)
        let probe = EmbeddedEngineBundleProbe(bundleURL: Bundle.main.bundleURL, profile: profile)

        do {
            let bundled = try probe.validateBundledSupport()
            try EnginePackager.install()
            let installedHelperCount = try probe.validateInstalledSupport(
                at: EnginePackager.engineDestinationDirectory
            )
            try SMAppServiceInstaller.register()

            let healthy = await TheyOSHealthProber().waitForHealthy(timeout: 30)
            guard healthy else { throw DevEmbeddedEngineSmokeError.healthTimeout }

            let bootstrap = try await HealthCheckPoller(
                baseURL: TheyOSEnvironment.bootstrapBaseURL
            ).pollUntilReady()

            finish(
                result: result(
                    status: "passed",
                    reason: nil,
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile,
                    bundledHelperCount: bundled.bundledHelperCount,
                    installedHelperCount: installedHelperCount,
                    bootstrapState: bootstrap.state.rawValue,
                    checks: [
                        "dev_bundle_gate",
                        "embedded_launchagent_probe",
                        "support_helper_install",
                        "dev_launchagent_register",
                        "health_probe",
                        "bootstrap_status_probe",
                    ]
                ),
                exitCode: 0,
                environment: environment
            )
        } catch SMAppServiceInstaller.InstallerError.requiresApproval {
            finishRecoverableSkip(
                reason: "login_items_approval_required",
                strict: strict,
                environment: environment,
                bundleIdentifier: bundleIdentifier,
                profile: profile
            )
        } catch PollerError.engineUnreachable {
            finishRecoverableSkip(
                reason: "bootstrap_status_unreachable",
                strict: strict,
                environment: environment,
                bundleIdentifier: bundleIdentifier,
                profile: profile
            )
        } catch DevEmbeddedEngineSmokeError.healthTimeout {
            finishRecoverableSkip(
                reason: "health_timeout",
                strict: strict,
                environment: environment,
                bundleIdentifier: bundleIdentifier,
                profile: profile
            )
        } catch {
            finish(
                result: result(
                    status: "failed",
                    reason: publicReason(for: error),
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                ),
                exitCode: 1,
                environment: environment
            )
        }
    }

    private static func finishRecoverableSkip(
        reason: String,
        strict: Bool,
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile
    ) {
        finish(
            result: result(
                status: strict ? "failed" : "skipped",
                reason: reason,
                environment: environment,
                bundleIdentifier: bundleIdentifier,
                profile: profile
            ),
            exitCode: strict ? 1 : 0,
            environment: environment
        )
    }

    private static func result(
        status: String,
        reason: String?,
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile,
        bundledHelperCount: Int? = nil,
        installedHelperCount: Int? = nil,
        bootstrapState: String? = nil,
        checks: [String] = []
    ) -> SmokeResult {
        SmokeResult(
            status: status,
            reason: reason,
            strict: DevEmbeddedEngineSmokeGate.strictMode(environment: environment),
            profileKind: profile.kind.rawValue,
            bundleIdentifier: bundleIdentifier,
            launchdLabel: profile.engineLaunchdLabel,
            adminPort: profile.adminPort,
            bootstrapPort: profile.bootstrapPort,
            bundledHelperCount: bundledHelperCount,
            installedHelperCount: installedHelperCount,
            bootstrapState: bootstrapState,
            checks: checks
        )
    }

    private static func finish(
        result: SmokeResult,
        exitCode: Int32,
        environment: [String: String]
    ) {
        write(result: result, environment: environment)
        NSLog(
            "[DevEmbeddedEngineSmoke] status=%@ reason=%@",
            result.status,
            result.reason ?? "none"
        )
        exit(exitCode)
    }

    private static func write(result: SmokeResult, environment: [String: String]) {
        guard let path = environment[DevEmbeddedEngineSmokeGate.resultEnvKey],
              !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: url, options: [.atomic])
        } catch {
            NSLog("[DevEmbeddedEngineSmoke] result_write_failed")
        }
    }

    private static func publicReason(for error: Error) -> String {
        switch error {
        case EnginePackagerError.supportBinaryNotFound(_):
            return "support_binary_missing"
        case let error as EmbeddedEngineBundleProbeError:
            switch error {
            case .missingLaunchAgentPlist:
                return "launchagent_plist_missing"
            case .unreadableLaunchAgentPlist:
                return "launchagent_plist_unreadable"
            case .launchAgentLabelMismatch:
                return "launchagent_label_mismatch"
            case .missingBundledHelper:
                return "bundled_helper_missing"
            case .bundledHelperNotExecutable:
                return "bundled_helper_not_executable"
            case .missingInstalledHelper:
                return "installed_helper_missing"
            case .installedHelperNotExecutable:
                return "installed_helper_not_executable"
            }
        case SMAppServiceInstaller.InstallerError.notFound:
            return "launchagent_not_found"
        case SMAppServiceInstaller.InstallerError.registrationDidNotEnable:
            return "launchagent_registration_did_not_enable"
        case SMAppServiceInstaller.InstallerError.registrationFailed(_):
            return "launchagent_registration_failed"
        default:
            return "unexpected_error"
        }
    }

    private struct SmokeResult: Encodable {
        let status: String
        let reason: String?
        let strict: Bool
        let profileKind: String
        let bundleIdentifier: String?
        let launchdLabel: String
        let adminPort: Int
        let bootstrapPort: Int
        let bundledHelperCount: Int?
        let installedHelperCount: Int?
        let bootstrapState: String?
        let checks: [String]
    }

    private enum DevEmbeddedEngineSmokeError: Error {
        case healthTimeout
    }
}

private enum DevLocalAppleAttestationCaptureRunner {
    static func startIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let profile = SoyehtInstallProfile.current

        switch DevLocalAppleAttestationCaptureGate.decision(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            profile: profile
        ) {
        case .notRequested:
            return false
        case .refused(let reason):
            finish(
                result: result(
                    status: "refused",
                    reason: reason,
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                ),
                exitCode: 0,
                environment: environment
            )
            return true
        case .run(let fixturePath):
            Task { @MainActor in
                await run(
                    fixturePath: fixturePath,
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                )
            }
            return true
        }
    }

    @MainActor
    private static func run(
        fixturePath: String,
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile
    ) async {
        do {
            try EnginePackager.install()
            try SMAppServiceInstaller.register()

            let healthy = await TheyOSHealthProber().waitForHealthy(timeout: 30)
            guard healthy else { throw CaptureError.healthTimeout }
            _ = try await HealthCheckPoller(baseURL: TheyOSEnvironment.bootstrapBaseURL).pollUntilReady()

            let client = OwnerPasskeyEnrollmentClient(
                localSocketBaseURL: URL(string: "http://soyeht-local")!,
                socketPath: localRegistrationSocketPath(profile: profile)
            )
            let start = try await client.startMacosLocalAttested()
            let request = try OwnerPasskeyEnrollmentClient.registrationRequest(from: start)
            let anchor = CaptureAnchor()
            anchor.show()

            let provider = PasskeyProvider(anchorProvider: anchor)
            let attestation = try await provider.register(request)
            let fixture = try OwnerWebauthnLocalAppleAttestationFixture(
                rpID: start.options.publicKey.rp.id,
                attestation: attestation
            )
            try fixture.write(to: URL(fileURLWithPath: fixturePath))

            finish(
                result: result(
                    status: "passed",
                    reason: nil,
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile,
                    checks: [
                        "dev_bundle_gate",
                        "dev_engine_health",
                        "local_attested_start",
                        "platform_attestation_capture",
                        "untracked_fixture_write",
                        "no_local_finish_submit",
                    ]
                ),
                exitCode: 0,
                environment: environment
            )
        } catch {
            finish(
                result: result(
                    status: "failed",
                    reason: publicReason(for: error),
                    environment: environment,
                    bundleIdentifier: bundleIdentifier,
                    profile: profile
                ),
                exitCode: 1,
                environment: environment
            )
        }
    }

    private static func localRegistrationSocketPath(profile: SoyehtInstallProfile) -> String {
        MacosLocalRegistrationSocket.path(profile: profile)
    }

    private static func result(
        status: String,
        reason: String?,
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile,
        checks: [String] = []
    ) -> CaptureResult {
        CaptureResult(
            status: status,
            reason: reason,
            profileKind: profile.kind.rawValue,
            bundleIdentifier: bundleIdentifier,
            launchdLabel: profile.engineLaunchdLabel,
            fixtureWritten: status == "passed",
            checks: checks
        )
    }

    private static func finish(
        result: CaptureResult,
        exitCode: Int32,
        environment: [String: String]
    ) {
        write(result: result, environment: environment)
        NSLog(
            "[DevLocalAppleAttestationCapture] status=%@ reason=%@",
            result.status,
            result.reason ?? "none"
        )
        exit(exitCode)
    }

    private static func write(result: CaptureResult, environment: [String: String]) {
        guard let path = environment[DevLocalAppleAttestationCaptureGate.resultEnvKey],
              !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: url, options: [.atomic])
        } catch {
            NSLog("[DevLocalAppleAttestationCapture] result_write_failed")
        }
    }

    private static func publicReason(for error: Error) -> String {
        switch error {
        case CaptureError.healthTimeout:
            return "health_timeout"
        case OwnerPasskeyRegistrationError.canceled:
            return "ceremony_canceled"
        case OwnerPasskeyRegistrationError.notHandled:
            return "ceremony_not_handled"
        case OwnerPasskeyRegistrationError.invalidResponse:
            return "ceremony_invalid_response"
        case OwnerPasskeyRegistrationError.unexpectedCredentialType:
            return "ceremony_unexpected_credential"
        case OwnerPasskeyRegistrationError.alreadyInProgress:
            return "ceremony_already_in_progress"
        case is OwnerWebauthnRegistrationDTOError:
            return "local_start_decode_failed"
        case is OwnerWebauthnLocalAttestationFixtureError:
            return "fixture_build_failed"
        case is BootstrapError:
            return "engine_request_failed"
        default:
            return "capture_failed"
        }
    }

    private struct CaptureResult: Encodable {
        let status: String
        let reason: String?
        let profileKind: String
        let bundleIdentifier: String?
        let launchdLabel: String
        let fixtureWritten: Bool
        let checks: [String]
    }

    private enum CaptureError: Error {
        case healthTimeout
    }

    @MainActor
    private final class CaptureAnchor: NSObject, PasskeyPresentationAnchorProviding {
        private let window: NSWindow

        override init() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Soyeht Dev Attestation Capture"
            let label = NSTextField(labelWithString: "Use this one-time Dev.app prompt to capture a local Apple attestation fixture.")
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.frame = NSRect(x: 36, y: 58, width: 388, height: 64)
            let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
            content.addSubview(label)
            window.contentView = content
            self.window = window
            super.init()
        }

        func show() {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func passkeyPresentationAnchor() -> ASPresentationAnchor {
            window
        }
    }
}
#endif
