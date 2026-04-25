import XCTest
@testable import SoyehtMacDomain

final class AppCommandRegistryTests: XCTestCase {

    func testRegistryHasNoDuplicateShortcutsPerContext() {
        let conflicts = AppCommandRegistry.duplicateShortcuts()
        XCTAssertTrue(
            conflicts.isEmpty,
            "Duplicate shortcuts: \(conflicts.map { "\($0.context.rawValue): \($0.commandIDs)" })"
        )
    }

    func testExpectedAppAndPaneShortcuts() {
        XCTAssertEqual(shortcut(.newWindow), AppCommandShortcut(.character("n"), modifiers: [.command]))
        XCTAssertEqual(shortcut(.newConversation), AppCommandShortcut(.character("t"), modifiers: [.command]))
        XCTAssertEqual(shortcut(.showCommandPalette), AppCommandShortcut(.character("p"), modifiers: [.command]))
        XCTAssertEqual(shortcut(.showPairedDevices), AppCommandShortcut(.character("d"), modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.showClawStore), AppCommandShortcut(.character("s"), modifiers: [.command, .option]))

        XCTAssertEqual(shortcut(.focusPaneLeft), AppCommandShortcut(.special(.leftArrow), modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.focusPaneRight), AppCommandShortcut(.special(.rightArrow), modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.toggleZoomFocusedPane), AppCommandShortcut(.character("z"), modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.swapPaneUp), AppCommandShortcut(.special(.upArrow), modifiers: [.option, .shift]))
        XCTAssertEqual(shortcut(.rotateFocusedSplit), AppCommandShortcut(.character("r"), modifiers: [.option, .shift]))
    }

    func testWorkspaceTagShortcuts() {
        XCTAssertEqual(shortcut(.selectWorkspace(1)), AppCommandShortcut(.character("1"), modifiers: [.command]))
        XCTAssertEqual(shortcut(.selectWorkspace(9)), AppCommandShortcut(.character("9"), modifiers: [.command]))
        XCTAssertEqual(shortcut(.toggleWorkspaceSelection(4)), AppCommandShortcut(.character("4"), modifiers: [.command, .option]))
        XCTAssertEqual(shortcut(.moveFocusedPaneToWorkspace(7)), AppCommandShortcut(.character("7"), modifiers: [.control, .option]))
        XCTAssertEqual(shortcut(.moveActiveWorkspaceLeft), AppCommandShortcut(.character("["), modifiers: [.command, .control]))
        XCTAssertEqual(shortcut(.moveActiveWorkspaceRight), AppCommandShortcut(.character("]"), modifiers: [.command, .control]))
    }

    func testPaneGridLookupUsesAppRegistry() {
        XCTAssertEqual(
            command(
                keyCode: AppCommandSpecialKey.leftArrow.virtualKeyCode,
                characters: nil,
                modifiers: [.command, .shift],
                context: .paneGrid
            )?.id,
            .focusPaneLeft
        )
        XCTAssertEqual(
            command(
                keyCode: AppCommandSpecialKey.downArrow.virtualKeyCode,
                characters: nil,
                modifiers: [.option, .shift],
                context: .paneGrid
            )?.id,
            .swapPaneDown
        )
        XCTAssertEqual(
            command(keyCode: 0, characters: "z", modifiers: [.command, .shift], context: .paneGrid)?.id,
            .toggleZoomFocusedPane
        )
    }

    func testRemovedTmuxShortcutsAreNotAppCommands() {
        for context in AppCommandContext.allCases {
            XCTAssertNil(command(keyCode: 0, characters: "s", modifiers: [.command, .shift], context: context))
            XCTAssertNil(command(keyCode: 0, characters: "h", modifiers: [.command, .shift], context: context))
            XCTAssertNil(command(keyCode: 0, characters: "x", modifiers: [.command, .shift], context: context))
            XCTAssertNil(command(keyCode: 0, characters: " ", modifiers: [.command, .shift], context: context))
        }
    }

    private func shortcut(_ id: AppCommandID) -> AppCommandShortcut? {
        AppCommandRegistry.command(id)?.shortcut
    }

    private func command(
        keyCode: UInt16,
        characters: String?,
        modifiers: AppCommandModifier,
        context: AppCommandContext
    ) -> AppCommand? {
        AppCommandRegistry.command(
            matchingKeyCode: keyCode,
            charactersIgnoringModifiers: characters,
            modifiers: modifiers,
            in: context
        )
    }
}
