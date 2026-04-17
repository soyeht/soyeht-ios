import Foundation

/// Process-wide weak references to the stores the AppDelegate owns.
/// Set once at `applicationDidFinishLaunching`; read by view controllers
/// that need to look up conversations/workspaces without plumbing the
/// stores through every init.
///
/// This is intentionally narrow — it's not a DI container. If a type truly
/// owns a store relationship (e.g. `SoyehtMainWindowController`), it takes
/// the store directly. This indirection exists only for leaf UI like
/// `PaneViewController` where threading the stores through would noise up
/// every init without real benefit.
@MainActor
enum AppEnvironment {
    static weak var workspaceStore: WorkspaceStore?
    static weak var conversationStore: ConversationStore?
}
