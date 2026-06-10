import AppKit
import Foundation

struct MainMenuBuilder {
    private let explicitTarget: AnyObject

    init(explicitTarget: AnyObject = MainMenuExplicitTarget.shared) {
        self.explicitTarget = explicitTarget
    }

    func build(_ model: MenuModel = .publicNoWindow()) -> NSMenu {
        let mainMenu = NSMenu(title: model.title)
        mainMenu.identifier = Self.identifier(for: .main)
        for topLevelMenu in model.topLevelMenus {
            mainMenu.addItem(makeTopLevelItem(topLevelMenu))
        }
        return mainMenu
    }

    func buildPublicNoWindowMenu(clawStoreEnabled: Bool = false) -> NSMenu {
        build(.publicNoWindow(clawStoreEnabled: clawStoreEnabled))
    }

    private func makeTopLevelItem(_ model: TopLevelMenuModel) -> NSMenuItem {
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        item.identifier = Self.identifier(for: model.id)
        item.representedObject = model.id
        if let tag = model.tag {
            item.tag = tag
        }

        let submenu = NSMenu(title: model.title)
        submenu.identifier = Self.identifier(for: model.id)
        model.items.map(makeItem).forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func makeItem(_ model: MenuItemModel) -> NSMenuItem {
        switch model {
        case .command(let id):
            return makeCommandItem(id)
        case .system(let role):
            return makeSystemItem(role)
        case .explicit(let role):
            return makeExplicitItem(role)
        case .disabled(let title, let tag):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let tag {
                item.tag = tag
            }
            item.isEnabled = false
            return item
        case .submenu(let id, let title, let tag, let items):
            return makeSubmenuItem(id: id, title: title, tag: tag, items: items.map(makeItem))
        case .dynamic(let sectionID):
            return makeDynamicPlaceholder(sectionID)
        case .separator:
            return .separator()
        }
    }

    private func makeCommandItem(_ id: AppCommandID) -> NSMenuItem {
        guard let command = AppCommandRegistry.command(id) else {
            preconditionFailure("Missing command \(id)")
        }
        let item = NSMenuItem(title: command.title, action: CommandDispatcher.action, keyEquivalent: "")
        item.target = explicitTarget
        item.representedObject = id
        configure(item, shortcut: command.shortcut, tag: command.tag, state: .off, isEnabled: true)
        return item
    }

    private func makeSystemItem(_ role: MainMenuSystemRole) -> NSMenuItem {
        let item = NSMenuItem(title: role.title, action: NSSelectorFromString(role.action), keyEquivalent: "")
        item.representedObject = role
        configure(item, shortcut: role.shortcut, tag: role.tag, state: role.state, isEnabled: true)
        return item
    }

    private func makeExplicitItem(_ role: MainMenuExplicitRole) -> NSMenuItem {
        let item = NSMenuItem(title: role.title, action: NSSelectorFromString(role.action), keyEquivalent: "")
        item.target = explicitTarget
        item.representedObject = role
        configure(item, shortcut: role.shortcut, tag: nil, state: role.state, isEnabled: role.isEnabled)
        return item
    }

    private func makeSubmenuItem(
        id: MainMenuID,
        title: String,
        tag: Int?,
        items: [NSMenuItem],
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = Self.identifier(for: id)
        item.representedObject = id
        if let tag {
            item.tag = tag
        }
        item.isEnabled = isEnabled

        let submenu = NSMenu(title: title)
        submenu.identifier = Self.identifier(for: id)
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func makeDynamicPlaceholder(_ sectionID: MainMenuDynamicSectionID) -> NSMenuItem {
        switch sectionID {
        case .movePaneToWorkspace:
            let item = makeSubmenuItem(
                id: .movePaneToWorkspace,
                title: "Move Pane to Workspace",
                tag: AppCommandMenuTag.paneMoveToWorkspaceHeader,
                items: [
                    makeItem(.disabled(title: "No Focused Pane", tag: MainMenuTag.paneMoveUnavailable)),
                ],
                isEnabled: false
            )
            item.representedObject = sectionID
            return item
        case .workspaces:
            let item = makeItem(.disabled(title: "No Workspace Window", tag: MainMenuTag.workspaceUnavailable))
            item.representedObject = sectionID
            return item
        case .dictationLanguage:
            let item = makeSubmenuItem(
                id: .dictationLanguage,
                title: "Dictation Language",
                tag: MainMenuTag.soundDictationLanguage,
                items: []
            )
            item.representedObject = sectionID
            return item
        }
    }

    private func configure(
        _ item: NSMenuItem,
        shortcut: AppCommandShortcut?,
        tag: Int?,
        state: MenuItemState,
        isEnabled: Bool
    ) {
        if let shortcut {
            item.keyEquivalent = shortcut.menuKeyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers.eventModifierFlags
        }
        if let tag {
            item.tag = tag
        }
        item.state = nsState(for: state)
        item.isEnabled = isEnabled
    }

    private func nsState(for state: MenuItemState) -> NSControl.StateValue {
        switch state {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }

    static func identifier(for menuID: MainMenuID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("soyeht.mainMenu.\(menuID.rawValue)")
    }
}

private final class MainMenuExplicitTarget: NSObject {
    static let shared = MainMenuExplicitTarget()
}
