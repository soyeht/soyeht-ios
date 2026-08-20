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
        ///
        /// `transient` distinguishes "worth retrying" (a network hiccup or
        /// 5xx — the engine is a persistent daemon, so on restore the
        /// session almost certainly still exists) from "not" (no engine
        /// context at all, or a definitive 4xx) — restore uses this to
        /// decide whether a blip should downgrade the pane to `.native`
        /// immediately or retry first. First-attach (a brand-new pane,
        /// never expected to already have a live session) ignores it.
        case failed(transient: Bool)
        /// Attached successfully. `reconnected` (E5) is `true` only when an
        /// existing live session was returned as-is, `false` when a new
        /// process had to be spawned — say "session restored" only in the
        /// former case.
        case attached(reconnected: Bool)
    }

    /// HTTP status codes worth retrying (server-side hiccup) — a 4xx means
    /// the request itself was rejected and retrying it verbatim won't help.
    private static let transientHTTPStatusCodes = 500...599

    private static func isTransient(_ error: Error) -> Bool {
        if case SoyehtAPIClient.APIError.httpError(let status, _) = error {
            return transientHTTPStatusCodes.contains(status)
        }
        // One vocabulary for "nothing answered", shared with
        // `LocalEngineContext`, so the two cannot drift apart.
        return LocalEngineContext.isNotAnsweringYet(error)
    }

    static func attach(
        conversation: Conversation,
        launchNonce: String? = nil,
        cwd: URL,
        loginPath: String?,
        cols: Int,
        rows: Int,
        terminalView: MacOSWebSocketTerminalView,
        convStore: ConversationStore
    ) async -> AttachOutcome {
        let context: ServerContext
        switch await LocalEngineContext.resolveDetailed() {
        case .resolved(let resolved):
            context = resolved
        case .engineNotAnsweringYet:
            // MEASURED on a cold boot: the app asked 31 seconds before launchd
            // started the engine. The previous version returned
            // `transient: false` here, under a comment claiming "we don't even
            // have credentials to retry with" — a cause it never checked. The
            // retry machinery downstream was correct and complete; it was
            // simply never armed, because the one failure that actually
            // happens at login was classified as permanent.
            logger.warning("local engine not answering yet; worth waiting for")
            return .failed(transient: true)
        case .unavailable:
            logger.warning("no local engine context resolvable")
            return .failed(transient: false)
        }
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: loginPath,
            cols: cols,
            rows: rows,
            launchNonce: launchNonce
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
            // live GET /terminals/local per automation request. Keyed by
            // the engine's own echoed conversation_id (not re-derived from
            // `conversation.id.uuidString`), matching what
            // `record`/`remove` are keyed by everywhere else.
            EngineSessionTTYRegistry.record(
                conversationID: response.conversationId,
                slaveTTYPath: response.slaveTTYPath
            )
            return .attached(reconnected: response.reconnected)
        } catch {
            logger.error("createLocalTerminal failed: \(error.localizedDescription, privacy: .public)")
            return .failed(transient: isTransient(error))
        }
    }
}
