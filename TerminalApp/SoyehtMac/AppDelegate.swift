//
//  AppDelegate.swift
//  Soyeht
//

import Cocoa
import ApplicationServices
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
        case .householdDevicePairing, .householdPairMachine:
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
        if !SessionStore.shared.pairedServers.isEmpty {
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

    private enum AutomationError: LocalizedError {
        case emptyWorktreeWorkspaces
        case emptyWorktreePanes
        case emptyWorkspacePanes
        case emptyPaneInput
        case emptyRenameName
        case emptyRenameTargets
        case invalidDirectory(String)
        case invalidFile(String)
        case invalidWorkspaceIDFormat(String)
        case missingPaneName(String)
        case workspaceNotFound(UUID)
        case missingConversationStore
        case noActiveMainWindow
        case windowNotFound(String)

        var errorDescription: String? {
            switch self {
            case .emptyWorktreeWorkspaces:
                return "Automation request did not include any worktree workspaces."
            case .emptyWorktreePanes:
                return "Automation request did not include any worktree panes."
            case .emptyWorkspacePanes:
                return "Automation request did not include any workspace panes."
            case .emptyPaneInput:
                return "Automation request did not include text to send."
            case .emptyRenameName:
                return "Automation request did not include a new name."
            case .emptyRenameTargets:
                return "Automation request did not match anything to rename."
            case .invalidDirectory(let path):
                return "Automation worktree path is not a directory: \(path)"
            case .invalidFile(let path):
                return "Automation file path does not exist: \(path)"
            case .invalidWorkspaceIDFormat(let value):
                return "Workspace ID is not a valid UUID: \(value)"
            case .missingPaneName(let path):
                return "Automation pane is missing a name: \(path)"
            case .workspaceNotFound(let id):
                return "Workspace does not exist: \(id.uuidString)"
            case .missingConversationStore:
                return "Conversation store is not available."
            case .noActiveMainWindow:
                return "No active Soyeht main window is available."
            case .windowNotFound(let id):
                return "Soyeht window does not exist: \(id)"
            }
        }
    }

    private func handleAutomationRequest(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        switch request.type {
        case .createWorktreeWorkspaces:
            return try await handleCreateWorktreeWorkspaces(request)
        case .createWorktreePanes, .createWorktreeTabs:
            return try await handleCreateWorktreePanes(request)
        case .createWorkspacePanes:
            return try await handleCreateWorkspacePanes(request)
        case .sendPaneInput:
            return try handleSendPaneInput(request)
        case .renameWorkspace:
            return try handleRenameWorkspace(request)
        case .renamePanes:
            return try handleRenamePanes(request)
        case .arrangePanes:
            return try handleArrangePanes(request)
        case .emphasizePane:
            return try handleEmphasizePane(request)
        case .resizePaneExact:
            return try handleResizePaneExact(request)
        case .setPaneFontSize:
            return try handleSetPaneFontSize(request)
        case .scrollPane:
            return try handleScrollPane(request)
        case .listWindows:
            return handleListWindows(request)
        case .listWorkspaces:
            return try handleListWorkspaces(request)
        case .listPanes:
            return try handleListPanes(request)
        case .closePane:
            return try handleClosePane(request)
        case .closeWorkspace:
            return try handleCloseWorkspace(request)
        case .movePaneToWorkspace:
            return try handleMovePaneToWorkspace(request)
        case .getPaneStatus:
            return try handleGetPaneStatus(request)
        case .capturePane:
            return try handleCapturePane(request)
        case .capturePaneRange:
            return try handleCapturePaneRange(request)
        case .getActiveContext:
            return try handleGetActiveContext(request)
        case .openEditor:
            return try handleOpenEditor(request)
        case .openExplorer:
            return try handleOpenExplorer(request)
        case .openGit:
            return try handleOpenGit(request)
        case .openDiff:
            return try handleOpenDiff(request)
        }
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

    private func requestedWindowID(_ payload: SoyehtAutomationRequest.Payload) -> String? {
        let raw = payload.targetWindowID ?? payload.windowID
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func automationWindow(id: String) throws -> SoyehtMainWindowController {
        guard let controller = mainWindowControllers.first(where: { $0.windowID == id }) else {
            throw AutomationError.windowNotFound(id)
        }
        return controller
    }

    private func automationTargetWindow(
        payload: SoyehtAutomationRequest.Payload,
        createIfMissing: Bool = true
    ) throws -> SoyehtMainWindowController {
        if let id = requestedWindowID(payload) {
            return try automationWindow(id: id)
        }
        if let target = activeMainWindowController {
            return target
        }
        if createIfMissing {
            return openNewMainWindow()
        }
        throw AutomationError.noActiveMainWindow
    }

    private func automationMoveDestinationWindow(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> SoyehtMainWindowController {
        if let raw = payload.destinationWindowID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return try automationWindow(id: raw)
        }
        return try automationTargetWindow(payload: payload)
    }

    private func automationDisplayName(
        _ value: String?,
        fallback: String,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? value!
            : fallback
        return SoyehtAutomationNameFormatter.displayName(raw, kind: kind, style: style)
    }

    private func optionalAutomationDisplayName(
        _ value: String?,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SoyehtAutomationNameFormatter.displayName(value, kind: kind, style: style)
    }

    private func automationPaneName(
        _ value: String?,
        path: String,
        style: String?,
        allowsAutomaticName: Bool
    ) throws -> String? {
        if let displayName = optionalAutomationDisplayName(value, kind: .pane, style: style) {
            return displayName
        }
        guard allowsAutomaticName else {
            throw AutomationError.missingPaneName(path)
        }
        return nil
    }

    private func handleCreateWorktreeWorkspaces(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let workspaces = payload.requestedWorkspaces
        guard !workspaces.isEmpty else { throw AutomationError.emptyWorktreeWorkspaces }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        var created: [SoyehtAutomationResponse.CreatedWorkspace] = []
        for workspace in workspaces {
            let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(workspace.path)
            }

            let agent = workspace.agent ?? payload.agent ?? "codex"
            let command = workspace.command ?? payload.command ?? agent
            let prompt = workspace.prompt ?? payload.prompt
            let promptDelayMs = workspace.promptDelayMs ?? payload.promptDelayMs
            let workspaceName = automationDisplayName(
                workspace.name,
                fallback: url.lastPathComponent,
                kind: .workspace,
                style: payload.workspaceNameStyle ?? payload.nameStyle
            )
            let paneName = optionalAutomationDisplayName(
                workspace.name,
                kind: .pane,
                style: payload.paneNameStyle ?? payload.nameStyle
            )
            let result = try await target.createLocalAgentWorkspace(
                name: workspaceName,
                paneName: paneName,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: prompt,
                promptDelayMs: promptDelayMs,
                branch: workspace.branch
            )
            created.append(SoyehtAutomationResponse.CreatedWorkspace(
                name: result.workspaceName,
                path: url.path,
                workspaceID: result.workspaceID.uuidString,
                conversationID: result.conversationID.uuidString,
                handle: result.handle,
                windowID: target.windowID
            ))
        }
        return SoyehtAutomationResult(createdWorkspaces: created)
    }

    private func handleCreateWorktreePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw AutomationError.emptyWorktreePanes }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        var specs: [SoyehtMainWindowController.LocalAgentPaneSpec] = []
        for pane in panes {
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(pane.path)
            }

            let agent = pane.agent ?? payload.agent ?? "codex"
            let command = pane.command ?? payload.command ?? agent
            let name = try automationPaneName(
                pane.name,
                path: pane.path,
                style: payload.paneNameStyle ?? payload.nameStyle,
                allowsAutomaticName: payload.allowAutoPaneNames == true
                    && panes.count == 1
                    && agent == "shell"
            )
            specs.append(SoyehtMainWindowController.LocalAgentPaneSpec(
                name: name,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: pane.prompt ?? payload.prompt,
                promptDelayMs: pane.promptDelayMs ?? payload.promptDelayMs
            ))
        }

        let results = try await target.createLocalAgentPanes(specs)
        let created = results.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID
            )
        }
        return SoyehtAutomationResult(createdPanes: created)
    }

    private func handleCreateWorkspacePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw AutomationError.emptyWorkspacePanes }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        let specs = try panes.map { pane in
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(pane.path)
            }

            let agent = pane.agent ?? payload.agent ?? "shell"
            let command = pane.command ?? payload.command ?? agent
            let name = try automationPaneName(
                pane.name,
                path: pane.path,
                style: payload.paneNameStyle ?? payload.nameStyle,
                allowsAutomaticName: false
            )
            return SoyehtMainWindowController.LocalAgentPaneSpec(
                name: name,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: pane.prompt ?? payload.prompt,
                promptDelayMs: pane.promptDelayMs ?? payload.promptDelayMs
            )
        }

        guard let first = specs.first else { throw AutomationError.emptyWorkspacePanes }
        let workspaceName = automationDisplayName(
            payload.workspaceName ?? first.name,
            fallback: first.projectURL.lastPathComponent,
            kind: .workspace,
            style: payload.workspaceNameStyle ?? payload.nameStyle
        )
        let firstResult = try await target.createLocalAgentWorkspace(
            name: workspaceName,
            paneName: first.name,
            projectURL: first.projectURL,
            agentName: first.agentName,
            initialCommand: first.initialCommand,
            prompt: first.prompt,
            promptDelayMs: first.promptDelayMs,
            branch: payload.workspaceBranch
        )
        let additionalResults = try await target.createLocalAgentPanes(
            Array(specs.dropFirst()),
            batchSeedPaneIDs: [firstResult.conversationID]
        )
        let createdWorkspace = SoyehtAutomationResponse.CreatedWorkspace(
            name: firstResult.workspaceName,
            path: first.projectURL.path,
            workspaceID: firstResult.workspaceID.uuidString,
            conversationID: firstResult.conversationID.uuidString,
            handle: firstResult.handle,
            windowID: target.windowID
        )
        let firstPane = SoyehtAutomationResponse.CreatedPane(
            name: first.name ?? ConversationStore.normalize(firstResult.handle),
            path: first.projectURL.path,
            workspaceID: firstResult.workspaceID.uuidString,
            conversationID: firstResult.conversationID.uuidString,
            handle: firstResult.handle,
            windowID: target.windowID
        )
        let additionalPanes = additionalResults.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID
            )
        }
        return SoyehtAutomationResult(
            createdWorkspaces: [createdWorkspace],
            createdPanes: [firstPane] + additionalPanes
        )
    }

    private func handleSendPaneInput(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text, !text.isEmpty else {
            throw AutomationError.emptyPaneInput
        }
        let target = try automationTargetWindow(payload: payload)
        let sent = try target.sendInputToPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            text: text,
            appendNewline: payload.appendNewline ?? true,
            lineEnding: payload.lineEnding,
            sourceTTY: payload.sourceTTY
        )
        return SoyehtAutomationResult(sentPanes: sent.map {
            SoyehtAutomationResponse.SentPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                windowID: target.windowID
            )
        })
    }

    private func handleRenameWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let rawName = payload.newName ?? payload.workspaceName
        guard let rawName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renameWorkspaces(
            workspaceIDStrings: payload.workspaceIDs ?? [],
            workspaceNames: payload.workspaceNames ?? [],
            newName: rawName,
            nameStyle: payload.workspaceNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw AutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedWorkspaces: renamed.map {
            SoyehtAutomationResponse.RenamedWorkspace(
                workspaceID: $0.workspaceID.uuidString,
                oldName: $0.oldName,
                name: $0.name,
                windowID: target.windowID
            )
        })
    }

    private func handleRenamePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawName = payload.newName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renamePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            newName: rawName,
            nameStyle: payload.paneNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw AutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedPanes: renamed.map {
            SoyehtAutomationResponse.RenamedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                oldHandle: $0.oldHandle,
                handle: $0.handle,
                windowID: target.windowID
            )
        })
    }

    private func handleArrangePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let arranged = try target.arrangePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            layoutName: payload.layout,
            ratio: payload.ratio
        )
        return SoyehtAutomationResult(arrangedPaneLayouts: [
            SoyehtAutomationResponse.ArrangedPaneLayout(
                workspaceID: arranged.workspaceID.uuidString,
                layout: arranged.layout,
                conversationIDs: arranged.conversationIDs.map(\.uuidString),
                handles: arranged.handles
            )
        ])
    }

    private func handleEmphasizePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let emphasized = try target.emphasizePane(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode,
            ratio: payload.ratio,
            position: payload.position
        )
        return SoyehtAutomationResult(emphasizedPanes: [
            SoyehtAutomationResponse.EmphasizedPane(
                conversationID: emphasized.conversationID.uuidString,
                workspaceID: emphasized.workspaceID.uuidString,
                handle: emphasized.handle,
                mode: emphasized.mode,
                ratio: emphasized.ratio,
                position: emphasized.position
            )
        ])
    }

    private func handleResizePaneExact(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let resized = try target.resizePaneExact(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            position: payload.position,
            fraction: payload.fraction ?? payload.ratio,
            widthFraction: payload.widthFraction,
            heightFraction: payload.heightFraction
        )
        return SoyehtAutomationResult(resizedPanes: [
            SoyehtAutomationResponse.ResizedPane(
                conversationID: resized.conversationID.uuidString,
                workspaceID: resized.workspaceID.uuidString,
                handle: resized.handle,
                position: resized.position,
                fraction: resized.fraction,
                bounds: automationBounds(resized.bounds),
                pixelBounds: automationBounds(resized.pixelBounds),
                windowID: target.windowID
            )
        ])
    }

    private func handleSetPaneFontSize(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let adjusted = try target.setPaneFontSize(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            fontSize: payload.fontSize,
            delta: payload.delta,
            persist: payload.persist ?? false
        )
        return SoyehtAutomationResult(adjustedPaneFonts: adjusted.map {
            SoyehtAutomationResponse.AdjustedPaneFont(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                fontSize: $0.fontSize,
                persisted: $0.persisted,
                columns: $0.columns,
                rows: $0.rows,
                windowID: target.windowID
            )
        })
    }

    private func handleScrollPane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let scrolled = try target.scrollPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode ?? payload.direction,
            lines: payload.lines,
            position: payload.scrollPosition ?? payload.fraction ?? payload.ratio,
            row: payload.row
        )
        return SoyehtAutomationResult(scrolledPanes: scrolled.map {
            SoyehtAutomationResponse.ScrolledPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                row: $0.row,
                position: $0.position,
                canScroll: $0.canScroll,
                isScrolledToBottom: $0.isScrolledToBottom,
                windowID: target.windowID
            )
        })
    }

    private func automationBounds(
        _ bounds: SoyehtMainWindowController.PaneBoundsResult?
    ) -> SoyehtAutomationResponse.PaneBounds? {
        guard let bounds else { return nil }
        return SoyehtAutomationResponse.PaneBounds(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func handleListWindows(_ request: SoyehtAutomationRequest) -> SoyehtAutomationResult {
        SoyehtAutomationResult(listedWindows: mainWindowControllers.map { listedWindow($0) })
    }

    private func listedWorkspace(
        _ workspace: SoyehtMainWindowController.ListedWorkspaceResult,
        windowID: String
    ) -> SoyehtAutomationResponse.ListedWorkspace {
        SoyehtAutomationResponse.ListedWorkspace(
            workspaceID: workspace.workspaceID.uuidString,
            name: workspace.name,
            paneCount: workspace.paneCount,
            isActive: workspace.isActive,
            activePaneID: workspace.activePaneID?.uuidString,
            windowID: windowID
        )
    }

    private func listedWindow(
        _ controller: SoyehtMainWindowController
    ) -> SoyehtAutomationResponse.ListedWindow {
        let workspaces = controller.listWorkspaces()
        let active = controller.getActiveContext()
        let window = controller.window
        return SoyehtAutomationResponse.ListedWindow(
            windowID: controller.windowID,
            title: (window?.title.isEmpty == false) ? window?.title ?? "Soyeht" : "Soyeht",
            isKey: window?.isKeyWindow ?? false,
            isMain: window?.isMainWindow ?? false,
            isVisible: window?.isVisible ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            activeWorkspaceID: active.workspaceID.uuidString,
            activeWorkspaceName: active.workspaceName,
            workspaceCount: workspaces.count,
            paneCount: workspaces.reduce(0) { $0 + $1.paneCount },
            workspaces: workspaces.map { listedWorkspace($0, windowID: controller.windowID) }
        )
    }

    private func handleListWorkspaces(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        if let requested = requestedWindowID(request.payload) {
            let target = try automationWindow(id: requested)
            return SoyehtAutomationResult(
                listedWorkspaces: target.listWorkspaces().map { listedWorkspace($0, windowID: target.windowID) },
                activeContext: makeActiveContext(target)
            )
        }

        let controllers = mainWindowControllers
        let listed: [SoyehtAutomationResponse.ListedWorkspace]
        if controllers.isEmpty {
            listed = workspaceStore.orderedWorkspaces.map {
                SoyehtAutomationResponse.ListedWorkspace(
                    workspaceID: $0.id.uuidString,
                    name: $0.name,
                    paneCount: $0.layout.leafCount,
                    isActive: false,
                    activePaneID: $0.activePaneID?.uuidString,
                    windowID: nil
                )
            }
        } else {
            listed = controllers.flatMap { controller in
                controller.listWorkspaces().map { listedWorkspace($0, windowID: controller.windowID) }
            }
        }

        return SoyehtAutomationResult(
            listedWorkspaces: listed,
            activeContext: activeMainWindowController.map { makeActiveContext($0) }
        )
    }

    private func handleListPanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let wsIDStr = request.payload.workspaceIDs?.first
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let panes: [SoyehtMainWindowController.ListedPaneResult]
        if let target {
            panes = try target.listPanes(workspaceIDString: wsIDStr).panes
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            panes = []
        } else {
            panes = try listPanesWithoutActiveWindow(workspaceIDString: wsIDStr)
        }
        let listed = panes.map {
            SoyehtAutomationResponse.ListedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                path: $0.path,
                declaredAgent: $0.declaredAgent,
                isActive: $0.isActive,
                isActiveWorkspace: $0.isActiveWorkspace,
                windowID: $0.windowID ?? target?.windowID
            )
        }
        return SoyehtAutomationResult(
            listedPanes: listed,
            activeContext: target.map { makeActiveContext($0) }
        )
    }

    private func listPanesWithoutActiveWindow(
        workspaceIDString: String?
    ) throws -> [SoyehtMainWindowController.ListedPaneResult] {
        let windowByWorkspace = Dictionary(
            mainWindowControllers.flatMap { controller in
                workspaceStore.workspaceOrder(in: controller.windowID).map { ($0, controller.windowID) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let visibleWorkspaceIDs = Set(windowByWorkspace.keys)
        let all: [Conversation]
        if let idStr = workspaceIDString {
            guard let wsID = UUID(uuidString: idStr) else {
                throw AutomationError.invalidWorkspaceIDFormat(idStr)
            }
            guard workspaceStore.workspace(wsID) != nil else {
                throw AutomationError.workspaceNotFound(wsID)
            }
            guard visibleWorkspaceIDs.contains(wsID) else {
                return []
            }
            all = conversationStore.conversations(in: wsID)
        } else {
            all = conversationStore.all.filter { visibleWorkspaceIDs.contains($0.workspaceID) }
        }
        return all.map {
            SoyehtMainWindowController.ListedPaneResult(
                conversationID: $0.id,
                workspaceID: $0.workspaceID,
                handle: $0.handle,
                path: $0.content.primaryPath ?? $0.workingDirectoryPath ?? "",
                declaredAgent: $0.content.isTerminal ? $0.agent.rawValue : $0.content.displayKind,
                isActive: false,
                isActiveWorkspace: false,
                windowID: windowByWorkspace[$0.workspaceID]
            )
        }
    }

    private func handleGetActiveContext(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let target = try automationTargetWindow(payload: request.payload, createIfMissing: false)
        return SoyehtAutomationResult(activeContext: makeActiveContext(target))
    }

    private func handleOpenEditor(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let fileURL = try payload.file.map { try existingFileURL($0) }
        let rootURL = try payload.root.map { try existingDirectoryURL($0) }
            ?? fileURL?.deletingLastPathComponent()
            ?? payload.path.map { try existingDirectoryURL($0) }
        let opened = try target.openEditorPane(
            fileURL: fileURL,
            rootURL: rootURL,
            line: payload.line,
            column: payload.column,
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenExplorer(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.root ?? payload.path ?? payload.file else {
            throw AutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openExplorerPane(rootURL: try existingDirectoryURL(rawPath))
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenGit(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.repo ?? payload.repoPath ?? payload.path ?? payload.root else {
            throw AutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let repoURL = try existingDirectoryURL(rawPath)
        let opened = try target.openGitPane(
            repoURL: repoURL,
            selectedFilePath: payload.selectedFile,
            branch: payload.branch,
            compareBase: payload.compareBase,
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenDiff(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let selected = payload.selectedFile ?? payload.file
        let explicitRepo = payload.repo ?? payload.repoPath ?? payload.root ?? payload.path
        let repoCandidate: URL
        if let explicitRepo {
            repoCandidate = try existingDirectoryURL(explicitRepo)
        } else if let selected {
            repoCandidate = try existingFileURL(selected).deletingLastPathComponent()
        } else {
            throw AutomationError.invalidDirectory("")
        }
        let repoRoot = try GitRepositoryService.resolveRepoRoot(from: repoCandidate)
        let selectedPath = selected.map { relativeGitPath($0, repoRoot: repoRoot) }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openGitPane(
            repoURL: repoRoot,
            selectedFilePath: selectedPath,
            branch: payload.branch,
            compareBase: payload.compareBase,
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func openedSpecialPane(
        _ result: SoyehtMainWindowController.OpenedSpecialPaneResult,
        windowID: String
    ) -> SoyehtAutomationResponse.OpenedSpecialPane {
        SoyehtAutomationResponse.OpenedSpecialPane(
            kind: result.kind.rawValue,
            path: result.path,
            workspaceID: result.workspaceID.uuidString,
            conversationID: result.conversationID.uuidString,
            handle: result.handle,
            reused: result.reused,
            windowID: windowID
        )
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func existingFileURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AutomationError.invalidFile(path)
        }
        return url
    }

    private func existingDirectoryURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationError.invalidDirectory(path)
        }
        return url
    }

    private func relativeGitPath(_ path: String, repoRoot: URL) -> String {
        let absolute = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
            .standardizedFileURL
            .path
        let root = repoRoot.standardizedFileURL.path
        if absolute == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if absolute.hasPrefix(prefix) {
            return String(absolute.dropFirst(prefix.count))
        }
        return path
    }

    private func makeActiveContext(
        _ target: SoyehtMainWindowController
    ) -> SoyehtAutomationResponse.ActiveContext {
        let ctx = target.getActiveContext()
        return SoyehtAutomationResponse.ActiveContext(
            windowID: target.windowID,
            workspaceID: ctx.workspaceID.uuidString,
            workspaceName: ctx.workspaceName,
            paneID: ctx.paneID?.uuidString,
            paneHandle: ctx.paneHandle
        )
    }

    private func handleClosePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let closed = try target.closePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? []
        )
        return SoyehtAutomationResult(closedPanes: closed.map {
            SoyehtAutomationResponse.ClosedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle
            )
        })
    }

    private func handleCloseWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let closed = try target.closeWorkspaceSilently(
            workspaceIDStrings: payload.workspaceIDs ?? [],
            workspaceNames: payload.workspaceNames ?? []
        )
        return SoyehtAutomationResult(closedWorkspaces: closed.map {
            SoyehtAutomationResponse.ClosedWorkspace(
                workspaceID: $0.workspaceID.uuidString,
                name: $0.name
            )
        })
    }

    private func handleMovePaneToWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try automationTargetWindow(payload: payload)
        let destination = try automationMoveDestinationWindow(payload: payload)
        let moved = try source.movePanesToWorkspace(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            destinationWorkspaceIDString: payload.destinationWorkspaceID,
            destinationWorkspaceName: payload.destinationWorkspaceName,
            destinationWindowID: destination.windowID,
            destinationController: destination
        )
        if destination.windowID != source.windowID,
           let destinationWorkspaceID = moved.last?.destinationWorkspaceID {
            destination.activate(workspaceID: destinationWorkspaceID)
        }
        mainWindowControllers.forEach { $0.ensureActiveWorkspaceIsValid() }
        return SoyehtAutomationResult(movedPanes: moved.map {
            SoyehtAutomationResponse.MovedPane(
                conversationID: $0.conversationID.uuidString,
                sourceWorkspaceID: $0.sourceWorkspaceID.uuidString,
                destinationWorkspaceID: $0.destinationWorkspaceID.uuidString,
                handle: $0.handle,
                sourceWindowID: source.windowID,
                destinationWindowID: destination.windowID
            )
        })
    }

    private func handleGetPaneStatus(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let conversationIDStrings = payload.conversationIDs ?? []
        let handles = payload.handles ?? []
        let statuses: [SoyehtMainWindowController.PaneStatusResult]
        if let target = try? automationTargetWindow(payload: payload, createIfMissing: false) {
            statuses = try target.getPaneStatus(
                conversationIDStrings: conversationIDStrings,
                handles: handles
            )
        } else if let requested = requestedWindowID(payload) {
            _ = try automationWindow(id: requested)
            statuses = []
        } else {
            statuses = try SoyehtMainWindowController.paneStatuses(
                conversationIDStrings: conversationIDStrings,
                handles: handles,
                convStore: conversationStore
            )
        }
        return SoyehtAutomationResult(paneStatuses: statuses.map {
            SoyehtAutomationResponse.PaneStatus(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                agent: $0.agent,
                status: $0.status,
                exitCode: $0.exitCode
            )
        })
    }

    private func handleCapturePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let captured = try target.capturePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.captureMode,
            maxLines: payload.maxLines
        )
        return SoyehtAutomationResult(capturedPanes: captured.map {
            SoyehtAutomationResponse.CapturedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                text: $0.text,
                lineCount: $0.lineCount,
                omittedLineCount: $0.omittedLineCount,
                truncated: $0.truncated,
                windowID: target.windowID
            )
        })
    }

    private func handleCapturePaneRange(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let captured = try target.capturePaneRange(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.captureMode,
            startLine: payload.startLine,
            lineCount: payload.lineCount,
            fromEnd: payload.fromEnd ?? false
        )
        return SoyehtAutomationResult(capturedPanes: captured.map {
            SoyehtAutomationResponse.CapturedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                text: $0.text,
                lineCount: $0.lineCount,
                omittedLineCount: $0.omittedLineCount,
                truncated: $0.truncated,
                rangeStartLine: $0.rangeStartLine,
                rangeLineCount: $0.rangeLineCount,
                windowID: target.windowID
            )
        })
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
        PairedDevicesWindowController.shared.showWindow(nil)
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
        let target = frontmostMainWindowController
        target?.moveFocusedPaneToWorkspaceByTag(sender)
    }

    func performAppCommand(_ commandID: AppCommandID, sender: Any?) {
        switch commandID {
        case .newWindow:
            newWindow(sender ?? self)
        case .newConversation:
            newConversation(sender)
        case .showCommandPalette:
            showCommandPalette(sender)
        case .checkForUpdates:
            checkForUpdates(sender)
        case .showPreferences:
            showPreferences(sender ?? self)
        case .showAgentVisualPermissions:
            showAgentVisualPermissions(sender)
        case .showPairedDevices:
            showPairedDevices(sender ?? self)
        case .showConnectedServers:
            showConnectedServers(sender)
        case .uninstallSoyeht:
            uninstallSoyeht(sender)
        case .showClawStore:
            showClawStore(sender)
        case .showConversationsSidebar:
            showConversationsSidebar(sender)
        case .undoWindowAction:
            undoWindowAction(sender)
        case .redoWindowAction:
            redoWindowAction(sender)
        case .splitPaneVertical:
            splitPaneVertical(sender)
        case .splitPaneHorizontal:
            splitPaneHorizontal(sender)
        case .closeFocusedPane:
            closeFocusedPane(sender)
        case .focusPaneLeft:
            focusPaneLeft(sender)
        case .focusPaneRight:
            focusPaneRight(sender)
        case .focusPaneUp:
            focusPaneUp(sender)
        case .focusPaneDown:
            focusPaneDown(sender)
        case .toggleZoomFocusedPane:
            toggleZoomFocusedPane(sender)
        case .exitZoom:
            exitZoom(sender)
        case .swapPaneLeft:
            swapPaneLeft(sender)
        case .swapPaneRight:
            swapPaneRight(sender)
        case .swapPaneUp:
            swapPaneUp(sender)
        case .swapPaneDown:
            swapPaneDown(sender)
        case .rotateFocusedSplit:
            rotateFocusedSplit(sender)
        case .selectWorkspace:
            selectWorkspaceByTag(sender)
        case .moveFocusedPaneToWorkspace:
            moveFocusedPaneToWorkspaceByTag(sender)
        case .moveActiveWorkspaceLeft:
            moveActiveWorkspaceLeft(sender)
        case .moveActiveWorkspaceRight:
            moveActiveWorkspaceRight(sender)
        }
    }

    @IBAction func selectWorkspaceByTag(_ sender: Any?) {
        let target = frontmostMainWindowController
        target?.selectWorkspaceByTag(sender)
    }

    @IBAction func moveActiveWorkspaceLeft(_ sender: Any?) {
        frontmostMainWindowController?.moveActiveWorkspaceLeft(sender)
    }

    @IBAction func moveActiveWorkspaceRight(_ sender: Any?) {
        frontmostMainWindowController?.moveActiveWorkspaceRight(sender)
    }

    @IBAction func splitPaneVertical(_ sender: Any?) { withActivePaneGrid { $0.splitPaneVertical(sender) } }
    @IBAction func splitPaneHorizontal(_ sender: Any?) { withActivePaneGrid { $0.splitPaneHorizontal(sender) } }
    @IBAction func closeFocusedPane(_ sender: Any?) { withActivePaneGrid { $0.closeFocusedPane(sender) } }
    @IBAction func undoWindowAction(_ sender: Any?) {
        let controller = activeMainWindowController
        controller?.window?.undoManager?.undo()
        controller?.refreshWorkspaceChromeFromStore()
    }
    @IBAction func redoWindowAction(_ sender: Any?) {
        let controller = activeMainWindowController
        controller?.window?.undoManager?.redo()
        controller?.refreshWorkspaceChromeFromStore()
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

    @IBAction func newWindow(_ sender: Any) {
        openNewMainWindow(createFreshWorkspace: true)
    }

    @IBAction func closeActiveWorkspace(_ sender: Any?) {
        guard let controller = frontmostMainWindowController else {
            NSSound.beep()
            return
        }
        controller.closeActiveWorkspace(sender)
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
        guard let controller = frontmostMainWindowController else {
            NSSound.beep()
            return
        }
        controller.newConversation(sender)
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
        if let target = frontmostMainWindowController {
            target.openClawDrawerOverlay()
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard SessionStore.shared.currentContext() != nil else {
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
        guard let context = SessionStore.shared.currentContext() else {
            openWelcomeWindow()
            return
        }
        showStandaloneClawStore(context: context)
    }

    private func showStandaloneClawStore(context: ServerContext) {
        if let existing = clawStoreWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ClawStoreWindowController(context: context)
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

    private func showClawStoreComingSoonAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "clawStore.comingSoon.title", comment: "Alert title shown while Claw Store is disabled for launch.")
        alert.addButton(withTitle: String(localized: "common.button.ok"))
        if let window = NSApp.keyWindow ?? frontmostMainWindowController?.window {
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
        let parent = frontmostMainWindowController?.window
        palette.present(from: parent)
    }

    /// Resolve a palette selection: switch to the key main window (or any
    /// main window), activate the workspace, and — if a pane was selected —
    /// focus it. Mirrors the sidebar's `focusPane(workspaceID:conversationID:)`
    /// path so the behaviour is identical whichever entry point the user
    /// uses.
    private func jump(to item: CommandPaletteItem) {
        let target = frontmostMainWindowController ?? activeMainWindowController
        guard let target else { return }
        if let paneID = item.paneID {
            target.focusPane(workspaceID: item.workspaceID, conversationID: paneID)
        } else {
            target.activate(workspaceID: item.workspaceID)
        }
    }

    var frontmostMainWindowController: SoyehtMainWindowController? {
        Self.frontmostMainWindowController()
    }

    var activeMainWindowController: SoyehtMainWindowController? {
        frontmostMainWindowController ?? mainWindowControllers.first
    }

    func retainMenuWindowController(_ windowController: NSWindowController) {
        retain(windowController)
    }

    fileprivate static func frontmostMainWindowController() -> SoyehtMainWindowController? {
        mainWindowController(owning: NSApp.keyWindow)
            ?? mainWindowController(owning: NSApp.mainWindow)
            ?? NSApp.orderedWindows.lazy.compactMap { mainWindowController(owning: $0) }.first
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

    private func withActivePaneGrid(_ body: (PaneGridController) -> Void) {
        guard let grid = frontmostMainWindowController?.activeGridController else {
            NSSound.beep()
            return
        }
        body(grid)
    }

    /// Menu item / `⌘⇧C` target. Toggles the floating sidebar overlay on
    /// the key main window (or first main window if none is key). The
    /// overlay lives inside the main window via
    /// `WindowChromeViewController`, NOT as a separate NSWindow — matches
    /// SXnc2 V2 `floatSidebar`.
    @IBAction func showConversationsSidebar(_ sender: Any?) {
        let target = frontmostMainWindowController
        target?.toggleSidebarOverlay()
    }

    @IBAction func logout(_ sender: Any) {
        let store = SessionStore.shared
        guard !store.pairedServers.isEmpty else { return }

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
            panel.title = String(localized: "auth.login.title", comment: "Title above the login form.")
            panel.contentViewController = loginVC
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
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
        AppDelegate.frontmostMainWindowController()
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
#endif
