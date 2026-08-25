//
//  SoyehtAutomationRequestRouter domain extension
//  Soyeht
//

import Cocoa
import ApplicationServices
import Darwin
import os
import SoyehtCore

@MainActor
extension SoyehtAutomationRequestRouter {
    func handleListAgents(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let wsIDStr = request.payload.workspaceID ?? request.payload.workspaceIDs?.first
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let panes: [SoyehtMainWindowController.ListedPaneResult]
        if wsIDStr == nil, !mainWindowControllers().isEmpty {
            // The MCP 2.0 directory is intentionally global. Proximity is
            // represented by grouping and `isSourceWorkspace`, not by hiding
            // collaborators in other workspaces or windows.
            var seen = Set<Conversation.ID>()
            panes = try mainWindowControllers().flatMap { controller in
                try controller.listPanes(workspaceIDString: nil).panes
            }.filter { seen.insert($0.conversationID).inserted }
        } else if let target {
            panes = try target.listPanes(workspaceIDString: wsIDStr).panes
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            panes = []
        } else {
            panes = try listPanesWithoutActiveWindow(workspaceIDString: wsIDStr)
        }

        let source = try resolveAutomationSource(payload: request.payload)
        let identity = source.map(sourceIdentity)
        let presence = panePresenceByID()
        let agents = panes.map { pane in
            listedAgent(
                pane,
                source: identity,
                presence: presence[pane.conversationID.uuidString]
            )
        }
        let grouped = Dictionary(grouping: agents, by: \.workspaceID)
            .map { workspaceID, members in
                let sortedMembers = members.sorted { lhs, rhs in
                    if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                    return lhs.displayReference.localizedCaseInsensitiveCompare(rhs.displayReference) == .orderedAscending
                }
                return SoyehtAutomationResponse.AgentWorkspaceGroup(
                    workspaceID: workspaceID,
                    workspaceName: members.first?.workspaceName ?? "",
                    isSourceWorkspace: members.first?.isSourceWorkspace ?? false,
                    agentCount: members.count,
                    liveAgentCount: members.filter(\.isLive).count,
                    agents: sortedMembers
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSourceWorkspace != rhs.isSourceWorkspace {
                    return lhs.isSourceWorkspace && !rhs.isSourceWorkspace
                }
                return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
            }

        return SoyehtAutomationResult(
            activeContext: try target.map { try makeActiveContext($0, payload: request.payload) },
            sourceIdentity: identity,
            listedAgents: grouped.flatMap(\.agents),
            agentWorkspaceGroups: grouped
        )
    }

    func listPanesWithoutActiveWindow(
        workspaceIDString: String?
    ) throws -> [SoyehtMainWindowController.ListedPaneResult] {
        let windowByWorkspace = Dictionary(
            mainWindowControllers().flatMap { controller in
                workspaceStore.workspaceOrder(in: controller.windowID).map { ($0, controller.windowID) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let visibleWorkspaceIDs = Set(windowByWorkspace.keys)
        let all: [Conversation]
        if let idStr = workspaceIDString {
            guard let wsID = UUID(uuidString: idStr) else {
                throw SoyehtAutomationError.invalidWorkspaceIDFormat(idStr)
            }
            guard workspaceStore.workspace(wsID) != nil else {
                throw SoyehtAutomationError.workspaceNotFound(wsID)
            }
            guard visibleWorkspaceIDs.contains(wsID) else {
                return []
            }
            all = conversationStore.conversations(in: wsID)
        } else {
            all = conversationStore.all.filter { visibleWorkspaceIDs.contains($0.workspaceID) }
        }
        return all.map {
            SoyehtMainWindowController.ListedPaneResult(
                conversationID: $0.id,
                workspaceID: $0.workspaceID,
                handle: $0.handle,
                path: automationReportPath(for: $0.content, workingDirectoryPath: $0.workingDirectoryPath),
                declaredAgent: $0.content.isTerminal ? $0.agent.rawValue : $0.content.displayKind,
                isActive: false,
                isActiveWorkspace: false,
                windowID: windowByWorkspace[$0.workspaceID]
            )
        }
    }

    /// Thin fallback wrapper: the report token itself lives on PaneContent
    /// (`automationReportPath`) so EVERY wire producer shares one source.
    func automationReportPath(for content: PaneContent, workingDirectoryPath: String?) -> String {
        content.automationReportPath ?? workingDirectoryPath ?? ""
    }

    struct AutomationSourceResolution {
        let conversation: Conversation
        let resolution: String
    }

    struct PanePresence {
        let status: String
        let isLive: Bool
        let isAttachable: Bool
    }

    func automationTTYPath(for conversation: Conversation) -> String? {
        let engineConversationID: String? = {
            if case .engineLocal(let id) = conversation.commander { return id }
            return nil
        }()
        let livePane = LivePaneRegistry.shared.pane(
            for: conversation.id
        ) as? PaneViewController
        return livePane?.terminalView.localPTYSlaveTTYPathForAutomation
            ?? engineConversationID.flatMap {
                EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0)
            }
    }

    func automationTTYDevice(for conversation: Conversation) -> UInt32? {
        guard let ttyPath = automationTTYPath(for: conversation) else {
            return nil
        }
        var metadata = stat()
        guard stat(ttyPath, &metadata) == 0 else { return nil }
        return UInt32(metadata.st_rdev)
    }

    /// A normal managed pane always uses its per-launch nonce. An ordinary
    /// split-created shell additionally proves the active MCP runtime. A shell
    /// whose process predates nonce injection must be recreated: TTY identity
    /// alone cannot authenticate its separate lifecycle reporter hooks.
    func authenticatesAutomationSource(
        _ source: Conversation,
        payload: SoyehtAutomationRequest.Payload
    ) -> Bool {
        var launchCredentialIsValid = PaneStatusTracker.shared
            .validatesLaunchOwnership(paneID: source.id, nonce: payload.nonce)
        guard source.agent.isShell else { return launchCredentialIsValid }
        var runtimeIdentityIsValid = PaneStatusTracker.shared.validatesRuntimeIdentity(
            paneID: source.id,
            agentName: payload.runtimeAgent,
            instanceID: payload.runtimeInstanceID
        )
        if !runtimeIdentityIsValid {
            // A current MCP runtime can outlive an app restart. Its next tool
            // call carries the same PID/instance metadata as an explicit claim,
            // allowing adoption without typing into the user's shell. An MCP
            // process from a pre-feature build carries none of these fields and
            // must be restarted; it cannot be upgraded by code changed on disk.
            guard PaneStatusTracker.shared.runtimeIdentityClaim(for: source.id) == nil,
                  let runtimeAgent = payload.runtimeAgent?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).lowercased(),
                  LocalAgentCatalog.agent(named: runtimeAgent) != nil,
                  let runtimeInstanceID = payload.runtimeInstanceID,
                  !runtimeInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let runtimeProcessID = payload.runtimeProcessID,
                  let expectedTTYDevice = automationTTYDevice(for: source),
                  PaneStatusTracker.shared.claimRuntimeIdentity(
                    paneID: source.id,
                    agentName: runtimeAgent,
                    instanceID: runtimeInstanceID,
                    processID: runtimeProcessID,
                    nonce: payload.nonce,
                    expectedTTYDevice: expectedTTYDevice
                  ) else { return false }
            runtimeIdentityIsValid = true
            launchCredentialIsValid = PaneStatusTracker.shared
                .validatesLaunchOwnership(paneID: source.id, nonce: payload.nonce)
        }
        return runtimeIdentityIsValid && launchCredentialIsValid
    }

    func resolveAutomationSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> AutomationSourceResolution? {
        guard let convStore = AppEnvironment.conversationStore else {
            throw SoyehtAutomationError.missingConversationStore
        }

        if let rawID = payload.sourceConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            guard let id = UUID(uuidString: rawID),
                  let conversation = convStore.conversation(id) else {
                throw SoyehtAutomationError.sourceConversationNotFound(rawID)
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "conversationID")
        }

        if let rawHandle = payload.sourceHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHandle.isEmpty {
            let normalized = ConversationStore.normalize(rawHandle)
            guard let conversation = convStore.all.first(where: { ConversationStore.normalize($0.handle) == normalized }) else {
                throw SoyehtAutomationError.sourceHandleNotFound(ConversationStore.canonicalHandle(rawHandle))
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "handle")
        }

        guard let tty = normalizedTTYName(payload.sourceTTY) else {
            return nil
        }
        for conversation in convStore.all where conversation.content.isTerminal {
            // `.native` panes answer directly (NativePTY.slaveTTYPath).
            // `.engineLocal` has no local PTY object to ask — its TTY path
            // comes from the engine's create response, cached in
            // EngineSessionTTYRegistry when the pane attached (A5; avoids a
            // live GET /terminals/local per automation request). `.mirror`
            // matches neither, same pre-existing limitation as today.
            //
            // Registry lookups MUST key off the engine's own echoed
            // conversation_id, stored on `.engineLocal(conversationID:)` —
            // never re-derive it from `conversation.id.uuidString`. The
            // engine happens to echo that value byte-for-byte today
            // (verified in handlers_terminal.rs), so the two currently
            // agree, but that's an implementation detail of the engine,
            // not a guarantee; record/remove are keyed by the response
            // value everywhere else (EnginePaneAttacher), so the lookup
            // must match.
            let candidateTTY = automationTTYPath(for: conversation)
            guard let paneTTY = normalizedTTYName(candidateTTY), paneTTY == tty else {
                continue
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "tty")
        }
        return nil
    }

    func resolveAuthenticatedAutomationSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> Conversation {
        guard let source = try resolveAutomationSource(payload: payload)?.conversation else {
            throw SoyehtAutomationError.agentMessageSourceRequired
        }
        guard authenticatesAutomationSource(source, payload: payload) else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        return source
    }

    func resolveAuthenticatedAgentReportSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> Conversation {
        guard let source = try resolveAutomationSource(payload: payload)?.conversation else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        guard source.agent.isShell else {
            guard PaneStatusTracker.shared.validatesLaunchOwnership(
                paneID: source.id,
                nonce: payload.nonce
            ) else {
                throw SoyehtAutomationError.unauthenticatedAgentSource
            }
            return source
        }
        let reportSource = payload.reportSource?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let runtimeAgent = PaneStatusTracker.shared.runtimeIdentityClaim(
            for: source.id
        )?.agentName,
              PaneStatusTracker.shared.validatesLaunchOwnership(
                  paneID: source.id,
                  nonce: payload.nonce
              ),
              AgentStateReportAttribution.acceptsAuthenticatedHook(
                  reportSource: reportSource,
                  currentAgent: runtimeAgent
              ) else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        return source
    }

    /// A user grants manager authority to the agent currently authenticated in
    /// a normal shell, not to every future program that may reuse that pane.
    /// Revoke the durable pane grant whenever the runtime instance changes or
    /// exits. If the workspace snapshot cannot be saved, revoke launch
    /// ownership too so stale on-disk authority cannot become usable after a
    /// restart.
    func revokeShellRuntimeOrchestrationAuthorization(
        for source: Conversation
    ) throws {
        guard source.agent.isShell,
              var orchestration = workspaceStore.workspace(source.workspaceID)?.orchestration,
              orchestration.canManageRolesAndTopology(source.id) else { return }
        orchestration.setManagementAuthorization(for: source.id, isAuthorized: false)
        workspaceStore.updateOrchestration(
            source.workspaceID,
            orchestration: orchestration
        )
        guard workspaceStore.flushPendingSave() else {
            if !PaneStatusTracker.shared.prepareForAgentLaunch(paneID: source.id) {
                PaneStatusTracker.shared.quarantineAgentLaunchOwnership(paneID: source.id)
            }
            throw SoyehtAutomationError.orchestrationManagerAuthorizationPersistenceFailed
        }
    }

    func handleClaimAgentRuntime(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let previousRuntimeClaim: AgentRuntimeIdentityClaim?
        guard let source = try resolveAutomationSource(payload: payload)?.conversation,
              let runtimeAgent = payload.runtimeAgent?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).lowercased(),
              LocalAgentCatalog.agent(named: runtimeAgent) != nil,
              let runtimeInstanceID = payload.runtimeInstanceID,
              !runtimeInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let runtimeProcessID = payload.runtimeProcessID,
              let expectedTTYDevice = automationTTYDevice(for: source) else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        previousRuntimeClaim = PaneStatusTracker.shared.runtimeIdentityClaim(for: source.id)
        if source.agent.isShell {
            guard PaneStatusTracker.shared.claimRuntimeIdentity(
                paneID: source.id,
                agentName: runtimeAgent,
                instanceID: runtimeInstanceID,
                processID: runtimeProcessID,
                nonce: payload.nonce,
                expectedTTYDevice: expectedTTYDevice
            ) else {
                throw SoyehtAutomationError.unauthenticatedAgentSource
            }
            if previousRuntimeClaim?.instanceID != runtimeInstanceID {
                try revokeShellRuntimeOrchestrationAuthorization(for: source)
            }
        } else {
            guard source.agent.rawValue.lowercased() == runtimeAgent,
                  PaneStatusTracker.shared.validatesLaunchOwnership(
                      paneID: source.id,
                      nonce: payload.nonce
                  ) else {
                throw SoyehtAutomationError.unauthenticatedAgentSource
            }
        }
        if let pane = LivePaneRegistry.shared.pane(for: source.id) as? PaneViewController {
            pane.refreshOrchestrationManagerHeaderState(for: source)
            pane.agentStateDidChangeForDeferredDelivery()
        }
        return SoyehtAutomationResult()
    }

    func handleReleaseAgentRuntime(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload)?.conversation,
              let runtimeInstanceID = payload.runtimeInstanceID else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if source.agent.isShell {
            guard authenticatesAutomationSource(source, payload: payload),
                  PaneStatusTracker.shared.validatesRuntimeIdentity(
                      paneID: source.id,
                      agentName: payload.runtimeAgent,
                      instanceID: runtimeInstanceID
                  ) else {
                throw SoyehtAutomationError.unauthenticatedAgentSource
            }
            try revokeShellRuntimeOrchestrationAuthorization(for: source)
            guard PaneStatusTracker.shared.releaseRuntimeIdentity(
                paneID: source.id,
                instanceID: runtimeInstanceID,
                nonce: payload.nonce
            ) else {
                throw SoyehtAutomationError.unauthenticatedAgentSource
            }
        } else if !PaneStatusTracker.shared.validatesLaunchOwnership(
            paneID: source.id,
            nonce: payload.nonce
        ) {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if let pane = LivePaneRegistry.shared.pane(for: source.id) as? PaneViewController {
            pane.refreshOrchestrationManagerHeaderState(for: source)
            pane.agentStateDidChangeForDeferredDelivery()
        }
        return SoyehtAutomationResult()
    }

    /// Creation requests may be initiated by the UI with no agent identity.
    /// Once a request claims a pane as its prompt sender, however, that claim
    /// must carry the pane launch nonce just like message and policy writes.
    /// Otherwise an untrusted peer could forge a trusted-looking prompt
    /// envelope while opening a new pane.
    func authenticateClaimedAutomationSource(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws {
        let claimsSource = [payload.sourceConversationID, payload.sourceHandle, payload.sourceTTY]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        if claimsSource {
            _ = try resolveAuthenticatedAutomationSource(payload: payload)
        }
    }

    func resolveAuthorizedOrchestrationManager(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> Conversation {
        let source = try resolveAuthenticatedAutomationSource(payload: payload)
        guard workspaceStore.workspace(source.workspaceID)?
            .orchestration?
            .canManageRolesAndTopology(source.id) == true else {
            throw SoyehtAutomationError.orchestrationManagerAuthorizationRequired
        }
        return source
    }

    func sourceIdentity(
        _ source: AutomationSourceResolution
    ) -> SoyehtAutomationResponse.SourceIdentity {
        let conversation = source.conversation
        let windowID = windowID(containingWorkspace: conversation.workspaceID)
        let workspaceName = workspaceStore.workspace(conversation.workspaceID)?.name ?? ""
        return SoyehtAutomationResponse.SourceIdentity(
            conversationID: conversation.id.uuidString,
            workspaceID: conversation.workspaceID.uuidString,
            workspaceName: workspaceName,
            handle: conversation.handle,
            displayReference: Self.displayReference(for: conversation.handle),
            roleTemplateID: conversation.roleAssignment?.templateID,
            roleName: conversation.roleAssignment?.roleName,
            roleInstructions: conversation.roleAssignment?.instructions,
            path: automationReportPath(for: conversation.content, workingDirectoryPath: conversation.workingDirectoryPath),
            declaredAgent: conversation.content.isTerminal ? conversation.agent.rawValue : conversation.content.displayKind,
            activeRuntimeAgent: PaneStatusTracker.shared.effectiveAgentName(for: conversation),
            windowID: windowID,
            resolution: source.resolution,
            replyTarget: messageArguments(
                toHandle: conversation.handle,
                conversationID: conversation.id,
                targetWindowID: windowID,
                source: nil
            )
        )
    }

    func listedAgent(
        _ pane: SoyehtMainWindowController.ListedPaneResult,
        source: SoyehtAutomationResponse.SourceIdentity?,
        presence: PanePresence?
    ) -> SoyehtAutomationResponse.ListedAgent {
        let conversation = AppEnvironment.conversationStore?
            .conversation(pane.conversationID)
        let isTerminal = conversation?.content.isTerminal ?? false
        let isLive = presence?.isLive ?? (LivePaneRegistry.shared.pane(for: pane.conversationID) != nil)
        let isAttachable = presence?.isAttachable ?? (LivePaneRegistry.shared.pane(for: pane.conversationID) as? PaneViewController != nil)
        let canReceiveMessage = isTerminal
            && isAttachable
            && (conversation.map {
                PaneStatusTracker.shared.hasAuthenticatedAgentRuntime(for: $0)
            } ?? false)
        let role = conversation?.roleAssignment
        let args = messageArguments(
            toHandle: pane.handle,
            conversationID: pane.conversationID,
            targetWindowID: pane.windowID,
            source: source
        )
        return SoyehtAutomationResponse.ListedAgent(
            conversationID: pane.conversationID.uuidString,
            workspaceID: pane.workspaceID.uuidString,
            workspaceName: workspaceStore.workspace(pane.workspaceID)?.name ?? "",
            handle: pane.handle,
            displayReference: Self.displayReference(for: pane.handle),
            roleTemplateID: role?.templateID,
            roleName: role?.roleName,
            roleInstructions: role?.instructions,
            path: pane.path,
            declaredAgent: pane.declaredAgent,
            activeRuntimeAgent: conversation.flatMap {
                PaneStatusTracker.shared.effectiveAgentName(for: $0)
            },
            status: presence?.status ?? (isLive ? "live" : "not_live"),
            isLive: isLive,
            isAttachable: isAttachable,
            canReceiveMessage: canReceiveMessage,
            isActive: pane.isActive,
            isActiveWorkspace: pane.isActiveWorkspace,
            isSourceWorkspace: source?.workspaceID == pane.workspaceID.uuidString,
            windowID: pane.windowID,
            messageTarget: args,
            replyInstructions: replyInstructions(to: pane.conversationID, source: source)
        )
    }

    func messageArguments(
        toHandle: String,
        conversationID: Conversation.ID,
        targetWindowID: String?,
        source: SoyehtAutomationResponse.SourceIdentity?
    ) -> SoyehtAutomationResponse.MessageAgentArguments {
        SoyehtAutomationResponse.MessageAgentArguments(
            handles: [toHandle],
            conversationIDs: [conversationID.uuidString],
            fromHandle: source?.handle,
            fromConversationID: source?.conversationID,
            targetWindowID: targetWindowID,
            lineEnding: "enter"
        )
    }

    func replyInstructions(
        to conversationID: Conversation.ID,
        source: SoyehtAutomationResponse.SourceIdentity?
    ) -> String {
        if let source {
            return "Use message_agent with conversationIDs=[\"\(conversationID.uuidString)\"], fromConversationID=\"\(source.conversationID)\", lineEnding=\"enter\". Do not create a new pane when this conversation is present."
        }
        return "Use message_agent with conversationIDs=[\"\(conversationID.uuidString)\"] and pass fromConversationID from identify_agent when available. Do not create a new pane when this conversation is present."
    }

    static func displayReference(for handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return "[\(name.isEmpty ? "pane" : name)]"
    }

    func panePresenceByID() -> [String: PanePresence] {
        Dictionary(
            uniqueKeysWithValues: PaneStatusTracker.shared.snapshotForWire().compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return (
                    id,
                    PanePresence(
                        status: item["status"] as? String ?? "unknown",
                        isLive: item["is_live"] as? Bool ?? false,
                        isAttachable: item["is_attachable"] as? Bool ?? false
                    )
                )
            }
        )
    }

    func windowID(containingWorkspace workspaceID: Workspace.ID) -> String? {
        mainWindowControllers().first {
            workspaceStore.workspace(workspaceID, isInWindow: $0.windowID)
        }?.windowID
    }

    func normalizedTTYName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else { return nil }
        let basename = (trimmed as NSString).lastPathComponent
        return basename.isEmpty ? trimmed : basename
    }
}
