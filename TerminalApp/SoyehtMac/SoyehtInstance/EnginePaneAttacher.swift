import Foundation
import SoyehtCore
import os

/// Creates (or idempotently reattaches to) a broker-owned local PTY session
/// on this Mac's own embedded engine and wires a terminal view to it over
/// WebSocket — the shared mechanics behind both the first-attach path
/// (`SoyehtMainWindowController.attachEnginePane`, A1) and the
/// app-relaunch restore path (`PaneViewController.restoreEnginePaneIfNeeded`,
/// A3).
///
/// The engine's `POST /terminals/local` is idempotent per `conversation_id`
/// (see `handlers_terminal.rs`): a live session is returned as-is, a dead or
/// never-created one is spawned fresh. That means restore doesn't need to
/// distinguish "reattach" from "spawn new" itself — the same call handles
/// both — but it also means the client has no signal to tell which one
/// happened (the response shape is identical either way).
@MainActor
enum EnginePaneAttacher {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "engine-pane-attacher")

    /// Returns `false` on ANY failure (no local engine context, network
    /// error) — callers must fall back to `NativePTY` unconditionally, since
    /// the persistent-panes flag must never leave a pane dead.
    static func attach(
        conversation: Conversation,
        cwd: URL,
        loginPath: String?,
        cols: Int,
        rows: Int,
        terminalView: MacOSWebSocketTerminalView,
        convStore: ConversationStore
    ) async -> Bool {
        guard let context = await LocalEngineContext.resolve() else {
            logger.warning("no local engine context resolvable")
            return false
        }
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: loginPath,
            cols: cols,
            rows: rows
        )
        do {
            let response = try await SoyehtAPIClient.shared.createLocalTerminal(request, context: context)
            let attachment = SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment(
                conversationId: response.conversationId,
                context: context
            )
            // Flip commander BEFORE configuring the terminal so
            // `updateEmptyStateVisibility` sees a live instance immediately.
            convStore.updateCommander(conversation.id, commander: .engineLocal(conversationID: response.conversationId))
            terminalView.configure(wsUrl: attachment.url, cookieHeader: attachment.cookieHeader)
            return true
        } catch {
            logger.error("createLocalTerminal failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
