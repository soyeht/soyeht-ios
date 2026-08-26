import Foundation

extension SoyehtAutomationRequestRouter {
    func handleSetAgentRole(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        let targets = (payload.conversationIDs ?? []).isEmpty
            && (payload.handles ?? []).isEmpty
            ? [source]
            : try resolveAgentMessageTargets(payload)
        let workspace = workspaceStore.workspace(source.workspaceID)
        guard targets.allSatisfy({ $0.workspaceID == source.workspaceID }) else {
            let outside = targets.first { $0.workspaceID != source.workspaceID }!
            throw SoyehtAutomationError.orchestrationConversationOutsideWorkspace(
                outside.id.uuidString
            )
        }
        let templateID = payload.roleTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment: AgentRoleAssignment?
        if templateID?.lowercased() == "none" {
            assignment = nil
        } else if let templateID, !templateID.isEmpty {
            guard let template = workspace?.orchestration?.roleTemplates.template(id: templateID)
                ?? AgentRoleTemplateCatalog.template(id: templateID) else {
                throw SoyehtAutomationError.agentRoleTemplateNotFound(templateID)
            }
            assignment = AgentRoleAssignment(template: template)
        } else if let name = payload.roleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let instructions = payload.roleInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !instructions.isEmpty {
            assignment = AgentRoleAssignment(roleName: name, instructions: instructions)
        } else {
            assignment = nil
        }
        if let assignment {
            let issues = AgentOrchestrationValidator.validate(assignment: assignment)
                .filter { $0.severity == .error }
            guard issues.isEmpty else {
                throw AgentRoleTemplateLibraryError.invalidTemplate(issues)
            }
        }
        for target in targets {
            guard isEligibleOrchestrationAgent(target) else {
                throw SoyehtAutomationError.orchestrationRequiresAgentPane(target.id.uuidString)
            }
            if let activeGraph = workspace?.orchestration?.activeGraph,
               activeGraph.nodes.contains(where: { $0.conversationID == target.id }),
               target.roleAssignment != assignment {
                throw SoyehtAutomationError
                    .orchestrationRoleChangeRequiresReconfiguration(target.id.uuidString)
            }
        }
        let roleDeliveries: [AgentRoleAssignmentDelivery] = try targets.compactMap {
            target -> AgentRoleAssignmentDelivery? in
            guard target.roleAssignment != assignment else { return nil }
            return try AgentRoleAssignmentDelivery.make(
                target: target,
                sender: source,
                assignment: assignment
            )
        }
        let previousAssignments: [(Conversation.ID, AgentRoleAssignment?)] = targets.map {
            ($0.id, $0.roleAssignment)
        }
        var insertedRoleDeliveries: [AgentRoleAssignmentDelivery] = []
        do {
            for delivery in roleDeliveries {
                if try conversationStore.enqueueAgentMessage(
                    delivery.message,
                    in: delivery.targetID
                ) {
                    insertedRoleDeliveries.append(delivery)
                }
            }
        } catch {
            rollbackRoleAssignmentDeliveries(insertedRoleDeliveries)
            throw error
        }
        let states = targets.map { target in
            conversationStore.updateRoleAssignment(target.id, roleAssignment: assignment)
            let endpoint = AgentMessageEndpoint(
                paneID: target.id,
                workspaceID: target.workspaceID,
                handle: target.handle
            )
            return SoyehtAutomationResponse.AgentRoleState(
                conversationID: target.id.uuidString,
                displayReference: endpoint.displayLabel,
                templateID: assignment?.templateID,
                roleName: assignment?.roleName,
                instructions: assignment?.instructions
            )
        }
        guard workspaceStore.flushPendingSave() else {
            for (conversationID, previous) in previousAssignments {
                conversationStore.updateRoleAssignment(
                    conversationID,
                    roleAssignment: previous
                )
            }
            rollbackRoleAssignmentDeliveries(insertedRoleDeliveries)
            _ = workspaceStore.flushPendingSave()
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        insertedRoleDeliveries.forEach(PaneViewController.enqueueRoleAssignmentDeliveryIfLive)
        return SoyehtAutomationResult(agentRoles: states)
    }

    func handleSaveAgentRoleTemplate(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        let name = payload.roleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = payload.roleInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let requestedID = payload.templateID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = requestedID?.isEmpty == false ? requestedID! : "custom.\(slug)"
        let previousOrchestration = workspaceStore.workspace(source.workspaceID)?.orchestration
        var orchestration = previousOrchestration
            ?? WorkspaceOrchestration()
        try orchestration.roleTemplates.save(.init(
            id: id,
            displayName: name,
            instructions: instructions
        ))
        workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
        guard workspaceStore.flushPendingSave() else {
            workspaceStore.updateOrchestration(
                source.workspaceID,
                orchestration: previousOrchestration ?? WorkspaceOrchestration()
            )
            _ = workspaceStore.flushPendingSave()
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        return SoyehtAutomationResult(agentOrchestrations: [
            agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
        ])
    }

    func handleConfigureAgentOrchestration(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        let previousOrchestration = workspaceStore.workspace(source.workspaceID)?.orchestration
        var orchestration = previousOrchestration
            ?? WorkspaceOrchestration()
        let rawPreset = payload.preset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawPreset == nil || rawPreset == "" || rawPreset == "none" {
            try orchestration.activateGraph(id: nil)
            workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
            guard workspaceStore.flushPendingSave() else {
                workspaceStore.updateOrchestration(
                    source.workspaceID,
                    orchestration: previousOrchestration ?? WorkspaceOrchestration()
                )
                _ = workspaceStore.flushPendingSave()
                throw SoyehtAutomationError.agentMessagePersistenceFailed
            }
            return SoyehtAutomationResult(agentOrchestrations: [
                agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
            ])
        }
        let preset: AgentOrchestrationPreset
        switch rawPreset {
        case "council", "conselho": preset = .council
        case "plannerexecutorreviewer", "plan-execute-review", "planner-executor-reviewer":
            preset = .plannerExecutorReviewer
        case "executorreviewerloop", "execute-review", "executor-reviewer-loop":
            preset = .executorReviewerLoop
        case .some(let value): throw SoyehtAutomationError.invalidOrchestrationPreset(value)
        case nil: throw SoyehtAutomationError.invalidOrchestrationPreset("")
        }
        let ideatorCount = payload.ideatorCount ?? 3
        guard (1...16).contains(ideatorCount) else {
            throw SoyehtAutomationError.invalidOrchestrationIdeatorCount(ideatorCount)
        }
        let freshGraph = preset == .council
            ? AgentOrchestrationPresets.council(ideatorCount: ideatorCount)
            : AgentOrchestrationPresets.make(preset)
        var graph: AgentOrchestrationGraph
        if let active = orchestration.activeGraph,
           active.preset == preset,
           active.nodes.map(\.id) == freshGraph.nodes.map(\.id) {
            graph = active
        } else {
            // Preset configuration is replacement, not an append-only graph
            // history. There is intentionally no product surface for users to
            // prune stale generated presets, so retaining every toggle would
            // exhaust the bounded graph store after 16 legitimate changes.
            if let activeGraphID = orchestration.activeGraphID {
                orchestration.removeGraph(id: activeGraphID)
            }
            graph = freshGraph
        }
        var explicitIDs = Set<Conversation.ID>()
        var explicitRoleAssignments: [(Conversation.ID, AgentRoleAssignment)] = []
        for (nodeID, rawID) in payload.nodeBindings ?? [:] {
            guard let id = UUID(uuidString: rawID),
                  let conversation = conversationStore.conversation(id),
                  conversation.workspaceID == source.workspaceID else {
                throw SoyehtAutomationError.orchestrationConversationOutsideWorkspace(rawID)
            }
            guard isEligibleOrchestrationAgent(conversation) else {
                throw SoyehtAutomationError.orchestrationRequiresAgentPane(rawID)
            }
            try graph.bind(conversationID: id, toNodeID: nodeID)
            explicitIDs.insert(id)
            if let node = graph.nodes.first(where: { $0.id == nodeID }) {
                explicitRoleAssignments.append((id, node.role))
            }
        }
        let candidates = conversationStore.conversations(in: source.workspaceID).compactMap {
            conversation -> (Conversation.ID, AgentRoleAssignment)? in
            guard isEligibleOrchestrationAgent(conversation) else { return nil }
            if explicitIDs.contains(conversation.id),
               let node = graph.nodes.first(where: { $0.conversationID == conversation.id }) {
                return (conversation.id, node.role)
            }
            guard let assignment = conversation.roleAssignment else { return nil }
            return (conversation.id, assignment)
        }
        try graph.bindAllRoleAssignments(candidates)
        try orchestration.saveGraph(graph)
        try orchestration.activateGraph(id: graph.id)
        let changedExplicitAssignments = explicitRoleAssignments.compactMap {
            (conversationID, assignment) -> (Conversation, AgentRoleAssignment)? in
            guard let target = conversationStore.conversation(conversationID),
                  target.roleAssignment != assignment else { return nil }
            return (target, assignment)
        }
        let roleDeliveries = try changedExplicitAssignments.map {
            try AgentRoleAssignmentDelivery.make(
                target: $0.0,
                sender: source,
                assignment: $0.1
            )
        }
        var insertedRoleDeliveries: [AgentRoleAssignmentDelivery] = []
        do {
            for delivery in roleDeliveries {
                if try conversationStore.enqueueAgentMessage(
                    delivery.message,
                    in: delivery.targetID
                ) {
                    insertedRoleDeliveries.append(delivery)
                }
            }
        } catch {
            rollbackRoleAssignmentDeliveries(insertedRoleDeliveries)
            throw error
        }
        // All throwing validation is complete before role/topology stores
        // mutate. The durable role notices were staged first and share the
        // same snapshot commit as the graph activation.
        // Explicit node bindings carry the node's role into the pane so the
        // agent receives the same assignment that routing now enforces.
        let previousAssignments: [(Conversation.ID, AgentRoleAssignment?)] = explicitRoleAssignments.map {
            ($0.0, conversationStore.conversation($0.0)?.roleAssignment)
        }
        for (conversationID, assignment) in explicitRoleAssignments {
            conversationStore.updateRoleAssignment(
                conversationID,
                roleAssignment: assignment
            )
        }
        workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
        guard workspaceStore.flushPendingSave() else {
            for (conversationID, previous) in previousAssignments {
                conversationStore.updateRoleAssignment(
                    conversationID,
                    roleAssignment: previous
                )
            }
            workspaceStore.updateOrchestration(
                source.workspaceID,
                orchestration: previousOrchestration ?? WorkspaceOrchestration()
            )
            rollbackRoleAssignmentDeliveries(insertedRoleDeliveries)
            _ = workspaceStore.flushPendingSave()
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        insertedRoleDeliveries.forEach(PaneViewController.enqueueRoleAssignmentDeliveryIfLive)
        return SoyehtAutomationResult(agentOrchestrations: [
            agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
        ])
    }

    private func isEligibleOrchestrationAgent(_ conversation: Conversation) -> Bool {
        PaneStatusTracker.shared.hasAuthenticatedAgentRuntime(for: conversation)
    }

    private func rollbackRoleAssignmentDeliveries(
        _ deliveries: [AgentRoleAssignmentDelivery]
    ) {
        for delivery in deliveries {
            _ = try? conversationStore.mutateAgentMessageInbox(delivery.targetID) { inbox in
                try inbox.removeUndelivered(delivery.message.id)
            }
        }
    }
}
