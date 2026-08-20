import XCTest
@testable import SoyehtMacDomain

/// A3 acceptance ("closing and reopening the app reconnects to the same
/// live pane") lives in `PaneViewController`/`SoyehtMainWindowController`,
/// both AppKit-bound (subclass `NSViewController`/`NSWindowController`,
/// reference `MacOSWebSocketTerminalView` which subclasses SwiftTerm's
/// AppKit `TerminalView`) and so cannot be compiled into the AppKit-free
/// `SoyehtMacDomain` test target. These are source-guard tests (same
/// pattern as `AppCommandRoutingPresentationTests`): they assert on the
/// actual source text rather than executing it, to pin the restore wiring
/// without pulling AppKit into this package.
final class PersistentPanesRestoreSourceGuardTests: XCTestCase {
    func testRebindFromStoreCallsBothRestorePaths() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let rebind = try slice(
            source,
            from: "private func rebindFromStore()",
            to: "private func configureContent(for conv: Conversation)"
        )
        XCTAssertTrue(rebind.contains("restoreLocalShellIfNeeded(for: conv)"))
        XCTAssertTrue(rebind.contains("restoreEnginePaneIfNeeded(for: conv)"))
    }

    func testRestoreEnginePaneGuardsAndFallsBackToNativePTY() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let restore = try slice(
            source,
            from: "private func restoreEnginePaneIfNeeded(for conv: Conversation)",
            to: "private func stillRestorableEngineConversation("
        )
        // Only engineLocal panes with no live WS session, not re-entrant.
        XCTAssertTrue(restore.contains("case .engineLocal(let initialEngineConversationID) = conv.commander"))
        XCTAssertTrue(restore.contains("!terminalView.isRemoteSessionConfigured"))
        XCTAssertTrue(restore.contains("!isRestoringLocalShell"))
        // Reuses the shared attacher rather than reimplementing create+attach.
        XCTAssertTrue(restore.contains("EnginePaneAttacher.attach("))
        // E5 honesty: must distinguish an actual reconnect from a silent
        // fresh respawn, never claim "restored" for the latter.
        XCTAssertTrue(restore.contains("case .attached(reconnected: true):"))
        XCTAssertTrue(restore.contains("case .attached(reconnected: false):"))
        // Never leaves the pane dead if the engine can't be reached.
        XCTAssertTrue(restore.contains("NativePTY("))
        XCTAssertTrue(restore.contains(".native(pid: pty.pid)"))

        // FIX-1 (independent review): a transient failure must retry with
        // backoff before downgrading to .native, or a blip permanently
        // orphans the live engine session (next relaunch only looks for
        // .engineLocal).
        XCTAssertTrue(restore.contains("restoreRetryDelaysNanoseconds"))
        XCTAssertTrue(restore.contains("case .failed(transient: true) = outcome"))
        XCTAssertTrue(restore.contains("Task.sleep(nanoseconds:"))
        // Best-effort delete before falling back, in case a request that
        // looked failed to us actually succeeded engine-side (lost
        // response) — must not leave that orphaned.
        XCTAssertTrue(restore.contains("bestEffortDeleteEngineSession(engineConversationID: initialEngineConversationID)"))

        // FIX-2 (independent review, TOCTOU): every await gap must
        // re-validate before acting — the pane/workspace can close mid-
        // flight (endEngineSessionIfNeeded already deleted the session).
        let awaitCount = restore.components(separatedBy: "await ").count - 1
        let revalidateCount = restore.components(separatedBy: "stillRestorableEngineConversation(").count - 1
        XCTAssertGreaterThanOrEqual(
            revalidateCount, 3,
            "expected re-validation after the login-PATH await, after each retry backoff, and after the attach loop"
        )
        XCTAssertGreaterThan(awaitCount, 0)
    }

    func testStillRestorableEngineConversationChecksIdentityStoreAndCommander() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let helper = try slice(
            source,
            from: "private func stillRestorableEngineConversation(",
            to: "private static func bestEffortDeleteEngineSession("
        )
        XCTAssertTrue(helper.contains("LivePaneRegistry.shared.pane(for: conversationID) === self"))
        XCTAssertTrue(helper.contains("convStore.conversation(conversationID)"))
        XCTAssertTrue(helper.contains("case .engineLocal = conversation.commander"))
    }

    func testBestEffortDeleteEngineSessionClearsRegistryAndNeverThrows() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let helper = try slice(
            source,
            from: "private static func bestEffortDeleteEngineSession(",
            to: "// MARK: - Header wiring"
        )
        // FIX-3 (independent review): the registry is keyed by the
        // engine's own echoed conversation_id, stored on
        // .engineLocal(conversationID:) — not conversation.id.uuidString.
        // Cleaning it up here uses the same caller-supplied value.
        XCTAssertTrue(helper.contains("EngineSessionTTYRegistry.remove(conversationID: engineConversationID)"))
        XCTAssertTrue(helper.contains("try? await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)"))
    }

    /// FIX-1 (independent review): retry-worthiness must be a real
    /// classification, not a blanket "everything is transient" — a
    /// definitive 4xx (bad request, auth failure) should fail fast to the
    /// `NativePTY` fallback rather than waste ~3.5s of retries.
    func testAttachOutcomeClassifiesTransientFailuresBeforeRetrying() throws {
        let source = try macSource("SoyehtInstance/EnginePaneAttacher.swift")
        let attacher = try slice(
            source,
            from: "enum EnginePaneAttacher",
            to: "static func attach("
        )
        XCTAssertTrue(attacher.contains("case failed(transient: Bool)"))
        XCTAssertTrue(attacher.contains("500...599"))
        XCTAssertTrue(attacher.contains("case SoyehtAPIClient.APIError.httpError(let status, _) = error"))
        // No local engine context at all is definitive, not transient —
        // retrying without credentials can't help.
        let attach = try slice(
            source,
            from: "static func attach(",
            to: "}\n}"
        )
        XCTAssertTrue(attach.contains("return .failed(transient: false)"))
    }

    func testFirstAttachAndRestoreShareTheSameEngineAttachMechanics() throws {
        let mainWindowSource = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attachEnginePane = try slice(
            mainWindowSource,
            from: "private func attachEnginePane(",
            to: "private func initialPromptPayload("
        )
        XCTAssertTrue(attachEnginePane.contains("EnginePaneAttacher.attach("))
        // Not reimplementing createLocalTerminal/buildLocalTerminalWebSocketAttachment
        // directly here — that would let the two call sites drift.
        XCTAssertFalse(attachEnginePane.contains("SoyehtAPIClient.shared.createLocalTerminal"))
    }

    func testEnginePaneAttacherWiresContextRequestAndAttachmentInOrder() throws {
        let source = try macSource("SoyehtInstance/EnginePaneAttacher.swift")
        let attach = try slice(
            source,
            from: "static func attach(",
            to: "}\n}"
        )
        // `resolveDetailed`, not `resolve()`: the plain form collapses "nothing
        // answered yet" and "there is nothing" into one `nil`, and the caller
        // then has to guess. It guessed wrong — measured on a cold boot, the
        // engine arrived 31s after the app asked, and every restored pane was
        // downgraded to an in-process PTY for the session.
        XCTAssertTrue(attach.contains("LocalEngineContext.resolveDetailed()"))
        XCTAssertTrue(attach.contains("case .engineNotAnsweringYet:"),
                      "o attacher tem de distinguir 'ainda não respondeu' de 'não há'")
        XCTAssertTrue(attach.contains("return .failed(transient: true)"),
                      "'ainda não respondeu' tem de armar a repetição a jusante, que já existe e estava correta")
        XCTAssertTrue(attach.contains("EnginePaneSpawnRequestBuilder.makeCreateRequest("))
        XCTAssertTrue(attach.contains("SoyehtAPIClient.shared.createLocalTerminal("))
        XCTAssertTrue(attach.contains("SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment("))
        XCTAssertTrue(attach.contains("convStore.updateCommander(conversation.id, commander: .engineLocal(conversationID: response.conversationId))"))
        XCTAssertTrue(attach.contains("terminalView.configure("))
        XCTAssertTrue(attach.contains("wsUrl: attachment.url"))
        XCTAssertTrue(attach.contains("cookieHeader: attachment.cookieHeader"))
        // .mirror is never handoff-eligible — only this call site (used by
        // both A1 first-attach and A3 restore) may claim the pane as one.
        XCTAssertTrue(attach.contains("isLocalHandoffSource: true"))
        // E5: the response's `reconnected` flag must actually reach the
        // caller (via `.attached(reconnected:)`), not get silently dropped.
        XCTAssertTrue(attach.contains("return .attached(reconnected: response.reconnected)"))
        // A5: caches the TTY path so automation TTY-mapping can resolve
        // this pane without a live GET /terminals/local round-trip.
        XCTAssertTrue(attach.contains("EngineSessionTTYRegistry.record("))
    }

    func testIsRemoteSessionConfiguredTracksConfiguredURL() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let property = try slice(
            source,
            from: "var isRemoteSessionConfigured: Bool",
            to: "func localReplaySnapshot"
        )
        XCTAssertTrue(property.contains("configuredURL != nil"))
    }

    // MARK: - Helpers (same pattern as AppCommandRoutingPresentationTests)

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
    // MARK: - Uma pane native morta é reconstruída no broker
    //
    // MEDIDO na máquina do dono, 2026-08-20: 30 panes gravadas `.native`, e
    // cada relançamento recriava fielmente todas elas dentro do processo da
    // app — por isso cada fecho e cada atualização voltava a matá-las. Uma
    // única despromoção, meses de consequências. O comentário do restauro do
    // engine já dizia "stays `.native` until the user recreates it": o
    // comportamento estava documentado, só não estava reconhecido como o que
    // mantinha as pessoas frágeis para sempre.
    //
    // O que torna a promoção gratuita: no restauro o shell antigo JÁ MORREU
    // com o processo da app. Não se migra nada.

    func testRestoringANativePaneTriesTheBrokerBeforeRebuildingItInProcess() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let restore = try slice(
            source,
            from: "private func restoreLocalShellIfNeeded(",
            to: "private static let restoreRetryDelaysNanoseconds"
        )
        guard let attemptAt = restore.range(of: "upgradedRestoredPaneToEngine("),
              let nativeAt = restore.range(of: "let pty = try NativePTY(") else {
            return XCTFail("o restauro de uma pane native deixou de ter uma das duas metades")
        }
        XCTAssertLessThan(attemptAt.lowerBound, nativeAt.lowerBound,
                          "a tentativa no broker tem de PRECEDER a reconstrução em processo; a seguir a ela não serve de nada")

        // A CONDIÇÃO, não só a chamada. A primeira versão desta guarda exigia
        // apenas que a chamada existisse — e um mutante que trocasse a guarda
        // por `if false` passava verde com o comportamento morto. Presença não
        // é efeito.
        XCTAssertTrue(restore.contains("if SoyehtFeatureFlags.persistentLocalPanesEnabled,"),
                      "a promoção só pode estar atrás da flag de panes persistentes; qualquer outra condição desliga-a em silêncio")
        // E quando resulta, o caminho nativo não pode correr também: tem de
        // haver um `return` ENTRE a tentativa e a construção da PTY.
        let between = String(restore[attemptAt.upperBound..<nativeAt.lowerBound])
        XCTAssertTrue(between.contains("return"),
                      "sem um return entre as duas, uma promoção bem-sucedida seria seguida de uma PTY nativa por cima")
    }

    /// Fail-open: qualquer falha tem de cair na PTY nativa. Uma promoção que
    /// deixasse a pane morta seria pior do que a fragilidade que corrige.
    func testTheUpgradeNeverLeavesThePaneDead() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let attempt = try slice(
            source,
            from: "private func upgradedRestoredPaneToEngine(",
            to: "private func stillRestorableNativeConversation("
        )
        XCTAssertEqual(attempt.components(separatedBy: "return false").count - 1, 3,
                       "as três saídas de falha (sem store, sem pane viva, attach falhado) têm de devolver false para o chamador reconstruir")
        guard let attachedAt = attempt.range(of: "guard case .attached = outcome else { return false }"),
              let successAt = attempt.range(of: "return true") else {
            return XCTFail("a promoção deixou de exigir um attach bem-sucedido antes de reclamar sucesso")
        }
        // ORDEM, não presença. Um `return true` colocado ANTES do guard deixa
        // a asserção de presença verde e promove uma pane que nunca ligou —
        // medido com mutante na primeira versão desta guarda.
        XCTAssertLessThan(attachedAt.lowerBound, successAt.lowerBound,
                          "o único `return true` tem de vir DEPOIS do guard; antes dele reclama sucesso sem attach")
        XCTAssertEqual(attempt.components(separatedBy: "return true").count - 1, 1,
                       "um só caminho pode reclamar sucesso")
    }

    /// A promoção só olha para panes `.native`, e o restauro do engine só para
    /// `.engineLocal`. Se um dos dois passar a aceitar o tipo do outro, os dois
    /// caminhos correm sobre a mesma pane.
    func testTheTwoRestorePathsNeverClaimTheSameKind() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let native = try slice(
            source,
            from: "private func stillRestorableNativeConversation(",
            to: "private func stillRestorableEngineConversation("
        )
        let engine = try slice(
            source,
            from: "private func stillRestorableEngineConversation(",
            to: "/// Best-effort cleanup"
        )
        XCTAssertTrue(native.contains("case .native = conversation.commander"))
        XCTAssertFalse(native.contains("case .engineLocal"))
        XCTAssertTrue(engine.contains("case .engineLocal = conversation.commander"))
        XCTAssertFalse(engine.contains("case .native"))
    }

}
