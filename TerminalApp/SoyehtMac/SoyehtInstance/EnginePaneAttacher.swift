import Foundation
import SoyehtCore
import os

/// Attaches local panes through this Mac's engine. Known supervised sessions
/// restore through GET with an exact instance check. New execution uses a
/// durable creation intent; an uncertain response preserves that intent.
/// Legacy engine-owned sessions remain an explicit migration path.
@MainActor
enum EnginePaneAttacher {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "engine-pane-attacher")

    enum AttachOutcome: Equatable {
        /// No execution was submitted and no supervised ownership is known.
        /// The caller may retry, but must not select another backend silently.
        case failed(transient: Bool)
        /// A supervised session or uncertain CREATE already belongs to this
        /// pane. Preserve that ownership; never substitute a NativePTY.
        case preserved(retryable: Bool, message: String)
        /// Attached successfully. `reconnected` (E5) is `true` only when an
        /// existing live session was returned as-is, `false` when a new
        /// process had to be spawned — say "session restored" only in the
        /// former case.
        case attached(reconnected: Bool)
    }

    /// Compatibility for generic legacy errors. Supervised errors are typed
    /// before this rule, so unknown protocol failures never retry as 5xx.
    private static let transientHTTPStatusCodes = 500...599

    private static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? SoyehtAPIClient.LocalTerminalFailure {
            return failure == .unavailable
        }
        if case SoyehtAPIClient.APIError.httpError(let status, _) = error {
            return transientHTTPStatusCodes.contains(status)
        }
        // One vocabulary for "nothing answered", shared with
        // `LocalEngineContext`, so the two cannot drift apart.
        return LocalEngineContext.isNotAnsweringYet(error)
    }

    private static func isAuthenticationRejection(_ error: Error) -> Bool {
        guard case SoyehtAPIClient.APIError.httpError(let status, _) = error else { return false }
        return status == 401 || status == 403
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
        let current = convStore.conversation(conversation.id) ?? conversation
        func unresolved(_ retryable: Bool) -> AttachOutcome {
            if current.commander.requiresEngineSessionPreservation || convStore.conversation(conversation.id)?.commander.requiresEngineSessionPreservation == true {
                return .preserved(retryable: retryable, message: SoyehtAPIClient.LocalTerminalFailure.unavailable.localizedDescription)
            }
            return .failed(transient: retryable)
        }
        var context: ServerContext
        switch await LocalEngineContext.resolveDetailed() {
        case .resolved(let resolved):
            context = resolved
        case .engineNotAnsweringYet:
            // launchd may start the engine after the pane attempts to attach.
            // No response warrants another attempt; it proves neither missing
            // credentials nor the end of an existing terminal session.
            logger.warning("local engine not answering yet; worth waiting for")
            return unresolved(true)
        case .unavailable:
            logger.warning("no local engine context resolvable")
            return unresolved(false)
        }
        let expectedInstance = current.commander.engineSessionInstanceID
        guard convStore.conversation(conversation.id)?.commander == current.commander else {
            return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.instanceMismatch.localizedDescription)
        }
        var issuedIntent = current.commander.engineCreationIntentID
        var refreshedForIssuance = false
        while expectedInstance == nil && issuedIntent == nil {
            do {
                let issued = try await SoyehtAPIClient.shared.issueLocalTerminalIntent(conversationId: conversation.id.uuidString, context: context)
                // The explicit legacy backend does not consume tickets. Keep
                // its pending-request marker without impersonating issuance.
                issuedIntent = issued.intentId ?? UUID().uuidString
            } catch {
                if !refreshedForIssuance, isAuthenticationRejection(error) {
                    refreshedForIssuance = true
                    LocalEngineContext.invalidateVerification(context)
                    if case .resolved(let refreshed) = await LocalEngineContext.resolveDetailed() {
                        context = refreshed
                        continue
                    }
                }
                logger.error("terminal intent issuance failed cause=\(String(describing: error), privacy: .public)")
                return unresolved(isTransient(error))
            }
        }
        guard convStore.conversation(conversation.id)?.commander == current.commander else {
            return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.instanceMismatch.localizedDescription)
        }
        let creationIntent = issuedIntent ?? UUID().uuidString
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: loginPath,
            cols: cols,
            rows: rows,
            launchNonce: launchNonce,
            creationIntentID: creationIntent
        )
        if expectedInstance == nil {
            // Persist the intention before POST: a missing response does not
            // prove the shell failed to start. Retrying retains this intent.
            convStore.updateCommander(conversation.id, commander: .engineLocal(
                conversationID: conversation.id.uuidString, creationIntentID: creationIntent
            ))
            guard AppEnvironment.workspaceStore?.flushPendingSave() == true else {
                return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.stateNotSaved.localizedDescription)
            }
        }
        var retriedAfterCredentialRejection = false
        while true {
          do {
            let response: SoyehtAPIClient.LocalTerminalCreateResponse
            if let expectedInstance {
                response = try await SoyehtAPIClient.shared.restoreLocalTerminal(
                    conversationId: conversation.id.uuidString, sessionInstanceId: expectedInstance, context: context
                )
            } else if launchNonce == nil, current.commander.engineCreationIntentID != nil,
                      let existing = try await pendingSession(request: request, context: context) {
                response = existing
            } else {
                let support = EnginePackager.soyehtSupportDirectory
                let profile = SoyehtInstallProfile.current.kind
                let lease: EngineReplacementJournal.CreationLease
                do {
                    lease = try await Task.detached {
                        try EngineReplacementJournal.acquireCreationLease(
                            directory: EngineReplacementJournal.directory(in: support), profile: profile)
                    }.value
                } catch {
                    logger.notice("terminal CREATE deferred: replacement admission unavailable")
                    return .preserved(retryable: true, message: String(localized: LocalizedStringResource(
                        "engineReplacement.creationBlocked",
                        defaultValue: "Terminal launch is paused while the engine update is unresolved. Resume the engine update to continue.",
                        comment: "A pending engine replacement blocks new execution, while existing sessions can reconnect."
                    )))
                }
                // Retain the shared file lock across the entire asynchronous
                // POST. Scope exit, including throws, releases only the lease;
                // the persisted intent still protects an uncertain CREATE.
                defer { withExtendedLifetime(lease) {} }
                response = try await SoyehtAPIClient.shared.createLocalTerminal(request, context: context)
            }
            let owner = convStore.conversation(conversation.id)?.commander
            let stillOwned = expectedInstance.map { owner?.engineSessionInstanceID == $0 }
                ?? (owner?.engineCreationIntentID == creationIntent)
            guard stillOwned else {
                if let instance = response.sessionInstanceId {
                    try? await SoyehtAPIClient.shared.deleteLocalTerminal(
                        conversationId: response.conversationId, sessionInstanceId: instance, context: context
                    )
                }
                return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.instanceMismatch.localizedDescription)
            }
            let attachment = SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment(
                conversationId: response.conversationId,
                sessionInstanceId: response.sessionInstanceId,
                context: context
            )
            // Flip commander BEFORE configuring the terminal so
            // `updateEmptyStateVisibility` sees a live instance immediately.
            convStore.updateCommander(conversation.id, commander: .engineLocal(
                conversationID: response.conversationId, sessionInstanceID: response.sessionInstanceId,
                creationIntentID: response.sessionInstanceId == nil ? nil : response.intentId
            ))
            guard AppEnvironment.workspaceStore?.flushPendingSave() == true else {
                return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.stateNotSaved.localizedDescription)
            }
            terminalView.configure(
                wsUrl: attachment.url,
                cookieHeader: attachment.cookieHeader,
                isLocalHandoffSource: true,
                sessionInstanceId: response.sessionInstanceId
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
            // A brand-new session behind a reused view must not inherit the
            // previous session's input modes (mouse reporting, kitty
            // keyboard, bracketed paste): the dead TUI that enabled them
            // never restored them, and the new shell receives them as
            // garbage input. A reconnected session keeps running its own
            // TUI, which still owns those modes — leave it untouched.
            if !response.reconnected {
                terminalView.resetInputModesForNewSession()
            }
            return .attached(reconnected: response.reconnected)
          } catch {
            if !retriedAfterCredentialRejection,
               isAuthenticationRejection(error) {
                retriedAfterCredentialRejection = true
                LocalEngineContext.invalidateVerification(context)
                switch await LocalEngineContext.resolveDetailed() {
                case .resolved(let refreshed):
                    context = refreshed
                    continue
                case .engineNotAnsweringYet:
                    return .preserved(retryable: true, message: SoyehtAPIClient.LocalTerminalFailure.unavailable.localizedDescription)
                case .unavailable:
                    logger.error("local terminal credentials unavailable after authentication rejection")
                    return .preserved(retryable: false, message: SoyehtAPIClient.LocalTerminalFailure.rejected(code: "credentials_unavailable").localizedDescription)
                }
            }
            logger.error("local terminal attach failed cause=\(String(describing: error), privacy: .public)")
            return .preserved(retryable: isTransient(error), message: error.localizedDescription)
          }
        }
    }

    private static func pendingSession(request: SoyehtAPIClient.LocalTerminalCreateRequest, context: ServerContext) async throws -> SoyehtAPIClient.LocalTerminalCreateResponse? {
        let existing: SoyehtAPIClient.LocalTerminalSessionMetadata
        do {
            existing = try await SoyehtAPIClient.shared.getLocalTerminal(conversationId: request.conversationId, context: context)
        } catch SoyehtAPIClient.LocalTerminalFailure.sessionMissing {
            return nil
        }
        guard existing.intentId == request.intentId, let instance = existing.sessionInstanceId else {
            throw SoyehtAPIClient.LocalTerminalFailure.instanceMismatch
        }
        return try await SoyehtAPIClient.shared.restoreLocalTerminal(conversationId: request.conversationId, sessionInstanceId: instance, context: context)
    }
}
