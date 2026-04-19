import Foundation
import SoyehtCore

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

    /// Cached container id used when starting a session without a user-picked
    /// instance (e.g. the `bash` quick-start from `EmptyPaneSessionPickerView`).
    /// Populated by `resolveDefaultContainer()` on first use, then reused.
    static var defaultContainer: String?

    enum ContainerError: Error, LocalizedError {
        case noInstancesAvailable
        var errorDescription: String? {
            switch self {
            case .noInstancesAvailable:
                return "Nenhuma instância disponível. Configure uma no servidor antes de iniciar uma sessão."
            }
        }
    }

    /// Resolve the default container. Uses the in-memory cache first, falls
    /// back to `SessionStore.shared.loadInstances()` (populated at login),
    /// and finally hits `SoyehtAPIClient.getInstances()` as a last resort.
    /// Throws `ContainerError.noInstancesAvailable` when everything is empty.
    static func resolveDefaultContainer() async throws -> String {
        if let cached = defaultContainer { return cached }

        let cached = SessionStore.shared.loadInstances()
        if let container = cached.first(where: { $0.isOnline })?.container
            ?? cached.first?.container {
            defaultContainer = container
            return container
        }

        let fetched = try await SoyehtAPIClient.shared.getInstances()
        guard let container = fetched.first(where: { $0.isOnline })?.container
            ?? fetched.first?.container else {
            throw ContainerError.noInstancesAvailable
        }
        defaultContainer = container
        return container
    }
}
