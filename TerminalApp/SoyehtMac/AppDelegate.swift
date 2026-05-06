//
//  AppDelegate.swift
//  Soyeht
//

import Cocoa
import SoyehtCore

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
    private var automationService: SoyehtAutomationService?
    private var isTerminating = false

    var isTerminatingForWindowRestoration: Bool { isTerminating }

    private enum SoundMenuTag {
        static let topLevel = -701
        static let dictationLanguage = -702
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kick off the login-shell PATH probe immediately so it's ready by
        // the time the user opens the first bash pane. Async; never blocks
        // launch.
        LoginShellEnvironmentResolver.shared.warmup()
        normalizeInheritedWorkingDirectory()
        WorkspaceBookmarkStore.shared.forgetPersistedDocumentWorkspacePaths()
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
        WorkspaceSwitchBenchmark.scheduleIfRequestedByEnvironment()
        #endif
        SoyehtUpdater.shared.startIfConfigured()
        installApplicationMenuEnhancements()
        installUpdateMenu()
        installShellMenuEnhancements()
        installSoundMenu()
        installPairingMenu()
        installClawStoreMenu()
        installConnectedServersMenu()
        installCommandPaletteMenu()
        installPaneMenuEnhancements()
        installEditMenuEnhancements()
        installWorkspaceMenuEnhancements()
        // Boot the app-level WebSocket server so paired iPhones can reach us
        // as soon as the app launches, without a QR scan. Presence + pane
        // attach listeners; ports are cached in UserDefaults.
        PairingPresenceServer.shared.start()
        automationService = SoyehtAutomationService { [weak self] request in
            guard let self else { return SoyehtAutomationResult() }
            return try await self.handleAutomationRequest(request)
        }
        automationService?.start()
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
            restoreMainWindowsOrOpenDefault()
        }
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
        case .householdPairDevice:
            return
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
        initialWorkspaceID: Workspace.ID? = nil,
        createFreshWorkspace: Bool = false
    ) -> SoyehtMainWindowController {
        let windowID = initialWindowID ?? UUID().uuidString
        let workspaceID: Workspace.ID?
        if let initialWorkspaceID {
            workspaceID = initialWorkspaceID
        } else if createFreshWorkspace {
            workspaceID = workspaceStore.addAdhocWorkspaceForNewWindow(windowID: windowID).id
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
        case invalidWorkspaceIDFormat(String)
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
            case .invalidWorkspaceIDFormat(let value):
                return "Workspace ID is not a valid UUID: \(value)"
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
        case .getActiveContext:
            return try handleGetActiveContext(request)
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
            let workspaceName = SoyehtAutomationNameFormatter.displayName(
                workspace.name,
                kind: .workspace,
                style: payload.workspaceNameStyle ?? payload.nameStyle
            )
            let paneName = SoyehtAutomationNameFormatter.displayName(
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
            let name = SoyehtAutomationNameFormatter.displayName(
                pane.name,
                kind: .pane,
                style: payload.paneNameStyle ?? payload.nameStyle
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
            let name = SoyehtAutomationNameFormatter.displayName(
                pane.name,
                kind: .pane,
                style: payload.paneNameStyle ?? payload.nameStyle
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
        let rawWorkspaceName = payload.workspaceName ?? first.name
        let workspaceName = SoyehtAutomationNameFormatter.displayName(
            rawWorkspaceName,
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
            name: first.name,
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
            lineEnding: payload.lineEnding
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
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let listed: [SoyehtAutomationResponse.ListedWorkspace]
        if let target {
            listed = target.listWorkspaces().map { listedWorkspace($0, windowID: target.windowID) }
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            listed = []
        } else {
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
        }
        return SoyehtAutomationResult(
            listedWorkspaces: listed,
            activeContext: target.map { makeActiveContext($0) }
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
                agent: $0.agent,
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
                path: $0.workingDirectoryPath ?? "",
                agent: $0.agent.rawValue,
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
            destinationWindowID: destination.windowID
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

    // MARK: - Debug Menu (Phase 2)

    #if DEBUG
    private func installDebugMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Reuse an existing top-level "Debug" menu if SwiftTerm's storyboard
        // (or any other origin) already installed one — appending into it is
        // safer than creating a second menu with the same title.
        let debugMenu: NSMenu
        let isFreshMenu: Bool
        if let existing = mainMenu.items.first(where: { $0.title == "Debug" })?.submenu {
            debugMenu = existing
            isFreshMenu = false
        } else {
            debugMenu = NSMenu(title: "Debug")
            isFreshMenu = true
        }

        // Skip if our items already landed (re-entrancy).
        let benchTitle = "Benchmark Workspace Switching (50 cycles)"
        if debugMenu.items.contains(where: { $0.title == benchTitle }) { return }

        if !isFreshMenu { debugMenu.addItem(NSMenuItem.separator()) }

        let openPaneItem = NSMenuItem(title: "Open Pane Window", action: #selector(openPaneDebugWindow(_:)), keyEquivalent: "")
        openPaneItem.target = self
        debugMenu.addItem(openPaneItem)

        let sidebarItem = NSMenuItem(
            title: "Open Conversations Sidebar",
            action: #selector(showConversationsSidebar(_:)),
            keyEquivalent: AppCommandRegistry.command(.showConversationsSidebar)?.shortcut?.menuKeyEquivalent ?? ""
        )
        sidebarItem.keyEquivalentModifierMask = AppCommandRegistry.command(.showConversationsSidebar)?.shortcut?.modifiers.eventModifierFlags ?? []
        sidebarItem.target = self
        debugMenu.addItem(sidebarItem)

        debugMenu.addItem(NSMenuItem.separator())

        let benchItem = NSMenuItem(
            title: benchTitle,
            action: #selector(runWorkspaceSwitchBenchmark(_:)),
            keyEquivalent: ""
        )
        benchItem.target = self
        debugMenu.addItem(benchItem)

        if isFreshMenu {
            let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            debugItem.submenu = debugMenu
            // Insert before the Help menu (last item).
            let insertIndex = max(0, mainMenu.items.count - 1)
            mainMenu.insertItem(debugItem, at: insertIndex)
        }
    }

    @MainActor @objc private func runWorkspaceSwitchBenchmark(_ sender: Any?) {
        WorkspaceSwitchBenchmark.run(cycles: 50) { result in
            WorkspaceSwitchBenchmark.presentResult(result, presentingWindow: NSApp.keyWindow)
        }
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

    @IBAction func showConnectedServers(_ sender: Any?) {
        ConnectedServersWindowController.shared.showWindow(nil)
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

    private func installApplicationMenuEnhancements() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenu = mainMenu.items.first?.submenu,
              let command = AppCommandRegistry.command(.showPreferences),
              let item = findMenuItem(in: appMenu, titled: command.title) else { return }
        configureMenuItem(item, with: command)
    }

    private func installUpdateMenu() {
        guard let command = AppCommandRegistry.command(.checkForUpdates),
              let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let existing = findMenuItem(for: command, in: appMenu) {
            configureMenuItem(existing, with: command)
            return
        }

        let item = makeMenuItem(for: command)
        let aboutIndex = appMenu.items.firstIndex {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        }
        let index = aboutIndex.map { $0 + 1 } ?? min(1, appMenu.items.count)
        appMenu.insertItem(item, at: index)
    }

    private func installShellMenuEnhancements() {
        guard let shellMenu = NSApp.mainMenu?
            .items
            .first(where: { $0.title == "Shell" })?
            .submenu
        else { return }

        for commandID in [AppCommandID.newWindow, .newConversation] {
            guard let command = AppCommandRegistry.command(commandID),
                  let item = findMenuItem(in: shellMenu, titled: command.title) else { continue }
            configureMenuItem(item, with: command)
        }
    }

    private func installSoundMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let item: NSMenuItem
        let menu: NSMenu
        if let existing = mainMenu.items.first(where: { $0.tag == SoundMenuTag.topLevel || $0.title == "Sound" }) {
            item = existing
            menu = existing.submenu ?? NSMenu(title: "Sound")
        } else {
            item = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
            menu = NSMenu(title: "Sound")
            let shellIndex = mainMenu.items.firstIndex { $0.title == "Shell" }
            mainMenu.insertItem(item, at: shellIndex.map { $0 + 1 } ?? max(0, mainMenu.items.count - 1))
        }

        item.title = "Sound"
        item.tag = SoundMenuTag.topLevel
        item.submenu = menu
        menu.title = "Sound"
        menu.delegate = self
        refreshSoundMenu(menu)
    }

    private func refreshSoundMenu(_ soundMenu: NSMenu) {
        soundMenu.removeAllItems()

        let languageTitle = String(
            localized: "voice.mac.menu.dictationLanguage",
            defaultValue: "Dictation Language"
        )
        let header = NSMenuItem(title: languageTitle, action: nil, keyEquivalent: "")
        header.tag = SoundMenuTag.dictationLanguage
        header.submenu = NSMenu(title: languageTitle)
        soundMenu.addItem(header)

        guard let languageMenu = header.submenu else { return }
        let selected = MacVoiceInputPreferences.selectedLanguage
        for language in MacVoiceInputLanguage.allCases {
            let item = NSMenuItem(
                title: language.menuTitle,
                action: #selector(selectVoiceInputLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == selected ? .on : .off
            languageMenu.addItem(item)
        }
    }

    /// Adds a "Dispositivos pareados…" item under the app menu, right after
    /// Preferences (Cmd-,). Cmd-Shift-D opens the window.
    private func installPairingMenu() {
        guard let command = AppCommandRegistry.command(.showPairedDevices) else { return }
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenu.items.contains(where: { $0.action == command.action.selector }) { return }

        let item = makeMenuItem(for: command)

        // Insert right after "Preferences…" if present, else near the top.
        let insertAfter = appMenu.items.firstIndex(where: {
            $0.title.lowercased().contains("preferences") || $0.title.lowercased().contains("settings")
        })
        let index = insertAfter.map { $0 + 1 } ?? min(2, appMenu.items.count)
        appMenu.insertItem(item, at: index)
    }

    /// Adds a theyOS server list under the app menu. This is distinct from
    /// Paired Devices, which manages iPhones connected to this Mac.
    private func installConnectedServersMenu() {
        guard let command = AppCommandRegistry.command(.showConnectedServers) else { return }
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenu.items.contains(where: { $0.action == command.action.selector }) { return }

        let item = makeMenuItem(for: command)
        let insertAfter = appMenu.items.firstIndex(where: {
            $0.title.lowercased().contains("preferences") || $0.title.lowercased().contains("settings")
        })
        let index = insertAfter.map { $0 + 1 } ?? min(2, appMenu.items.count)
        appMenu.insertItem(item, at: index)
    }

    @IBAction func newWindow(_ sender: Any) {
        openNewMainWindow(createFreshWorkspace: true)
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        SoyehtUpdater.shared.checkForUpdates(sender)
    }

    @IBAction func newConversation(_ sender: Any?) {
        guard let controller = activeMainWindowController else {
            NSSound.beep()
            return
        }
        controller.newConversation(sender)
    }

    @IBAction func selectVoiceInputLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let language = MacVoiceInputLanguage(rawValue: rawValue) else { return }

        MacVoiceInputPreferences.selectedLanguage = language
        if let soundMenu = NSApp.mainMenu?.items.first(where: { $0.tag == SoundMenuTag.topLevel })?.submenu {
            refreshSoundMenu(soundMenu)
        }
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
        if let target = activeMainWindowController {
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

    /// Adds "Claw Store…" to the app menu with ⌘⌥S. ⌘⇧S is already
    /// taken by "Export Selected Text As…" in the Shell menu.
    private func installClawStoreMenu() {
        guard let command = AppCommandRegistry.command(.showClawStore) else { return }
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenu.items.contains(where: { $0.action == command.action.selector }) { return }
        let item = makeMenuItem(for: command)
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
        guard let command = AppCommandRegistry.command(.showCommandPalette) else { return }
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
        upsertMenuItem(for: command, in: targetMenu)
    }

    /// Normalize conflicting storyboard shortcuts and install the phase-2
    /// pane commands that still lack menu wiring (`zoom`, `swap`, `rotate`).
    /// We do this programmatically so the runtime menu always matches the
    /// product contract, even if the storyboard lags behind.
    private func installPaneMenuEnhancements() {
        guard let mainMenu = NSApp.mainMenu,
              let paneMenu = mainMenu.items.first(where: { $0.title == "Pane" })?.submenu
        else { return }

        [
            AppCommandID.splitPaneVertical,
            .splitPaneHorizontal,
            .focusPaneLeft,
            .focusPaneRight,
            .focusPaneUp,
            .focusPaneDown,
            .closeFocusedPane,
            .toggleZoomFocusedPane,
            .exitZoom,
            .swapPaneLeft,
            .swapPaneRight,
            .swapPaneUp,
            .swapPaneDown,
            .rotateFocusedSplit,
        ].forEach { commandID in
            guard let command = AppCommandRegistry.command(commandID) else { return }
            upsertMenuItem(for: command, in: paneMenu)
        }
        installMoveFocusedPaneMenu(in: paneMenu)
    }

    /// Route Edit > Undo/Redo directly to the active main window's
    /// workspace-level UndoManager. Relying on the responder chain left the
    /// menu item titles updating correctly while the items stayed disabled
    /// whenever focus was inside a terminal or custom pane view.
    private func installEditMenuEnhancements() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for commandID in [AppCommandID.undoWindowAction, .redoWindowAction] {
            guard let command = AppCommandRegistry.command(commandID),
                  let item = findMenuItem(in: mainMenu, titled: command.title) else { continue }
            configureMenuItem(item, with: command)
        }
    }

    private func installMoveFocusedPaneMenu(in paneMenu: NSMenu) {
        let title = String(localized: "paneMenu.moveTo.header", comment: "Pane submenu header — 'Move Focused Pane To…'. Reveals workspace targets.")
        let header: NSMenuItem
        // Identity via tag, not title — title changes with the UI language,
        // so title-match would double-insert on language switch.
        if let existing = paneMenu.items.first(where: { $0.tag == AppCommandMenuTag.paneMoveToWorkspaceHeader }) {
            header = existing
            existing.title = title
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.tag = AppCommandMenuTag.paneMoveToWorkspaceHeader
            header.submenu = NSMenu(title: title)
            paneMenu.addItem(.separator())
            paneMenu.addItem(header)
        }
        guard let submenu = header.submenu else { return }
        for tag in AppCommandRegistry.workspaceTags {
            guard let command = AppCommandRegistry.command(.moveFocusedPaneToWorkspace(tag)) else { continue }
            upsertMenuItem(for: command, in: submenu)
        }
    }

    private func installWorkspaceMenuEnhancements() {
        // Storyboard-baked title; storyboard is not catalog-localized so this
        // stays stable across UI languages. `// i18n-exempt: storyboard title`.
        guard let workspaceMenu = NSApp.mainMenu?
            .items
            .first(where: { $0.title == "Workspaces" })?
            .submenu
        else { return }

        workspaceMenu.delegate = self
        if let command = AppCommandRegistry.command(.showConversationsSidebar),
           let item = findMenuItem(in: workspaceMenu, titled: command.title) {
            configureMenuItem(item, with: command)
        }
        for tag in AppCommandRegistry.workspaceTags {
            guard let command = AppCommandRegistry.command(.selectWorkspace(tag)) else { continue }
            // Storyboard pre-assigns tag=1…9 on these items; match by tag so
            // lookup survives language switches (title is localized at runtime).
            guard let item = workspaceMenu.items.first(where: { $0.tag == tag }) else { continue }
            configureMenuItem(item, with: command)
        }
        if workspaceMenu.items.last?.isSeparatorItem != true {
            workspaceMenu.addItem(.separator())
        }
        for commandID in [
            AppCommandID.closeSelectedWorkspaces,
            .moveActiveWorkspaceLeft,
            .moveActiveWorkspaceRight,
        ] {
            guard let command = AppCommandRegistry.command(commandID) else { continue }
            upsertMenuItem(for: command, in: workspaceMenu)
        }
        installToggleWorkspaceSelectionMenu(in: workspaceMenu)

        let title = String(localized: "workspaceMenu.groupActive.header", comment: "Workspace submenu header — reveals 'assign active workspace to group' options.")
        let header: NSMenuItem
        // Identity via tag, not title — title is language-dependent.
        if let existing = workspaceMenu.items.first(where: { $0.tag == AppCommandMenuTag.workspaceGroupActiveHeader }) {
            header = existing
            existing.title = title
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.tag = AppCommandMenuTag.workspaceGroupActiveHeader
            header.submenu = NSMenu(title: title)
            workspaceMenu.addItem(header)
        }
        refreshWorkspaceMenuEnhancements(in: workspaceMenu)
    }

    private func refreshWorkspaceMenuEnhancements(in workspaceMenu: NSMenu) {
        if let closeCommand = AppCommandRegistry.command(.closeSelectedWorkspaces),
           let closeSelected = workspaceMenu.items.first(where: { $0.action == closeCommand.action.selector }) {
            let count = activeMainWindowController?.selectedWorkspaceIDsInVisualOrder.count ?? 0
            closeSelected.title = count > 1
                ? String(
                    localized: "workspaceMenu.closeSelected.count",
                    defaultValue: "Close \(count) Workspaces",
                    comment: "Dynamic menu title when multiple workspaces are selected. %lld = count."
                )
                : String(localized: "workspaceMenu.closeSelected", comment: "Workspace menu item — bulk-close currently multi-selected workspaces.")
            closeSelected.isEnabled = count > 1
            closeSelected.target = self
        }

        guard let header = workspaceMenu.items.first(where: { $0.tag == AppCommandMenuTag.workspaceGroupActiveHeader }),
              let submenu = header.submenu else { return }

        let currentGroupID = activeMainWindowController?.activeWorkspaceGroupID
        let hasActiveWorkspace = activeMainWindowController != nil
        submenu.removeAllItems()

        let none = NSMenuItem(title: String(localized: "workspaceMenu.group.none", comment: "Group submenu item that unassigns the active workspace from any group."), action: #selector(assignActiveWorkspaceToGroup(_:)), keyEquivalent: "")
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
        let newGroup = NSMenuItem(title: String(localized: "workspaceMenu.group.newGroup", comment: "Group submenu item that opens the new-group prompt."), action: #selector(newGroupForActiveWorkspace(_:)), keyEquivalent: "")
        newGroup.target = self
        newGroup.isEnabled = hasActiveWorkspace
        submenu.addItem(newGroup)
    }

    @discardableResult
    private func upsertMenuItem(for command: AppCommand, in menu: NSMenu) -> NSMenuItem {
        if let existing = findMenuItem(for: command, in: menu) {
            configureMenuItem(existing, with: command)
            return existing
        }
        let item = makeMenuItem(for: command)
        menu.addItem(item)
        return item
    }

    private func findMenuItem(for command: AppCommand, in menu: NSMenu) -> NSMenuItem? {
        if let tag = command.tag {
            return menu.items.first {
                $0.tag == tag || ($0.title == command.title && $0.action == command.action.selector)
            }
        }
        return menu.items.first {
            $0.action == command.action.selector || $0.title == command.title
        }
    }

    private func makeMenuItem(for command: AppCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: command.action.selector,
            keyEquivalent: command.shortcut?.menuKeyEquivalent ?? ""
        )
        configureMenuItem(item, with: command)
        return item
    }

    private func configureMenuItem(_ item: NSMenuItem, with command: AppCommand) {
        item.title = command.title
        item.action = command.action.selector
        item.target = self
        if let tag = command.tag {
            item.tag = tag
        }
        if let shortcut = command.shortcut {
            item.keyEquivalent = shortcut.menuKeyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers.eventModifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func installToggleWorkspaceSelectionMenu(in workspaceMenu: NSMenu) {
        let title = String(localized: "workspaceMenu.toggleSelection.header", comment: "Workspace submenu header — reveals 'toggle multi-select for workspace N' options.")
        let header: NSMenuItem
        // Identity via tag, not title — title is language-dependent.
        if let existing = workspaceMenu.items.first(where: { $0.tag == AppCommandMenuTag.workspaceToggleSelectionHeader }) {
            header = existing
            existing.title = title
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.tag = AppCommandMenuTag.workspaceToggleSelectionHeader
            header.submenu = NSMenu(title: title)
            workspaceMenu.addItem(header)
        }
        guard let submenu = header.submenu else { return }
        for tag in AppCommandRegistry.workspaceTags {
            guard let command = AppCommandRegistry.command(.toggleWorkspaceSelection(tag)) else { continue }
            upsertMenuItem(for: command, in: submenu)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Workspaces":
            refreshWorkspaceMenuEnhancements(in: menu)
        case "Sound":
            refreshSoundMenu(menu)
        default:
            return
        }
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
            let undoTitle = String(localized: "editMenu.undo.default", comment: "Default Edit > Undo title when no undo is available.")
            let title = activeUndoManager?.undoMenuItemTitle ?? undoTitle
            menuItem.title = title.isEmpty ? undoTitle : title
            return activeUndoManager?.canUndo == true
        case #selector(redoWindowAction(_:)):
            let redoTitle = String(localized: "editMenu.redo.default", comment: "Default Edit > Redo title when no redo is available.")
            let title = activeUndoManager?.redoMenuItemTitle ?? redoTitle
            menuItem.title = title.isEmpty ? redoTitle : title
            return activeUndoManager?.canRedo == true
        case #selector(moveActiveWorkspaceLeft(_:)):
            return activeMainWindowController?.canMoveActiveWorkspace(by: -1) == true
        case #selector(moveActiveWorkspaceRight(_:)):
            return activeMainWindowController?.canMoveActiveWorkspace(by: 1) == true
        case #selector(showClawStore(_:)):
            return true
        case #selector(checkForUpdates(_:)):
            return SoyehtUpdater.shared.canCheckForUpdates
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
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
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
            alert.messageText = "Workspace Switch Benchmark"
            alert.informativeText = """
                activate.total p50: \(String(format: "%.2f", result.activateTotalP50)) ms
                activate.total p95: \(String(format: "%.2f", result.activateTotalP95)) ms
                activate.total max: \(String(format: "%.2f", result.activateTotalMax)) ms
                Total samples: \(result.totalSamples)

                Full report: \(result.outputPath.path)
                """
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Benchmark Failed"
            alert.informativeText = "Need an active main window with at least 2 workspaces. Check Console.app for [bench] messages."
            alert.alertStyle = .warning
        }
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func activeMainWindowController() -> SoyehtMainWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? SoyehtMainWindowController { return wc }
        return NSApp.windows.compactMap { $0.windowController as? SoyehtMainWindowController }.first
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
