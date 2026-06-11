import Cocoa
import Foundation
import SoyehtCore

@MainActor
protocol MainMenuRuntimeProviding: AnyObject {
    var workspaceStore: WorkspaceStore { get }
    var frontmostMainWindowController: SoyehtMainWindowController? { get }

    func retainMenuWindowController(_ windowController: NSWindowController)
}

@MainActor
protocol MainMenuActionHandling: AnyObject, AppCommandPerforming {
    func closeActiveWorkspace(_ sender: Any?)
    func logout(_ sender: Any)
    func defaultFontSize(_ sender: Any?)
    func biggerFont(_ sender: Any?)
    func smallerFont(_ sender: Any?)
    func selectWorkspaceByTag(_ sender: Any?)
    func moveFocusedPaneToWorkspaceByTag(_ sender: Any?)
    func newGroupForActiveWorkspace(_ sender: Any?)
    func assignActiveWorkspaceToGroup(_ sender: NSMenuItem)
}

@MainActor
final class MainMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private weak var runtime: MainMenuRuntimeProviding?
    private weak var actionHandler: MainMenuActionHandling?

    init(runtime: MainMenuRuntimeProviding, actionHandler: MainMenuActionHandling) {
        self.runtime = runtime
        self.actionHandler = actionHandler
        super.init()
    }

    func installProgrammaticMainMenu() {
        let mainMenu = MainMenuBuilder(explicitTarget: self)
            .buildPublicNoWindowMenu(clawStoreEnabled: SoyehtFeatureFlags.clawStoreEnabled)
        NSApp.mainMenu = mainMenu
        configureProgrammaticMainMenuRuntime(mainMenu)
    }

    func installProgrammaticMainMenuIfNeeded() {
        guard NSApp.mainMenu?.identifier != MainMenuBuilder.identifier(for: .main) else { return }
        installProgrammaticMainMenu()
    }

    func installInternalDebugMenuIfNeeded() {
        #if DEBUG
        guard Self.shouldShowInternalDebugMenu else { return }
        installDebugMenu()
        #endif
    }

    private func configureProgrammaticMainMenuRuntime(_ mainMenu: NSMenu) {
        NSApp.windowsMenu = submenu(.window, in: mainMenu)
        NSApp.helpMenu = submenu(.help, in: mainMenu)

        [
            MainMenuID.edit,
            .view,
            .pane,
            .workspaces,
            .sound,
        ].compactMap { submenu($0, in: mainMenu) }
            .forEach { $0.delegate = self }

        rebuildSoundMenuIfPresent()
        installInternalDebugMenuIfNeeded()
    }

    private func submenu(_ id: MainMenuID) -> NSMenu? {
        submenu(id, in: NSApp.mainMenu)
    }

    private func submenu(_ id: MainMenuID, in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.first(where: {
            $0.identifier == MainMenuBuilder.identifier(for: id)
                || $0.submenu?.identifier == MainMenuBuilder.identifier(for: id)
        })?.submenu
    }

    private var dynamicActions: MainMenuDynamicActionSelectors {
        MainMenuDynamicActionSelectors(
            dispatchAppCommand: CommandDispatcher.action,
            selectWorkspaceByTag: #selector(selectWorkspaceByTag(_:)),
            moveFocusedPaneToWorkspaceByTag: #selector(moveFocusedPaneToWorkspaceByTag(_:)),
            assignActiveWorkspaceToGroup: #selector(assignActiveWorkspaceToGroup(_:)),
            newGroupForActiveWorkspace: #selector(newGroupForActiveWorkspace(_:)),
            selectVoiceInputLanguage: #selector(selectVoiceInputLanguage(_:))
        )
    }

    @IBAction func dispatchAppCommand(_ sender: Any?) {
        guard CommandDispatcher(performer: actionHandler).dispatch(sender) else {
            NSSound.beep()
            return
        }
    }

    @IBAction func closeActiveWorkspace(_ sender: Any?) {
        actionHandler?.closeActiveWorkspace(sender)
    }

    @IBAction func logout(_ sender: Any?) {
        actionHandler?.logout(sender ?? self)
    }

    @IBAction func defaultFontSize(_ sender: Any?) {
        actionHandler?.defaultFontSize(sender)
    }

    @IBAction func biggerFont(_ sender: Any?) {
        actionHandler?.biggerFont(sender)
    }

    @IBAction func smallerFont(_ sender: Any?) {
        actionHandler?.smallerFont(sender)
    }

    @IBAction func selectWorkspaceByTag(_ sender: Any?) {
        actionHandler?.selectWorkspaceByTag(sender)
    }

    @IBAction func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {
        actionHandler?.moveFocusedPaneToWorkspaceByTag(sender)
    }

    @IBAction func newGroupForActiveWorkspace(_ sender: Any?) {
        actionHandler?.newGroupForActiveWorkspace(sender)
    }

    @IBAction func assignActiveWorkspaceToGroup(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else {
            NSSound.beep()
            return
        }
        actionHandler?.assignActiveWorkspaceToGroup(item)
    }

    @IBAction func selectVoiceInputLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let language = MacVoiceInputLanguage(rawValue: rawValue) else { return }

        MacVoiceInputPreferences.selectedLanguage = language
        rebuildSoundMenuIfPresent()
    }

    private func rebuildSoundMenuIfPresent() {
        guard let soundMenu = submenu(.sound) else { return }
        rebuildSoundMenu(soundMenu)
    }

    private func rebuildSoundMenu(_ soundMenu: NSMenu) {
        let builder = DictationLanguageMenuSectionBuilder(target: self, actions: dynamicActions)
        builder.rebuild(soundMenu: soundMenu, state: dictationLanguageSectionState)
    }

    private func rebuildMovePaneSection(header: NSMenuItem, submenu: NSMenu) {
        let builder = MovePaneMenuSectionBuilder(target: self, actions: dynamicActions)
        builder.rebuild(header: header, submenu: submenu, state: movePaneSectionState)
    }

    private func rebuildWorkspaceSection(in workspaceMenu: NSMenu) {
        let builder = WorkspaceMenuSectionBuilder(target: self, actions: dynamicActions)
        builder.rebuild(menu: workspaceMenu, state: workspaceSectionState)
    }

    private var dictationLanguageSectionState: DictationLanguageMenuSectionState {
        let selected = MacVoiceInputPreferences.selectedLanguage
        return DictationLanguageMenuSectionState(entries: MacVoiceInputLanguage.allCases.map { language in
            DictationLanguageMenuEntry(
                title: language.menuTitle,
                rawValue: language.rawValue,
                isSelected: language == selected
            )
        })
    }

    private var movePaneSectionState: MovePaneMenuSectionState {
        guard let controller = frontmostMainWindowController,
              canMoveFocusedPane,
              let focusedPaneID = controller.activeGridController?.focusedPaneID,
              controller.store.workspace(controller.activeWorkspaceID)?.layout.contains(focusedPaneID) == true
        else {
            return .noFocusedPane
        }

        let destinations = controller.store.orderedWorkspaces(in: controller.windowID)
            .enumerated()
            .compactMap { index, workspace -> WorkspaceMenuEntry? in
                guard workspace.id != controller.activeWorkspaceID else { return nil }
                return WorkspaceMenuEntry(
                    id: workspace.id,
                    name: workspace.name,
                    tag: index + 1,
                    isActive: false
                )
            }

        return destinations.isEmpty ? .noDestinations : .destinations(destinations)
    }

    private var workspaceSectionState: WorkspaceMenuSectionState {
        let controller = frontmostMainWindowController
        let currentGroupID = controller?.activeWorkspaceGroupID
        let selection: WorkspaceSelectionMenuState

        if let controller {
            let workspaces = workspaceEntries(for: controller)
            selection = workspaces.isEmpty ? .noWorkspaces : .workspaces(workspaces)
        } else {
            selection = .noWindow
        }

        return WorkspaceMenuSectionState(
            selection: selection,
            groups: workspaceGroups(activeGroupID: currentGroupID),
            hasActiveWorkspace: controller != nil,
            activeWorkspaceHasNoGroup: currentGroupID == nil
        )
    }

    private func workspaceEntries(for controller: SoyehtMainWindowController) -> [WorkspaceMenuEntry] {
        controller.store.orderedWorkspaces(in: controller.windowID)
            .enumerated()
            .map { index, workspace in
                WorkspaceMenuEntry(
                    id: workspace.id,
                    name: workspace.name,
                    tag: index + 1,
                    isActive: workspace.id == controller.activeWorkspaceID
                )
            }
    }

    private func workspaceGroups(activeGroupID: Group.ID?) -> [WorkspaceGroupMenuEntry] {
        runtime?.workspaceStore.orderedGroups.map { group in
            WorkspaceGroupMenuEntry(
                id: group.id,
                name: group.name,
                isActive: group.id == activeGroupID
            )
        } ?? []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier {
        case MainMenuBuilder.identifier(for: .pane):
            if let header = menu.items.first(where: { $0.tag == AppCommandMenuTag.paneMoveToWorkspaceHeader }),
               let submenu = header.submenu {
                rebuildMovePaneSection(header: header, submenu: submenu)
            }
        case MainMenuBuilder.identifier(for: .edit), MainMenuBuilder.identifier(for: .view):
            PublicMenuSurface.removeDuplicateVisibleItems(from: menu)
        case MainMenuBuilder.identifier(for: .workspaces):
            rebuildWorkspaceSection(in: menu)
        case MainMenuBuilder.identifier(for: .sound):
            rebuildSoundMenu(menu)
        default:
            return
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let context = commandUIContext
        if let commandID = menuItem.representedObject as? AppCommandID,
           let command = AppCommandRegistry.command(commandID) {
            return apply(command.validation(in: context), to: menuItem)
        }
        if let role = menuItem.representedObject as? MainMenuExplicitRole {
            return apply(role.validation(in: context), to: menuItem)
        }

        switch menuItem.action {
        case #selector(selectWorkspaceByTag(_:)):
            return validateSelectWorkspaceItem(menuItem, context: context)
        case #selector(moveFocusedPaneToWorkspaceByTag(_:)):
            return validateMoveFocusedPaneItem(menuItem, context: context)
        case #selector(assignActiveWorkspaceToGroup(_:)), #selector(newGroupForActiveWorkspace(_:)):
            return context.activeWindow != nil
        default:
            return true
        }
    }

    private var frontmostMainWindowController: SoyehtMainWindowController? {
        runtime?.frontmostMainWindowController
    }

    private var canMoveFocusedPane: Bool {
        guard let controller = frontmostMainWindowController,
              let grid = controller.activeGridController,
              grid.canActOnFocusedPane,
              controller.store.workspaceCount(in: controller.windowID) > 1
        else {
            return false
        }
        return true
    }

    private var activeUndoManager: UndoManager? {
        frontmostMainWindowController?.window?.undoManager
    }

    private var commandUIContext: CommandUIContext {
        let frontmostController = frontmostMainWindowController
        let frontmostState = frontmostController.map {
            commandWindowState(for: $0, includeMoveDestinations: true)
        }
        return CommandUIContext(
            frontmostWindow: frontmostState,
            activeWindow: frontmostState,
            undo: UndoCommandUIState(
                canUndo: activeUndoManager?.canUndo == true,
                canRedo: activeUndoManager?.canRedo == true,
                undoMenuItemTitle: activeUndoManager?.undoMenuItemTitle,
                redoMenuItemTitle: activeUndoManager?.redoMenuItemTitle
            ),
            hasPairedServers: !SessionStore.shared.pairedServers.isEmpty,
            clawStoreEnabled: SoyehtFeatureFlags.clawStoreEnabled,
            canCheckForUpdates: SoyehtUpdater.shared.canCheckForUpdates,
            terminalFontSize: Double(TerminalPreferences.shared.fontSize),
            defaultTerminalFontSize: Double(TerminalPreferences.defaultFontSize),
            minimumTerminalFontSize: Double(TerminalPreferences.minimumFontSize)
        )
    }

    private func commandWindowState(
        for controller: SoyehtMainWindowController,
        includeMoveDestinations: Bool
    ) -> MainWindowCommandUIState {
        let ordered = controller.store.orderedWorkspaces(in: controller.windowID)
        let activeWorkspaceTag = ordered.firstIndex(where: { $0.id == controller.activeWorkspaceID })
            .map { $0 + 1 }
        let selectableTags = Set(ordered.indices.map { $0 + 1 })
        let moveDestinations: Set<Int>
        if includeMoveDestinations, canMoveFocusedPane {
            moveDestinations = Set(ordered.enumerated().compactMap { index, workspace in
                workspace.id == controller.activeWorkspaceID ? nil : index + 1
            })
        } else {
            moveDestinations = []
        }

        return MainWindowCommandUIState(
            workspaceCount: ordered.count,
            activeWorkspaceTag: activeWorkspaceTag,
            selectableWorkspaceTags: selectableTags,
            moveFocusedPaneDestinationTags: moveDestinations,
            canMoveActiveWorkspaceLeft: controller.canMoveActiveWorkspace(by: -1),
            canMoveActiveWorkspaceRight: controller.canMoveActiveWorkspace(by: 1),
            paneGrid: controller.activeGridController.map(commandPaneState)
        )
    }

    private func commandPaneState(for grid: PaneGridController) -> PaneCommandUIState {
        let directions: [(CommandUIDirection, WorkspaceLayout.Direction)] = [
            (.left, .left),
            (.right, .right),
            (.up, .up),
            (.down, .down),
        ]
        return PaneCommandUIState(
            canActOnFocusedPane: grid.canActOnFocusedPane,
            hasZoomedPane: grid.zoomedPaneID != nil,
            canRotateFocusedSplit: grid.canRotateFocusedSplit,
            focusableDirections: Set(directions.compactMap { command, layout in
                grid.canFocusNeighbor(layout) ? command : nil
            }),
            swappableDirections: Set(directions.compactMap { command, layout in
                grid.canSwapNeighbor(layout) ? command : nil
            })
        )
    }

    private func validateSelectWorkspaceItem(
        _ menuItem: NSMenuItem,
        context: CommandUIContext
    ) -> Bool {
        let tag = menuItem.tag
        let validation = CommandUIValidation(
            isEnabled: context.activeWindow?.selectableWorkspaceTags.contains(tag) == true,
            state: context.activeWindow?.activeWorkspaceTag == tag ? .on : .off
        )
        return apply(validation, to: menuItem)
    }

    private func validateMoveFocusedPaneItem(
        _ menuItem: NSMenuItem,
        context: CommandUIContext
    ) -> Bool {
        context.frontmostWindow?.moveFocusedPaneDestinationTags.contains(menuItem.tag) == true
    }

    private func apply(_ validation: CommandUIValidation, to menuItem: NSMenuItem) -> Bool {
        if let title = validation.title {
            menuItem.title = title
        }
        if let state = validation.state {
            menuItem.state = MainMenuItemFactory.nsState(for: state)
        }
        return validation.isEnabled
    }

    #if DEBUG
    private static var shouldShowInternalDebugMenu: Bool {
        PublicMenuSurface.shouldShowInternalDebugMenu(isDevelopmentBuild: true)
    }

    private func installDebugMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let debugTitle = String(localized: "debug.menu.title")
        let debugMenu: NSMenu
        let isFreshMenu: Bool
        if let existing = submenu(.debug, in: mainMenu) {
            debugMenu = existing
            isFreshMenu = false
        } else {
            debugMenu = NSMenu(title: debugTitle)
            debugMenu.identifier = MainMenuBuilder.identifier(for: .debug)
            isFreshMenu = true
        }

        guard !debugMenu.items.contains(where: { $0.tag == MainMenuTag.debugBenchmark }) else { return }

        if !isFreshMenu { debugMenu.addItem(NSMenuItem.separator()) }

        let openPaneItem = NSMenuItem(title: String(localized: "debug.menu.openPaneWindow"), action: #selector(openPaneDebugWindow(_:)), keyEquivalent: "")
        openPaneItem.target = self
        openPaneItem.tag = MainMenuTag.debugOpenPaneWindow
        debugMenu.addItem(openPaneItem)

        let sidebarItem = NSMenuItem(
            title: String(localized: "debug.menu.openConversationsSidebar"),
            action: CommandDispatcher.action,
            keyEquivalent: AppCommandRegistry.command(.showConversationsSidebar)?.shortcut?.menuKeyEquivalent ?? ""
        )
        sidebarItem.keyEquivalentModifierMask = AppCommandRegistry.command(.showConversationsSidebar)?.shortcut?.modifiers.eventModifierFlags ?? []
        sidebarItem.target = self
        sidebarItem.representedObject = AppCommandID.showConversationsSidebar
        sidebarItem.tag = MainMenuTag.debugConversationsSidebar
        debugMenu.addItem(sidebarItem)

        debugMenu.addItem(NSMenuItem.separator())

        let benchItem = NSMenuItem(
            title: String(localized: "debug.menu.benchmarkWorkspaceSwitching"),
            action: #selector(runWorkspaceSwitchBenchmark(_:)),
            keyEquivalent: ""
        )
        benchItem.target = self
        benchItem.tag = MainMenuTag.debugBenchmark
        debugMenu.addItem(benchItem)

        if isFreshMenu {
            let debugItem = NSMenuItem(title: debugTitle, action: nil, keyEquivalent: "")
            debugItem.identifier = MainMenuBuilder.identifier(for: .debug)
            debugItem.representedObject = MainMenuID.debug
            debugItem.submenu = debugMenu
            let insertIndex = mainMenu.items.firstIndex {
                $0.identifier == MainMenuBuilder.identifier(for: .help)
            } ?? max(0, mainMenu.items.count - 1)
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
        window.title = String(localized: "debug.window.paneGrid")
        window.contentViewController = grid
        window.center()

        let wc = NSWindowController(window: window)
        runtime?.retainMenuWindowController(wc)
        wc.showWindow(nil)
    }
    #endif
}
