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
/// both — and (E5) the response's `reconnected` field tells the caller
/// which one actually happened, for honest logging.
@MainActor
enum EnginePaneAttacher {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "engine-pane-attacher")

    enum AttachOutcome: Equatable {
        /// No local engine context, or the create/attach call failed.
        /// Callers must fall back to `NativePTY` unconditionally — the
        /// persistent-panes flag must never leave a pane dead.
        case failed
        /// Attached successfully. `reconnected` (E5) is `true` only when an
        /// existing live session was returned as-is, `false` when a new
        /// process had to be spawned — say "session restored" only in the
        /// former case.
        case attached(reconnected: Bool)
    }

    static func attach(
        conversation: Conversation,
        cwd: URL,
        loginPath: String?,
        cols: Int,
        rows: Int,
        terminalView: MacOSWebSocketTerminalView,
        convStore: ConversationStore
    ) async -> AttachOutcome {
        guard let context = await LocalEngineContext.resolve() else {
            logger.warning("no local engine context resolvable")
            return .failed
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
            terminalView.configure(
                wsUrl: attachment.url,
                cookieHeader: attachment.cookieHeader,
                isLocalHandoffSource: true
            )
            // Lets automation TTY-mapping resolve this pane the same way it
            // already does for `.native` (NativePTY.slaveTTYPath) — see
            // `EngineSessionTTYRegistry`'s doc comment for why this beats a
            // live GET /terminals/local per automation request.
            EngineSessionTTYRegistry.record(
                conversationID: response.conversationId,
                slaveTTYPath: response.slaveTTYPath
            )
            return .attached(reconnected: response.reconnected)
        } catch {
            logger.error("createLocalTerminal failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
