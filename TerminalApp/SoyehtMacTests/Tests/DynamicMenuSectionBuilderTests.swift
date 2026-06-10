import AppKit
import Foundation
import XCTest
@testable import SoyehtMacDomain

final class DynamicMenuSectionBuilderTests: XCTestCase {
    private var target: DynamicMenuSectionTarget!

    override func setUp() {
        super.setUp()
        target = DynamicMenuSectionTarget()
    }

    override func tearDown() {
        target = nil
        super.tearDown()
    }

    func testMovePaneSectionBuildsDestinationItemsWithStableIdentityAndShortcuts() throws {
        let header = NSMenuItem(title: "Move Pane to Workspace", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move Pane to Workspace")
        let firstID = Workspace.ID()
        let secondID = Workspace.ID()

        MovePaneMenuSectionBuilder(target: target, actions: target.actions).rebuild(
            header: header,
            submenu: submenu,
            state: .destinations([
                WorkspaceMenuEntry(id: firstID, name: "Alpha", tag: 1, isActive: false),
                WorkspaceMenuEntry(id: secondID, name: "Gamma", tag: 3, isActive: false),
            ])
        )

        XCTAssertTrue(header.isEnabled)
        XCTAssertEqual(submenu.items.count, 2)
        XCTAssertEqual(submenu.items[0].title, "Alpha")
        XCTAssertEqual(submenu.items[0].action, #selector(DynamicMenuSectionTarget.moveFocusedPaneToWorkspaceByTag(_:)))
        XCTAssertTrue(submenu.items[0].target === target)
        XCTAssertEqual(submenu.items[0].representedObject as? Workspace.ID, firstID)
        XCTAssertEqual(submenu.items[0].tag, 1)

        let second = submenu.items[1]
        let shortcut = try XCTUnwrap(AppCommandRegistry.command(.moveFocusedPaneToWorkspace(3))?.shortcut)
        XCTAssertEqual(second.title, "Gamma")
        XCTAssertEqual(second.representedObject as? Workspace.ID, secondID)
        XCTAssertEqual(second.tag, 3)
        XCTAssertEqual(second.keyEquivalent, shortcut.menuKeyEquivalent)
        XCTAssertEqual(second.keyEquivalentModifierMask, shortcut.modifiers.eventModifierFlags)
    }

    func testMovePaneSectionShowsDisabledFallbacks() {
        let header = NSMenuItem(title: "Move Pane to Workspace", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move Pane to Workspace")
        let builder = MovePaneMenuSectionBuilder(target: target, actions: target.actions)

        builder.rebuild(header: header, submenu: submenu, state: .noFocusedPane)
        XCTAssertFalse(header.isEnabled)
        XCTAssertEqual(submenu.items.map(\.tag), [MainMenuTag.paneMoveUnavailable])
        XCTAssertEqual(submenu.items.first?.title, "No Focused Pane")

        builder.rebuild(header: header, submenu: submenu, state: .noDestinations)
        XCTAssertFalse(header.isEnabled)
        XCTAssertEqual(submenu.items.map(\.tag), [MainMenuTag.paneMoveUnavailable])
        XCTAssertEqual(submenu.items.first?.title, "No Other Workspaces")
    }

    func testWorkspaceSectionBuildsSelectionAndGroupItemsWithStableIdentity() throws {
        let menu = NSMenu(title: "Workspaces")
        let activeWorkspaceID = Workspace.ID()
        let secondWorkspaceID = Workspace.ID()
        let activeGroupID = Group.ID()

        WorkspaceMenuSectionBuilder(target: target, actions: target.actions).rebuild(
            menu: menu,
            state: WorkspaceMenuSectionState(
                selection: .workspaces([
                    WorkspaceMenuEntry(id: activeWorkspaceID, name: "Main", tag: 1, isActive: true),
                    WorkspaceMenuEntry(id: secondWorkspaceID, name: "Review", tag: 2, isActive: false),
                ]),
                groups: [
                    WorkspaceGroupMenuEntry(id: activeGroupID, name: "Product", isActive: true),
                    WorkspaceGroupMenuEntry(id: Group.ID(), name: "QA", isActive: false),
                ],
                hasActiveWorkspace: true,
                activeWorkspaceHasNoGroup: false
            )
        )

        let sidebar = try XCTUnwrap(menu.items.first { $0.representedObject as? AppCommandID == .showConversationsSidebar })
        XCTAssertEqual(sidebar.action, #selector(DynamicMenuSectionTarget.dispatchAppCommand(_:)))
        XCTAssertTrue(sidebar.target === target)

        let workspaceItems = menu.items.filter {
            $0.action == #selector(DynamicMenuSectionTarget.selectWorkspaceByTag(_:))
        }
        XCTAssertEqual(workspaceItems.map(\.title), ["Main", "Review"])
        XCTAssertEqual(workspaceItems.map(\.tag), [1, 2])
        XCTAssertEqual(workspaceItems[0].representedObject as? Workspace.ID, activeWorkspaceID)
        XCTAssertEqual(workspaceItems[0].state, .on)
        XCTAssertEqual(workspaceItems[1].representedObject as? Workspace.ID, secondWorkspaceID)
        XCTAssertEqual(workspaceItems[1].state, .off)

        let groupHeader = try XCTUnwrap(menu.items.first { $0.tag == AppCommandMenuTag.workspaceGroupActiveHeader })
        XCTAssertEqual(groupHeader.identifier, MainMenuBuilder.identifier(for: .groupActiveWorkspace))
        XCTAssertEqual(groupHeader.representedObject as? MainMenuID, .groupActiveWorkspace)

        let groupMenu = try XCTUnwrap(groupHeader.submenu)
        let noGroup = groupMenu.items[0]
        XCTAssertEqual(noGroup.representedObject as? MainMenuExplicitRole, .assignActiveWorkspaceToNoGroup)
        XCTAssertEqual(noGroup.action, #selector(DynamicMenuSectionTarget.assignActiveWorkspaceToGroup(_:)))
        XCTAssertTrue(noGroup.target === target)
        XCTAssertEqual(noGroup.state, .off)
        XCTAssertTrue(noGroup.isEnabled)

        let activeGroup = try XCTUnwrap(groupMenu.items.first { $0.representedObject as? Group.ID == activeGroupID })
        XCTAssertEqual(activeGroup.title, "Product")
        XCTAssertEqual(activeGroup.state, .on)
        XCTAssertTrue(activeGroup.isEnabled)

        let newGroup = try XCTUnwrap(
            groupMenu.items.first { $0.representedObject as? MainMenuExplicitRole == .newGroupForActiveWorkspace }
        )
        XCTAssertEqual(newGroup.action, #selector(DynamicMenuSectionTarget.newGroupForActiveWorkspace(_:)))
        XCTAssertTrue(newGroup.target === target)
        XCTAssertTrue(newGroup.isEnabled)
    }

    func testWorkspaceSectionShowsNoWindowFallbackWithoutLosingGroupIdentity() throws {
        let menu = NSMenu(title: "Workspaces")
        let groupID = Group.ID()

        WorkspaceMenuSectionBuilder(target: target, actions: target.actions).rebuild(
            menu: menu,
            state: WorkspaceMenuSectionState(
                selection: .noWindow,
                groups: [
                    WorkspaceGroupMenuEntry(id: groupID, name: "Product", isActive: false),
                ],
                hasActiveWorkspace: false,
                activeWorkspaceHasNoGroup: true
            )
        )

        let fallback = try XCTUnwrap(menu.items.first { $0.tag == MainMenuTag.workspaceUnavailable })
        XCTAssertEqual(fallback.title, "No Workspace Window")
        XCTAssertFalse(fallback.isEnabled)

        let groupHeader = try XCTUnwrap(menu.items.first { $0.tag == AppCommandMenuTag.workspaceGroupActiveHeader })
        let groupMenu = try XCTUnwrap(groupHeader.submenu)
        let noGroup = groupMenu.items[0]
        XCTAssertEqual(noGroup.representedObject as? MainMenuExplicitRole, .assignActiveWorkspaceToNoGroup)
        XCTAssertEqual(noGroup.state, .on)
        XCTAssertFalse(noGroup.isEnabled)

        let group = try XCTUnwrap(groupMenu.items.first { $0.representedObject as? Group.ID == groupID })
        XCTAssertFalse(group.isEnabled)

        let newGroup = try XCTUnwrap(
            groupMenu.items.first { $0.representedObject as? MainMenuExplicitRole == .newGroupForActiveWorkspace }
        )
        XCTAssertFalse(newGroup.isEnabled)
    }

    func testDictationLanguageSectionBuildsStableSubmenu() throws {
        let menu = NSMenu(title: "Sound")

        DictationLanguageMenuSectionBuilder(target: target, actions: target.actions).rebuild(
            soundMenu: menu,
            state: DictationLanguageMenuSectionState(entries: [
                DictationLanguageMenuEntry(title: "English", rawValue: "en-US", isSelected: true),
                DictationLanguageMenuEntry(title: "Portuguese", rawValue: "pt-BR", isSelected: false),
            ])
        )

        let header = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(header.identifier, MainMenuBuilder.identifier(for: .dictationLanguage))
        XCTAssertEqual(header.representedObject as? MainMenuDynamicSectionID, .dictationLanguage)
        XCTAssertEqual(header.tag, MainMenuTag.soundDictationLanguage)

        let languageMenu = try XCTUnwrap(header.submenu)
        XCTAssertEqual(languageMenu.identifier, MainMenuBuilder.identifier(for: .dictationLanguage))
        XCTAssertEqual(languageMenu.items.map(\.title), ["English", "Portuguese"])
        XCTAssertEqual(languageMenu.items.map { $0.representedObject as? String }, ["en-US", "pt-BR"])
        XCTAssertEqual(languageMenu.items.map(\.state), [.on, .off])
        XCTAssertEqual(languageMenu.items.map(\.action), [
            #selector(DynamicMenuSectionTarget.selectVoiceInputLanguage(_:)),
            #selector(DynamicMenuSectionTarget.selectVoiceInputLanguage(_:)),
        ])
        XCTAssertTrue(languageMenu.items.allSatisfy { $0.target === target })
    }
}

private final class DynamicMenuSectionTarget: NSObject {
    var actions: MainMenuDynamicActionSelectors {
        MainMenuDynamicActionSelectors(
            dispatchAppCommand: #selector(dispatchAppCommand(_:)),
            selectWorkspaceByTag: #selector(selectWorkspaceByTag(_:)),
            moveFocusedPaneToWorkspaceByTag: #selector(moveFocusedPaneToWorkspaceByTag(_:)),
            assignActiveWorkspaceToGroup: #selector(assignActiveWorkspaceToGroup(_:)),
            newGroupForActiveWorkspace: #selector(newGroupForActiveWorkspace(_:)),
            selectVoiceInputLanguage: #selector(selectVoiceInputLanguage(_:))
        )
    }

    @objc func dispatchAppCommand(_ sender: Any?) {}
    @objc func selectWorkspaceByTag(_ sender: Any?) {}
    @objc func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {}
    @objc func assignActiveWorkspaceToGroup(_ sender: Any?) {}
    @objc func newGroupForActiveWorkspace(_ sender: Any?) {}
    @objc func selectVoiceInputLanguage(_ sender: Any?) {}
}
