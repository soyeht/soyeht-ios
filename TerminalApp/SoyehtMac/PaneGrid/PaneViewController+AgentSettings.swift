import AppKit

@MainActor
extension PaneViewController {
    func refreshOrchestrationManagerHeaderState(for suppliedConversation: Conversation? = nil) {
        guard let conversationStore = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let conversation = suppliedConversation
                ?? conversationStore.conversation(conversationID) else {
            header.isOrchestrationManager = false
            header.canToggleOrchestrationManager = false
            return
        }
        header.isOrchestrationManager = workspaceStore.workspace(conversation.workspaceID)?
            .orchestration?
            .canManageRolesAndTopology(conversationID) == true
        header.canToggleOrchestrationManager = PaneStatusTracker.shared
            .hasAuthenticatedAgentRuntime(for: conversation)
    }

    func setOrchestrationManagementAuthorizationFromHeader(_ isAuthorized: Bool) {
        guard let conversationStore = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let conversation = conversationStore.conversation(conversationID),
              PaneStatusTracker.shared.hasAuthenticatedAgentRuntime(
                  for: conversation
              ) else {
            refreshOrchestrationManagerHeaderState()
            return
        }

        let previousOrchestration = workspaceStore.workspace(conversation.workspaceID)?.orchestration
        var orchestration = previousOrchestration ?? WorkspaceOrchestration()
        orchestration.setManagementAuthorization(
            for: conversationID,
            isAuthorized: isAuthorized
        )

        guard !isAuthorized || orchestration.canManageRolesAndTopology(conversationID) else {
            refreshOrchestrationManagerHeaderState(for: conversation)
            presentOrchestrationManagerToggleError(
                "This workspace already has the maximum number of authorized orchestrators."
            )
            return
        }

        workspaceStore.updateOrchestration(
            conversation.workspaceID,
            orchestration: orchestration
        )
        guard workspaceStore.flushPendingSave() else {
            workspaceStore.updateOrchestration(
                conversation.workspaceID,
                orchestration: previousOrchestration
            )
            _ = workspaceStore.flushPendingSave()
            refreshOrchestrationManagerHeaderState(for: conversation)
            presentOrchestrationManagerToggleError(
                "Soyeht couldn't save the orchestrator privilege. The previous setting was restored."
            )
            return
        }
        refreshOrchestrationManagerHeaderState(for: conversation)
    }

    private func presentOrchestrationManagerToggleError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't update orchestrator privilege"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    func presentAgentMessagingSettings() {
        guard let store = AppEnvironment.conversationStore,
              let conversation = store.conversation(conversationID),
              let workspaceStore = AppEnvironment.workspaceStore else { return }
        let candidates = store.all
            .filter { $0.id != conversationID && $0.content.isTerminal }
            .sorted {
                let leftWorkspace = workspaceStore.workspace($0.workspaceID)?.name ?? ""
                let rightWorkspace = workspaceStore.workspace($1.workspaceID)?.name ?? ""
                if leftWorkspace != rightWorkspace {
                    return leftWorkspace.localizedCaseInsensitiveCompare(rightWorkspace) == .orderedAscending
                }
                return $0.handle.localizedCaseInsensitiveCompare($1.handle) == .orderedAscending
            }
        let accessory = AgentMessagingPolicyAccessoryView(
            conversation: conversation,
            candidates: candidates,
            workspaceName: { workspaceStore.workspace($0)?.name ?? "" }
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Messaging & Blocks"
        alert.informativeText = "Control who may send messages to \(AgentMessageEndpoint(paneID: conversation.id, workspaceID: conversation.workspaceID, handle: conversation.handle).displayLabel). Blocks use stable pane IDs, so renaming does not remove them."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  var latest = store.conversation(self.conversationID)?.agentCommunicationPolicy else { return }
            switch accessory.receiveMode {
            case .everyone:
                latest.incoming.isEnabled = true
                latest.incoming.allowsCrossWorkspace = true
            case .sameWorkspace:
                latest.incoming.isEnabled = true
                latest.incoming.allowsCrossWorkspace = false
            case .nobody:
                latest.incoming.isEnabled = false
            }
            latest.incoming.blockedPaneIDs = accessory.blockedPaneIDs
            let previous = store.conversation(self.conversationID)?.agentCommunicationPolicy
            let previousAgentRequested = store.conversation(self.conversationID)?
                .agentRequestedCommunicationPolicy
            store.updateAgentCommunicationPolicy(self.conversationID, policy: latest)
            if accessory.shouldResetAgentRequestedPolicy {
                store.updateAgentRequestedCommunicationPolicy(
                    self.conversationID,
                    policy: .open
                )
            }
            guard workspaceStore.flushPendingSave() else {
                if let previous {
                    store.updateAgentCommunicationPolicy(self.conversationID, policy: previous)
                }
                if let previousAgentRequested {
                    store.updateAgentRequestedCommunicationPolicy(
                        self.conversationID,
                        policy: previousAgentRequested
                    )
                }
                _ = workspaceStore.flushPendingSave()
                let errorAlert = NSAlert(error: SoyehtAutomationError.agentMessagePersistenceFailed)
                if let window = self.view.window {
                    errorAlert.beginSheetModal(for: window) { _ in }
                } else {
                    errorAlert.runModal()
                }
                return
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    func presentAgentRoleAndOrchestrationSettings() {
        guard let conversationStore = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let conversation = conversationStore.conversation(conversationID),
              let workspace = workspaceStore.workspace(conversation.workspaceID) else { return }
        let accessory = AgentRoleOrchestrationAccessoryView(
            conversationID: conversationID,
            assignment: conversation.roleAssignment,
            orchestration: workspace.orchestration
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Role & Orchestration"
        alert.informativeText = "Assign a reusable role to this agent and optionally activate a declarative topology for \(workspace.name)."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let previousOrchestration = workspaceStore.workspace(conversation.workspaceID)?.orchestration
                let previousAssignment = conversationStore.conversation(self.conversationID)?
                    .roleAssignment
                var orchestration = previousOrchestration
                    ?? WorkspaceOrchestration()
                orchestration.setManagementAuthorization(
                    for: self.conversationID,
                    isAuthorized: accessory.isManagementAuthorized
                )
                let assignment = try accessory.resolvedAssignment(updating: &orchestration)

                if let preset = accessory.selectedPreset {
                    var graph = AgentOrchestrationPresets.graph(
                        for: preset,
                        reusing: orchestration.activeGraph
                    )
                    let roleCandidates = conversationStore.all
                        .filter {
                            $0.workspaceID == conversation.workspaceID
                                && PaneStatusTracker.shared.hasAuthenticatedAgentRuntime(for: $0)
                        }
                        .sorted { left, right in
                            if left.id == self.conversationID { return true }
                            if right.id == self.conversationID { return false }
                            return left.handle.localizedCaseInsensitiveCompare(right.handle) == .orderedAscending
                        }
                        .compactMap { candidate -> (Conversation.ID, AgentRoleAssignment)? in
                            let role = candidate.id == self.conversationID
                                ? assignment
                                : candidate.roleAssignment
                            guard let role else { return nil }
                            return (candidate.id, role)
                        }
                    try graph.bindAllRoleAssignments(roleCandidates)
                    try orchestration.saveGraph(graph)
                    try orchestration.activateGraph(id: graph.id)
                } else {
                    try orchestration.activateGraph(id: nil)
                }
                let currentTarget = conversationStore.conversation(self.conversationID)
                    ?? conversation
                let roleDelivery = currentTarget.roleAssignment == assignment
                    ? nil
                    : try AgentRoleAssignmentDelivery.make(
                        target: currentTarget,
                        sender: currentTarget,
                        assignment: assignment
                    )
                if let roleDelivery {
                    _ = try conversationStore.enqueueAgentMessage(
                        roleDelivery.message,
                        in: roleDelivery.targetID
                    )
                }
                // Commit both user-visible mutations only after graph
                // construction/validation succeeds. A failed topology save
                // must not leave the pane's role half-updated.
                conversationStore.updateRoleAssignment(self.conversationID, roleAssignment: assignment)
                workspaceStore.updateOrchestration(conversation.workspaceID, orchestration: orchestration)
                guard workspaceStore.flushPendingSave() else {
                    conversationStore.updateRoleAssignment(
                        self.conversationID,
                        roleAssignment: previousAssignment
                    )
                    workspaceStore.updateOrchestration(
                        conversation.workspaceID,
                        orchestration: previousOrchestration
                    )
                    if let roleDelivery {
                        _ = try? conversationStore.mutateAgentMessageInbox(
                            roleDelivery.targetID
                        ) { inbox in
                            try inbox.removeUndelivered(roleDelivery.message.id)
                        }
                    }
                    _ = workspaceStore.flushPendingSave()
                    throw SoyehtAutomationError.agentMessagePersistenceFailed
                }
                self.refreshOrchestrationManagerHeaderState(for: conversation)
                roleDelivery.map(PaneViewController.enqueueRoleAssignmentDeliveryIfLive)
            } catch {
                let errorAlert = NSAlert(error: error)
                if let window = self.view.window {
                    errorAlert.beginSheetModal(for: window) { _ in }
                } else {
                    errorAlert.runModal()
                }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }
}
