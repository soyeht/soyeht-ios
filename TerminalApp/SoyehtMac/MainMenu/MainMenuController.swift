import Cocoa
import Foundation
import SoyehtCore

@MainActor
protocol MainMenuRuntimeProviding: AnyObject {
    var workspaceStore: WorkspaceStore { get }
    var frontmostMainWindowController: SoyehtMainWindowController? { get }
    var activeMainWindowController: SoyehtMainWindowController? { get }

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

        refreshSoundMenu()
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
        refreshSoundMenu()
    }

    private func refreshSoundMenu() {
        guard let soundMenu = submenu(.sound) else { return }
        refreshSoundMenu(soundMenu)
    }

    private func refreshSoundMenu(_ soundMenu: NSMenu) {
        soundMenu.removeAllItems()

        let languageTitle = String(
            localized: "voice.mac.menu.dictationLanguage",
            defaultValue: "Dictation Language"
        )
        let header = NSMenuItem(title: languageTitle, action: nil, keyEquivalent: "")
        header.identifier = MainMenuBuilder.identifier(for: .dictationLanguage)
        header.representedObject = MainMenuDynamicSectionID.dictationLanguage
        header.tag = MainMenuTag.soundDictationLanguage
        let languageMenu = NSMenu(title: languageTitle)
        languageMenu.identifier = MainMenuBuilder.identifier(for: .dictationLanguage)
        header.submenu = languageMenu
        soundMenu.addItem(header)

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

    private func refreshMoveFocusedPaneMenu(header: NSMenuItem, submenu: NSMenu) {
        submenu.removeAllItems()

        guard let controller = frontmostMainWindowController,
              canMoveFocusedPane,
              let focusedPaneID = controller.activeGridController?.focusedPaneID,
              controller.store.workspace(controller.activeWorkspaceID)?.layout.contains(focusedPaneID) == true
        else {
            header.isEnabled = false
            submenu.addItem(disabledMenuItem(
                title: String(
                    localized: "paneMenu.moveTo.noPane",
                    defaultValue: "No Focused Pane",
                    comment: "Disabled Pane submenu item shown when there is no focused pane to move."
                ),
                tag: MainMenuTag.paneMoveUnavailable
            ))
            return
        }

        let ordered = controller.store.orderedWorkspaces(in: controller.windowID)
        let destinations = ordered.enumerated().filter { _, workspace in
            workspace.id != controller.activeWorkspaceID
        }

        guard !destinations.isEmpty else {
            header.isEnabled = false
            submenu.addItem(disabledMenuItem(
                title: String(
                    localized: "paneMenu.moveTo.noDestinations",
                    defaultValue: "No Other Workspaces",
                    comment: "Disabled Pane submenu item shown when there is no workspace destination."
                ),
                tag: MainMenuTag.paneMoveUnavailable
            ))
            return
        }

        header.isEnabled = true
        for (index, workspace) in destinations {
            let tag = index + 1
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(moveFocusedPaneToWorkspaceByTag(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = workspace.id
            item.tag = tag
            if let command = AppCommandRegistry.command(.moveFocusedPaneToWorkspace(tag)),
               let shortcut = command.shortcut {
                item.keyEquivalent = shortcut.menuKeyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifiers.eventModifierFlags
            }
            submenu.addItem(item)
        }
    }

    private func rebuildWorkspaceMenu(in workspaceMenu: NSMenu) {
        workspaceMenu.removeAllItems()

        if let command = AppCommandRegistry.command(.showConversationsSidebar) {
            workspaceMenu.addItem(makeMenuItem(for: command))
        }

        workspaceMenu.addItem(.separator())
        appendWorkspaceSelectionItems(to: workspaceMenu)
        workspaceMenu.addItem(.separator())

        for commandID in [AppCommandID.moveActiveWorkspaceLeft, .moveActiveWorkspaceRight] {
            guard let command = AppCommandRegistry.command(commandID) else { continue }
            workspaceMenu.addItem(makeMenuItem(for: command))
        }

        workspaceMenu.addItem(.separator())
        let title = String(localized: "workspaceMenu.groupActive.header", comment: "Workspace submenu header — reveals 'assign active workspace to group' options.")
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.identifier = MainMenuBuilder.identifier(for: .groupActiveWorkspace)
        header.representedObject = MainMenuID.groupActiveWorkspace
        header.tag = AppCommandMenuTag.workspaceGroupActiveHeader
        let submenu = NSMenu(title: title)
        submenu.identifier = MainMenuBuilder.identifier(for: .groupActiveWorkspace)
        header.submenu = submenu
        workspaceMenu.addItem(header)
        refreshWorkspaceMenuEnhancements(in: workspaceMenu)
        collapseSeparators(in: workspaceMenu)
    }

    private func appendWorkspaceSelectionItems(to workspaceMenu: NSMenu) {
        guard let controller = activeMainWindowController else {
            workspaceMenu.addItem(disabledMenuItem(
                title: String(
                    localized: "workspaceMenu.noWindow",
                    defaultValue: "No Workspace Window",
                    comment: "Disabled Workspaces menu item shown when no workspace window is open."
                ),
                tag: MainMenuTag.workspaceUnavailable
            ))
            return
        }

        let ordered = controller.store.orderedWorkspaces(in: controller.windowID)
        guard !ordered.isEmpty else {
            workspaceMenu.addItem(disabledMenuItem(
                title: String(
                    localized: "workspaceMenu.noWorkspaces",
                    defaultValue: "No Workspaces",
                    comment: "Disabled Workspaces menu item shown when the active window has no workspaces."
                ),
                tag: MainMenuTag.workspaceUnavailable
            ))
            return
        }

        for (index, workspace) in ordered.enumerated() {
            let tag = index + 1
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(selectWorkspaceByTag(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = workspace.id
            item.tag = tag
            item.state = workspace.id == controller.activeWorkspaceID ? .on : .off
            if let command = AppCommandRegistry.command(.selectWorkspace(tag)),
               let shortcut = command.shortcut {
                item.keyEquivalent = shortcut.menuKeyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifiers.eventModifierFlags
            }
            workspaceMenu.addItem(item)
        }
    }

    private func refreshWorkspaceMenuEnhancements(in workspaceMenu: NSMenu) {
        guard let runtime,
              let header = workspaceMenu.items.first(where: { $0.tag == AppCommandMenuTag.workspaceGroupActiveHeader }),
              let submenu = header.submenu else { return }

        let currentGroupID = activeMainWindowController?.activeWorkspaceGroupID
        let hasActiveWorkspace = activeMainWindowController != nil
        submenu.removeAllItems()

        let none = NSMenuItem(title: String(localized: "workspaceMenu.group.none", comment: "Group submenu item that unassigns the active workspace from any group."), action: #selector(assignActiveWorkspaceToGroup(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = MainMenuExplicitRole.assignActiveWorkspaceToNoGroup
        none.state = currentGroupID == nil ? .on : .off
        none.isEnabled = hasActiveWorkspace
        submenu.addItem(none)

        if !runtime.workspaceStore.orderedGroups.isEmpty {
            submenu.addItem(.separator())
            for group in runtime.workspaceStore.orderedGroups {
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
        newGroup.representedObject = MainMenuExplicitRole.newGroupForActiveWorkspace
        newGroup.isEnabled = hasActiveWorkspace
        submenu.addItem(newGroup)
    }

    private func makeMenuItem(for command: AppCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: CommandDispatcher.action,
            keyEquivalent: command.shortcut?.menuKeyEquivalent ?? ""
        )
        configureMenuItem(item, with: command)
        return item
    }

    private func configureMenuItem(_ item: NSMenuItem, with command: AppCommand) {
        item.title = command.title
        item.action = CommandDispatcher.action
        item.target = self
        item.representedObject = command.id
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

    private func disabledMenuItem(title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        item.isEnabled = false
        return item
    }

    private func collapseSeparators(in menu: NSMenu) {
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            let isEdge = index == 0 || index == menu.items.count - 1
            let previousIsSeparator = index > 0 && menu.items[index - 1].isSeparatorItem
            if item.isSeparatorItem && (isEdge || previousIsSeparator) {
                menu.removeItem(at: index)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier {
        case MainMenuBuilder.identifier(for: .pane):
            if let header = menu.items.first(where: { $0.tag == AppCommandMenuTag.paneMoveToWorkspaceHeader }),
               let submenu = header.submenu {
                refreshMoveFocusedPaneMenu(header: header, submenu: submenu)
            }
        case MainMenuBuilder.identifier(for: .edit), MainMenuBuilder.identifier(for: .view):
            PublicMenuSurface.removeDuplicateVisibleItems(from: menu)
        case MainMenuBuilder.identifier(for: .workspaces):
            rebuildWorkspaceMenu(in: menu)
        case MainMenuBuilder.identifier(for: .sound):
            refreshSoundMenu(menu)
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

    private var activeMainWindowController: SoyehtMainWindowController? {
        runtime?.activeMainWindowController
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
        let activeController = activeMainWindowController
        let frontmostState = frontmostController.map {
            commandWindowState(for: $0, includeMoveDestinations: true)
        }
        let activeState: MainWindowCommandUIState?
        if let activeController, let frontmostController, activeController === frontmostController {
            activeState = frontmostState
        } else {
            activeState = activeController.map {
                commandWindowState(for: $0, includeMoveDestinations: false)
            }
        }
        return CommandUIContext(
            frontmostWindow: frontmostState,
            activeWindow: activeState,
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
            menuItem.state = nsState(for: state)
        }
        return validation.isEnabled
    }

    private func nsState(for state: MenuItemState) -> NSControl.StateValue {
        switch state {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
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
