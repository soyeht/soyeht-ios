import Foundation

/// In-memory `conversation_id -> slave_tty_path` map for engine-owned
/// (`.engineLocal`) panes, populated whenever `EnginePaneAttacher.attach`
/// succeeds and cleared when a session ends.
///
/// Exists so `SoyehtAutomationRequestRouter.resolveAutomationSource`'s
/// TTY-mapping fallback can resolve an `.engineLocal` pane synchronously,
/// the same way it already resolves `.native` via `NativePTY.slaveTTYPath`
/// — without a live network round-trip per automation request, and without
/// cascading `async` through `automationWindowForSource`/
/// `automationTargetWindow`, which sit under most of that router's ~20
/// handlers and are synchronous today. The engine already hands us this
/// path in the create response (E5, `slave_tty_path`); remembering it here
/// is simpler and more robust than querying `GET /terminals/local` on
/// every TTY-based automation lookup.
@MainActor
enum EngineSessionTTYRegistry {
    private static var ttyByConversationID: [String: String] = [:]

    static func record(conversationID: String, slaveTTYPath: String) {
        guard !slaveTTYPath.isEmpty else { return }
        ttyByConversationID[conversationID] = slaveTTYPath
    }

    static func slaveTTYPath(forConversationID conversationID: String) -> String? {
        ttyByConversationID[conversationID]
    }

    static func remove(conversationID: String) {
        ttyByConversationID.removeValue(forKey: conversationID)
    }
}
