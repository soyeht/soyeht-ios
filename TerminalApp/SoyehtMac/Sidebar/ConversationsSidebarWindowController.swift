import AppKit

/// Separate window (1100×920) hosting the Conversations Sidebar.
/// Activated via Window → Conversations / ⌘⇧C.
@MainActor
final class ConversationsSidebarWindowController: NSWindowController {

    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore

    init(workspaceStore: WorkspaceStore, conversationStore: ConversationStore) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Conversations"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 600)
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier(kSidebarWindowIdentifier)
        window.isRestorable = true
        window.restorationClass = SoyehtWindowRestoration.self

        super.init(window: window)

        let split = ConversationsSidebarSplitController(
            workspaceStore: workspaceStore,
            conversationStore: conversationStore
        )
        window.contentViewController = split
    }

    required init?(coder: NSCoder) { fatalError() }
}
