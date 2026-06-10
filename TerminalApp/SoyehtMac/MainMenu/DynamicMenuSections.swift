import AppKit
import Foundation

struct MainMenuDynamicActionSelectors {
    let dispatchAppCommand: Selector
    let selectWorkspaceByTag: Selector
    let moveFocusedPaneToWorkspaceByTag: Selector
    let assignActiveWorkspaceToGroup: Selector
    let newGroupForActiveWorkspace: Selector
    let selectVoiceInputLanguage: Selector
}

struct WorkspaceMenuEntry: Hashable {
    let id: Workspace.ID
    let name: String
    let tag: Int
    let isActive: Bool
}

struct WorkspaceGroupMenuEntry: Hashable {
    let id: Group.ID
    let name: String
    let isActive: Bool
}

enum WorkspaceSelectionMenuState: Hashable {
    case noWindow
    case noWorkspaces
    case workspaces([WorkspaceMenuEntry])
}

struct WorkspaceMenuSectionState: Hashable {
    let selection: WorkspaceSelectionMenuState
    let groups: [WorkspaceGroupMenuEntry]
    let hasActiveWorkspace: Bool
    let activeWorkspaceHasNoGroup: Bool
}

enum MovePaneMenuSectionState: Hashable {
    case noFocusedPane
    case noDestinations
    case destinations([WorkspaceMenuEntry])
}

struct DictationLanguageMenuEntry: Hashable {
    let title: String
    let rawValue: String
    let isSelected: Bool
}

struct DictationLanguageMenuSectionState: Hashable {
    let entries: [DictationLanguageMenuEntry]
}

enum MainMenuItemFactory {
    static func commandItem(
        for command: AppCommand,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: action,
            keyEquivalent: command.shortcut?.menuKeyEquivalent ?? ""
        )
        item.target = target
        item.representedObject = command.id
        if let tag = command.tag {
            item.tag = tag
        }
        applyShortcut(command.shortcut, to: item)
        return item
    }

    static func disabledItem(title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        item.isEnabled = false
        return item
    }

    static func collapseSeparators(in menu: NSMenu) {
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            let isEdge = index == 0 || index == menu.items.count - 1
            let previousIsSeparator = index > 0 && menu.items[index - 1].isSeparatorItem
            if item.isSeparatorItem && (isEdge || previousIsSeparator) {
                menu.removeItem(at: index)
            }
        }
    }

    static func nsState(for state: MenuItemState) -> NSControl.StateValue {
        switch state {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }

    static func applyShortcut(_ shortcut: AppCommandShortcut?, to item: NSMenuItem) {
        guard let shortcut else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifiers.eventModifierFlags
    }
}

struct MovePaneMenuSectionBuilder {
    let target: AnyObject
    let actions: MainMenuDynamicActionSelectors

    func rebuild(
        header: NSMenuItem,
        submenu: NSMenu,
        state: MovePaneMenuSectionState
    ) {
        submenu.removeAllItems()

        switch state {
        case .noFocusedPane:
            header.isEnabled = false
            submenu.addItem(MainMenuItemFactory.disabledItem(
                title: String(
                    localized: "paneMenu.moveTo.noPane",
                    defaultValue: "No Focused Pane",
                    comment: "Disabled Pane submenu item shown when there is no focused pane to move."
                ),
                tag: MainMenuTag.paneMoveUnavailable
            ))
        case .noDestinations:
            header.isEnabled = false
            submenu.addItem(MainMenuItemFactory.disabledItem(
                title: String(
                    localized: "paneMenu.moveTo.noDestinations",
                    defaultValue: "No Other Workspaces",
                    comment: "Disabled Pane submenu item shown when there is no workspace destination."
                ),
                tag: MainMenuTag.paneMoveUnavailable
            ))
        case .destinations(let destinations):
            header.isEnabled = true
            for workspace in destinations {
                submenu.addItem(movePaneItem(for: workspace))
            }
        }
    }

    private func movePaneItem(for workspace: WorkspaceMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: workspace.name,
            action: actions.moveFocusedPaneToWorkspaceByTag,
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = workspace.id
        item.tag = workspace.tag
        if let command = AppCommandRegistry.command(.moveFocusedPaneToWorkspace(workspace.tag)) {
            MainMenuItemFactory.applyShortcut(command.shortcut, to: item)
        }
        return item
    }
}

struct WorkspaceMenuSectionBuilder {
    let target: AnyObject
    let actions: MainMenuDynamicActionSelectors

    func rebuild(menu workspaceMenu: NSMenu, state: WorkspaceMenuSectionState) {
        workspaceMenu.removeAllItems()

        if let command = AppCommandRegistry.command(.showConversationsSidebar) {
            workspaceMenu.addItem(MainMenuItemFactory.commandItem(
                for: command,
                target: target,
                action: actions.dispatchAppCommand
            ))
        }

        workspaceMenu.addItem(.separator())
        appendWorkspaceSelectionItems(to: workspaceMenu, state: state.selection)
        workspaceMenu.addItem(.separator())

        for commandID in [AppCommandID.moveActiveWorkspaceLeft, .moveActiveWorkspaceRight] {
            guard let command = AppCommandRegistry.command(commandID) else { continue }
            workspaceMenu.addItem(MainMenuItemFactory.commandItem(
                for: command,
                target: target,
                action: actions.dispatchAppCommand
            ))
        }

        workspaceMenu.addItem(.separator())
        workspaceMenu.addItem(groupActiveWorkspaceItem(state: state))
        MainMenuItemFactory.collapseSeparators(in: workspaceMenu)
    }

    private func appendWorkspaceSelectionItems(
        to workspaceMenu: NSMenu,
        state: WorkspaceSelectionMenuState
    ) {
        switch state {
        case .noWindow:
            workspaceMenu.addItem(MainMenuItemFactory.disabledItem(
                title: String(
                    localized: "workspaceMenu.noWindow",
                    defaultValue: "No Workspace Window",
                    comment: "Disabled Workspaces menu item shown when no workspace window is open."
                ),
                tag: MainMenuTag.workspaceUnavailable
            ))
        case .noWorkspaces:
            workspaceMenu.addItem(MainMenuItemFactory.disabledItem(
                title: String(
                    localized: "workspaceMenu.noWorkspaces",
                    defaultValue: "No Workspaces",
                    comment: "Disabled Workspaces menu item shown when the active window has no workspaces."
                ),
                tag: MainMenuTag.workspaceUnavailable
            ))
        case .workspaces(let workspaces):
            for workspace in workspaces {
                workspaceMenu.addItem(selectWorkspaceItem(for: workspace))
            }
        }
    }

    private func selectWorkspaceItem(for workspace: WorkspaceMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: workspace.name,
            action: actions.selectWorkspaceByTag,
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = workspace.id
        item.tag = workspace.tag
        item.state = workspace.isActive ? .on : .off
        if let command = AppCommandRegistry.command(.selectWorkspace(workspace.tag)) {
            MainMenuItemFactory.applyShortcut(command.shortcut, to: item)
        }
        return item
    }

    private func groupActiveWorkspaceItem(state: WorkspaceMenuSectionState) -> NSMenuItem {
        let title = String(
            localized: "workspaceMenu.groupActive.header",
            comment: "Workspace submenu header — reveals 'assign active workspace to group' options."
        )
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.identifier = MainMenuBuilder.identifier(for: .groupActiveWorkspace)
        header.representedObject = MainMenuID.groupActiveWorkspace
        header.tag = AppCommandMenuTag.workspaceGroupActiveHeader

        let submenu = NSMenu(title: title)
        submenu.identifier = MainMenuBuilder.identifier(for: .groupActiveWorkspace)
        rebuildGroupActiveWorkspaceMenu(submenu, state: state)
        header.submenu = submenu
        return header
    }

    private func rebuildGroupActiveWorkspaceMenu(
        _ submenu: NSMenu,
        state: WorkspaceMenuSectionState
    ) {
        let none = NSMenuItem(
            title: String(
                localized: "workspaceMenu.group.none",
                comment: "Group submenu item that unassigns the active workspace from any group."
            ),
            action: actions.assignActiveWorkspaceToGroup,
            keyEquivalent: ""
        )
        none.target = target
        none.representedObject = MainMenuExplicitRole.assignActiveWorkspaceToNoGroup
        none.state = state.activeWorkspaceHasNoGroup ? .on : .off
        none.isEnabled = state.hasActiveWorkspace
        submenu.addItem(none)

        if !state.groups.isEmpty {
            submenu.addItem(.separator())
            for group in state.groups {
                let item = NSMenuItem(
                    title: group.name,
                    action: actions.assignActiveWorkspaceToGroup,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = group.id
                item.state = group.isActive ? .on : .off
                item.isEnabled = state.hasActiveWorkspace
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let newGroup = NSMenuItem(
            title: String(
                localized: "workspaceMenu.group.newGroup",
                comment: "Group submenu item that opens the new-group prompt."
            ),
            action: actions.newGroupForActiveWorkspace,
            keyEquivalent: ""
        )
        newGroup.target = target
        newGroup.representedObject = MainMenuExplicitRole.newGroupForActiveWorkspace
        newGroup.isEnabled = state.hasActiveWorkspace
        submenu.addItem(newGroup)
    }
}

struct DictationLanguageMenuSectionBuilder {
    let target: AnyObject
    let actions: MainMenuDynamicActionSelectors

    func rebuild(
        soundMenu: NSMenu,
        state: DictationLanguageMenuSectionState
    ) {
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
        for entry in state.entries {
            languageMenu.addItem(languageItem(for: entry))
        }
        header.submenu = languageMenu
        soundMenu.addItem(header)
    }

    private func languageItem(for entry: DictationLanguageMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.title,
            action: actions.selectVoiceInputLanguage,
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = entry.rawValue
        item.state = entry.isSelected ? .on : .off
        return item
    }
}
