import XCTest
@testable import SoyehtMacDomain

final class AgentOrchestrationTests: XCTestCase {
    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soyeht-orchestration-\(UUID().uuidString).json")
    }

    func testBuiltInRoleTemplatesHaveStableIDsAndOrder() {
        XCTAssertEqual(
            AgentRoleTemplateCatalog.builtIn.map(\.id),
            ["builtin.planner", "builtin.executor", "builtin.reviewer", "builtin.aggregator"]
        )
        XCTAssertTrue(AgentRoleTemplateCatalog.builtIn.allSatisfy { !$0.instructions.isEmpty })
    }

    func testRoleAssignmentIsSnapshotNotPaneIdentity() {
        let role = AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)
        let conversation = Conversation(
            handle: "@temporary-name",
            agent: .claw("codex"),
            workspaceID: UUID(),
            commander: .mirror(instanceID: "test"),
            roleAssignment: role
        )

        XCTAssertEqual(conversation.handle, "@temporary-name")
        XCTAssertEqual(conversation.roleAssignment?.roleName, "Reviewer")
        XCTAssertEqual(conversation.roleAssignment?.templateID, "builtin.reviewer")
    }

    func testCustomTemplatesCanBeSavedUpdatedAndRemoved() throws {
        var library = AgentRoleTemplateLibrary()
        try library.save(.init(id: "custom.security", displayName: "Security", instructions: "Threat model."))
        try library.save(.init(id: "custom.docs", displayName: "Docs", instructions: "Check documentation."))
        try library.save(.init(id: "custom.security", displayName: "Security reviewer", instructions: "Review threats."))

        XCTAssertEqual(library.customTemplates.map(\.id), ["custom.docs", "custom.security"])
        XCTAssertEqual(library.template(id: "custom.security")?.displayName, "Security reviewer")
        XCTAssertNotNil(try library.remove(id: "custom.docs"))
        XCTAssertNil(library.template(id: "custom.docs"))
    }

    func testBuiltInTemplatesCannotBeOverwrittenOrRemoved() {
        var library = AgentRoleTemplateLibrary()
        let replacement = AgentRoleTemplate(
            id: "builtin.planner",
            displayName: "Different",
            instructions: "Different"
        )

        XCTAssertThrowsError(try library.save(replacement)) {
            XCTAssertEqual(
                $0 as? AgentRoleTemplateLibraryError,
                .builtInTemplateIsReadOnly("builtin.planner")
            )
        }
        XCTAssertThrowsError(try library.remove(id: "builtin.planner")) {
            XCTAssertEqual(
                $0 as? AgentRoleTemplateLibraryError,
                .builtInTemplateIsReadOnly("builtin.planner")
            )
        }
    }

    func testInvalidCustomTemplateIsRejectedDeterministically() {
        var library = AgentRoleTemplateLibrary()
        XCTAssertThrowsError(try library.save(.init(id: "Bad ID", displayName: "", instructions: ""))) { error in
            guard case let AgentRoleTemplateLibraryError.invalidTemplate(issues) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(issues.map(\.code), [.emptyTemplateName, .invalidIdentifier, .emptyInstructions])
            XCTAssertEqual(issues.map(\.path), ["template.displayName", "template.id", "template.instructions"])
        }
    }

    func testPresetCouncilFansInToAggregator() {
        let graph = AgentOrchestrationPresets.council(ideatorCount: 4)

        XCTAssertEqual(graph.preset, .council)
        XCTAssertEqual(graph.nodes.count, 5)
        XCTAssertEqual(graph.edges.count, 4)
        XCTAssertTrue(graph.edges.allSatisfy { $0.targetNodeID == "aggregator" })
        XCTAssertTrue(graph.edges.allSatisfy { $0.message?.authorization == .allow })
        XCTAssertTrue(graph.edges.allSatisfy { $0.artifact?.authorization == .allow })
        XCTAssertTrue(graph.isValid)
    }

    func testPresetPlannerExecutorReviewerIsDirectedChain() {
        let graph = AgentOrchestrationPresets.plannerExecutorReviewer()

        XCTAssertEqual(graph.nodes.map(\.id), ["planner", "executor", "reviewer"])
        XCTAssertEqual(
            graph.edges.map { "\($0.sourceNodeID)->\($0.targetNodeID)" },
            ["planner->executor", "executor->reviewer"]
        )
        XCTAssertEqual(graph.policy.unlistedMessages, .deny)
        XCTAssertEqual(graph.policy.unlistedArtifacts, .deny)
        XCTAssertTrue(graph.isValid)
    }

    func testPresetExecutorReviewerIsBidirectional() {
        let graph = AgentOrchestrationPresets.executorReviewerLoop()

        XCTAssertEqual(
            Set(graph.edges.map { "\($0.sourceNodeID)->\($0.targetNodeID)" }),
            ["executor->reviewer", "reviewer->executor"]
        )
        XCTAssertTrue(graph.isValid)
    }

    func testGraphResolvesDeclaredAndFallbackPolicies() throws {
        var graph = AgentOrchestrationPresets.plannerExecutorReviewer()
        let planner = UUID()
        let executor = UUID()
        let reviewer = UUID()
        try graph.bind(conversationID: planner, toNodeID: "planner")
        try graph.bind(conversationID: executor, toNodeID: "executor")
        try graph.bind(conversationID: reviewer, toNodeID: "reviewer")

        XCTAssertEqual(
            graph.flowPolicy(from: planner, to: executor, kind: .message)?.authorization,
            .allow
        )
        XCTAssertEqual(
            graph.flowPolicy(from: planner, to: reviewer, kind: .message)?.authorization,
            .deny
        )
        XCTAssertEqual(
            graph.flowPolicy(from: planner, to: reviewer, kind: .artifact)?.authorization,
            .deny
        )
        XCTAssertEqual(graph.roleAssignment(for: reviewer)?.roleName, "Reviewer")
        XCTAssertNil(graph.flowPolicy(from: UUID(), to: reviewer, kind: .message))
    }

    func testGraphBindingRejectsDuplicateConversation() throws {
        var graph = AgentOrchestrationPresets.executorReviewerLoop()
        let conversationID = UUID()
        try graph.bind(conversationID: conversationID, toNodeID: "executor")

        XCTAssertThrowsError(try graph.bind(conversationID: conversationID, toNodeID: "reviewer")) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationGraphError,
                .conversationAlreadyBound(conversationID)
            )
        }
    }

    func testValidationFindsStructuralErrorsInStableOrder() {
        let conversationID = UUID()
        let badRole = AgentRoleAssignment(templateID: "missing.role", roleName: "", instructions: "")
        let graph = AgentOrchestrationGraph(
            title: "",
            nodes: [
                .init(id: "Bad ID", conversationID: conversationID, role: badRole),
                .init(id: "Bad ID", conversationID: conversationID, role: badRole),
            ],
            edges: [
                .init(from: "missing", to: "missing"),
                .init(from: "missing", to: "missing"),
            ]
        )

        let first = graph.validationIssues
        let second = graph.validationIssues
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains(where: { $0.code == .emptyGraphTitle }))
        XCTAssertTrue(first.contains(where: { $0.code == .duplicateNodeID }))
        XCTAssertTrue(first.contains(where: { $0.code == .duplicateConversationBinding }))
        XCTAssertTrue(first.contains(where: { $0.code == .unknownRoleTemplate && $0.severity == .warning }))
        XCTAssertTrue(first.contains(where: { $0.code == .selfEdge }))
        XCTAssertTrue(first.contains(where: { $0.code == .unknownSourceNode }))
        XCTAssertTrue(first.contains(where: { $0.code == .unknownTargetNode }))
        XCTAssertTrue(first.contains(where: { $0.code == .duplicateEdge }))
        XCTAssertTrue(first.contains(where: { $0.code == .emptyEdge }))
        XCTAssertFalse(graph.isValid)
    }

    func testUnknownTemplateIsWarningBecauseAssignmentRetainsSnapshot() {
        let graph = AgentOrchestrationGraph(
            title: "Detached template",
            nodes: [
                .init(
                    id: "worker",
                    role: .init(
                        templateID: "custom.deleted",
                        roleName: "Still meaningful",
                        instructions: "The snapshot remains executable."
                    )
                ),
            ],
            edges: []
        )

        XCTAssertTrue(graph.isValid)
        XCTAssertEqual(graph.validationIssues.map(\.code), [.unknownRoleTemplate])
        XCTAssertEqual(graph.validationIssues.first?.severity, .warning)
    }

    func testWorkspaceOrchestrationSavesAndActivatesGraphs() throws {
        var orchestration = WorkspaceOrchestration()
        let graph = AgentOrchestrationPresets.plannerExecutorReviewer()

        try orchestration.saveGraph(graph)
        try orchestration.activateGraph(id: graph.id)

        XCTAssertEqual(orchestration.activeGraph, graph)
        XCTAssertNil(orchestration.removeGraph(id: UUID()))
        XCTAssertEqual(orchestration.removeGraph(id: graph.id), graph)
        XCTAssertNil(orchestration.activeGraphID)
    }

    func testWorkspaceOrchestrationPersistsMultipleAuthorizedManagers() throws {
        let first = UUID()
        let second = UUID()
        var orchestration = WorkspaceOrchestration()

        orchestration.setManagementAuthorization(for: first, isAuthorized: true)
        orchestration.setManagementAuthorization(for: second, isAuthorized: true)

        XCTAssertTrue(orchestration.canManageRolesAndTopology(first))
        XCTAssertTrue(orchestration.canManageRolesAndTopology(second))

        let roundTrip = try JSONDecoder().decode(
            WorkspaceOrchestration.self,
            from: JSONEncoder().encode(orchestration)
        )
        XCTAssertEqual(roundTrip, orchestration)

        orchestration.setManagementAuthorization(for: first, isAuthorized: false)
        XCTAssertFalse(orchestration.canManageRolesAndTopology(first))
        XCTAssertTrue(orchestration.canManageRolesAndTopology(second))
    }

    func testLegacyWorkspaceOrchestrationDefaultsAuthorizedManagersToEmpty() throws {
        let orchestration = WorkspaceOrchestration()
        let legacyData = try removingJSONKey(
            "authorizedManagerPaneIDs",
            from: JSONEncoder().encode(orchestration)
        )

        let decoded = try JSONDecoder().decode(WorkspaceOrchestration.self, from: legacyData)

        XCTAssertTrue(decoded.authorizedManagerPaneIDs.isEmpty)
    }

    func testWorkspaceValidationRejectsBindingOutsideWorkspace() {
        let inside = UUID()
        let outside = UUID()
        var graph = AgentOrchestrationPresets.executorReviewerLoop()
        graph.nodes[0].conversationID = inside
        graph.nodes[1].conversationID = outside
        let orchestration = WorkspaceOrchestration(graphs: [graph], activeGraphID: graph.id)

        let issues = orchestration.validationIssues(workspaceConversationIDs: [inside])

        XCTAssertEqual(issues.filter { $0.code == .conversationOutsideWorkspace }.count, 1)
        XCTAssertTrue(issues.first(where: { $0.code == .conversationOutsideWorkspace })?.path.contains("nodes[1]") == true)
    }

    func testWorkspaceAndConversationCodableAreBackwardCompatible() throws {
        let workspaceID = UUID()
        let paneID = UUID()
        let legacyWorkspace = Workspace(
            id: workspaceID,
            name: "Legacy",
            kind: .adhoc,
            layout: .leaf(paneID)
        )
        let legacyWorkspaceData = try removingJSONKey(
            "orchestration",
            from: JSONEncoder().encode(legacyWorkspace)
        )
        let decodedWorkspace = try JSONDecoder().decode(Workspace.self, from: legacyWorkspaceData)
        XCTAssertNil(decodedWorkspace.orchestration)

        let legacyConversation = Conversation(
            id: paneID,
            handle: "@legacy",
            agent: .claw("claude"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        )
        let legacyConversationData = try removingJSONKey(
            "roleAssignment",
            from: JSONEncoder().encode(legacyConversation)
        )
        let decodedConversation = try JSONDecoder().decode(Conversation.self, from: legacyConversationData)
        XCTAssertNil(decodedConversation.roleAssignment)
    }

    @MainActor
    func testStoresUpdateRolesAndOrchestrationWithoutChangingIdentity() throws {
        let storageURL = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let paneID = UUID()
        let workspace = Workspace(name: "Team", kind: .team, layout: .leaf(paneID))
        let workspaceStore = WorkspaceStore(storageURL: storageURL)
        _ = workspaceStore.add(workspace)
        let conversationStore = ConversationStore()
        _ = conversationStore.add(Conversation(
            id: paneID,
            handle: "@worker",
            agent: .claw("codex"),
            workspaceID: workspace.id,
            commander: .mirror(instanceID: "test")
        ))
        let role = AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)
        var orchestration = WorkspaceOrchestration()
        let graph = AgentOrchestrationPresets.executorReviewerLoop()
        try orchestration.saveGraph(graph)

        conversationStore.updateRoleAssignment(paneID, roleAssignment: role)
        workspaceStore.updateOrchestration(workspace.id, orchestration: orchestration)

        XCTAssertEqual(conversationStore.conversation(paneID)?.handle, "@worker")
        XCTAssertEqual(conversationStore.conversation(paneID)?.roleAssignment, role)
        XCTAssertEqual(workspaceStore.workspace(workspace.id)?.name, "Team")
        XCTAssertEqual(workspaceStore.workspace(workspace.id)?.orchestration, orchestration)
    }

    func testWorkspaceRoundTripPersistsCustomTemplatesGraphsAndPaneRole() throws {
        var templates = AgentRoleTemplateLibrary()
        try templates.save(.init(
            id: "custom.security-reviewer",
            displayName: "Security reviewer",
            instructions: "Audit trust boundaries."
        ))
        var orchestration = WorkspaceOrchestration(roleTemplates: templates)
        let graph = AgentOrchestrationPresets.council(ideatorCount: 2)
        try orchestration.saveGraph(graph)
        try orchestration.activateGraph(id: graph.id)

        let workspace = Workspace(
            name: "Orchestrated",
            kind: .team,
            layout: .leaf(UUID()),
            orchestration: orchestration
        )
        let workspaceRoundTrip = try JSONDecoder().decode(
            Workspace.self,
            from: JSONEncoder().encode(workspace)
        )
        XCTAssertEqual(workspaceRoundTrip, workspace)
        XCTAssertEqual(
            workspaceRoundTrip.orchestration?.roleTemplates.template(id: "custom.security-reviewer")?.displayName,
            "Security reviewer"
        )

        let conversation = Conversation(
            handle: "@agent",
            agent: .claw("opencode"),
            workspaceID: workspace.id,
            commander: .mirror(instanceID: "test"),
            roleAssignment: .init(template: AgentRoleTemplateCatalog.executor)
        )
        let conversationRoundTrip = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation)
        )
        XCTAssertEqual(conversationRoundTrip, conversation)
    }

    private func removingJSONKey(_ key: String, from data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
