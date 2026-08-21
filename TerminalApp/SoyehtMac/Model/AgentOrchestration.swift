import Foundation

// MARK: - Roles

/// Reusable instructions for an agent role. A template is deliberately not an
/// agent name: many panes can share one role and renaming a pane never changes
/// its assignment.
struct AgentRoleTemplate: Codable, Identifiable, Hashable {
    typealias ID = String

    var id: ID
    var displayName: String
    var instructions: String

    init(id: ID, displayName: String, instructions: String) {
        self.id = id
        self.displayName = displayName
        self.instructions = instructions
    }
}

/// The role snapshot assigned to one pane. Keeping a snapshot as well as the
/// optional template reference means an existing assignment remains meaningful
/// if a custom template is later edited or removed.
struct AgentRoleAssignment: Codable, Hashable {
    var templateID: AgentRoleTemplate.ID?
    var roleName: String
    var instructions: String

    init(templateID: AgentRoleTemplate.ID? = nil, roleName: String, instructions: String) {
        self.templateID = templateID
        self.roleName = roleName
        self.instructions = instructions
    }

    init(template: AgentRoleTemplate) {
        self.init(
            templateID: template.id,
            roleName: template.displayName,
            instructions: template.instructions
        )
    }
}

enum AgentRoleTemplateCatalog {
    static let planner = AgentRoleTemplate(
        id: "builtin.planner",
        displayName: "Planner",
        instructions: "Clarify the objective, identify constraints, and produce an actionable plan. Do not implement unless explicitly asked."
    )

    static let executor = AgentRoleTemplate(
        id: "builtin.executor",
        displayName: "Executor",
        instructions: "Implement the agreed plan, verify the result, and report concrete evidence and remaining risks."
    )

    static let reviewer = AgentRoleTemplate(
        id: "builtin.reviewer",
        displayName: "Reviewer",
        instructions: "Review independently for correctness, regressions, safety, and missing tests. Return actionable findings before approval."
    )

    static let aggregator = AgentRoleTemplate(
        id: "builtin.aggregator",
        displayName: "Aggregator",
        instructions: "Collect the other agents' independent results, preserve disagreements, and synthesize a decision with traceable rationale."
    )

    /// Stable order is part of the automation/UI contract.
    static let builtIn: [AgentRoleTemplate] = [planner, executor, reviewer, aggregator]

    static func template(
        id: AgentRoleTemplate.ID,
        customTemplates: [AgentRoleTemplate] = []
    ) -> AgentRoleTemplate? {
        customTemplates.first(where: { $0.id == id })
            ?? builtIn.first(where: { $0.id == id })
    }

    static var builtInIDs: Set<AgentRoleTemplate.ID> {
        Set(builtIn.map(\.id))
    }
}

/// Codable workspace-scoped library. UI may copy a built-in into a custom ID,
/// edit it, and save it; the enclosing Workspace persistence makes it durable.
struct AgentRoleTemplateLibrary: Codable, Hashable {
    private(set) var customTemplates: [AgentRoleTemplate]

    init(customTemplates: [AgentRoleTemplate] = []) {
        self.customTemplates = customTemplates
    }

    var allTemplates: [AgentRoleTemplate] {
        AgentRoleTemplateCatalog.builtIn + customTemplates
    }

    func template(id: AgentRoleTemplate.ID) -> AgentRoleTemplate? {
        AgentRoleTemplateCatalog.template(id: id, customTemplates: customTemplates)
    }

    mutating func save(_ template: AgentRoleTemplate) throws {
        if AgentRoleTemplateCatalog.builtInIDs.contains(template.id) {
            throw AgentRoleTemplateLibraryError.builtInTemplateIsReadOnly(template.id)
        }

        let issues = AgentOrchestrationValidator.validate(template: template)
            .filter { $0.severity == .error }
        guard issues.isEmpty else {
            throw AgentRoleTemplateLibraryError.invalidTemplate(issues)
        }

        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
        customTemplates.sort { $0.id < $1.id }
    }

    @discardableResult
    mutating func remove(id: AgentRoleTemplate.ID) throws -> AgentRoleTemplate? {
        if AgentRoleTemplateCatalog.builtInIDs.contains(id) {
            throw AgentRoleTemplateLibraryError.builtInTemplateIsReadOnly(id)
        }
        guard let index = customTemplates.firstIndex(where: { $0.id == id }) else { return nil }
        return customTemplates.remove(at: index)
    }
}

enum AgentRoleTemplateLibraryError: Error, Equatable {
    case builtInTemplateIsReadOnly(AgentRoleTemplate.ID)
    case invalidTemplate([AgentOrchestrationValidationIssue])
}

// MARK: - Declarative graph

enum AgentOrchestrationAuthorization: String, Codable, Hashable {
    case deny
    case requireApproval
    case allow
}

enum AgentOrchestrationFlowKind: String, Codable, Hashable {
    case message
    case artifact
}

/// Policy for one kind of data flowing over an edge.
struct AgentOrchestrationFlowPolicy: Codable, Hashable {
    var authorization: AgentOrchestrationAuthorization
    var requiresAcknowledgement: Bool

    init(
        authorization: AgentOrchestrationAuthorization = .allow,
        requiresAcknowledgement: Bool = true
    ) {
        self.authorization = authorization
        self.requiresAcknowledgement = requiresAcknowledgement
    }

    static let allow = AgentOrchestrationFlowPolicy()
    static let requireApproval = AgentOrchestrationFlowPolicy(authorization: .requireApproval)
}

/// Default for communication not represented by an edge. Presets are closed
/// by default: their visible topology is also their effective allowlist.
struct AgentOrchestrationGraphPolicy: Codable, Hashable {
    var unlistedMessages: AgentOrchestrationAuthorization
    var unlistedArtifacts: AgentOrchestrationAuthorization

    init(
        unlistedMessages: AgentOrchestrationAuthorization = .deny,
        unlistedArtifacts: AgentOrchestrationAuthorization = .deny
    ) {
        self.unlistedMessages = unlistedMessages
        self.unlistedArtifacts = unlistedArtifacts
    }

    static let closed = AgentOrchestrationGraphPolicy()
}

struct AgentOrchestrationNode: Codable, Identifiable, Hashable {
    typealias ID = String

    /// Stable graph-local routing key, e.g. `planner` or `reviewer`.
    var id: ID
    /// Nil while a saved topology is still an unbound template.
    var conversationID: Conversation.ID?
    var role: AgentRoleAssignment

    init(id: ID, conversationID: Conversation.ID? = nil, role: AgentRoleAssignment) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
    }
}

/// A directed edge. Message and artifact rules are separate because a role may
/// be allowed to report text while needing approval to hand off files/patches.
/// A nil rule means that kind of flow is not provided by this edge.
struct AgentOrchestrationEdge: Codable, Hashable {
    var sourceNodeID: AgentOrchestrationNode.ID
    var targetNodeID: AgentOrchestrationNode.ID
    var message: AgentOrchestrationFlowPolicy?
    var artifact: AgentOrchestrationFlowPolicy?

    init(
        from sourceNodeID: AgentOrchestrationNode.ID,
        to targetNodeID: AgentOrchestrationNode.ID,
        message: AgentOrchestrationFlowPolicy? = nil,
        artifact: AgentOrchestrationFlowPolicy? = nil
    ) {
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.message = message
        self.artifact = artifact
    }
}

enum AgentOrchestrationPreset: String, Codable, CaseIterable, Hashable {
    case council
    case plannerExecutorReviewer
    case executorReviewerLoop
}

struct AgentOrchestrationGraph: Codable, Identifiable, Hashable {
    static let currentSchemaVersion = 1

    typealias ID = UUID

    var schemaVersion: Int
    var id: ID
    var title: String
    var preset: AgentOrchestrationPreset?
    var policy: AgentOrchestrationGraphPolicy
    var nodes: [AgentOrchestrationNode]
    var edges: [AgentOrchestrationEdge]

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: ID = UUID(),
        title: String,
        preset: AgentOrchestrationPreset? = nil,
        policy: AgentOrchestrationGraphPolicy = .closed,
        nodes: [AgentOrchestrationNode],
        edges: [AgentOrchestrationEdge]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.preset = preset
        self.policy = policy
        self.nodes = nodes
        self.edges = edges
    }

    var validationIssues: [AgentOrchestrationValidationIssue] {
        AgentOrchestrationValidator.validate(graph: self)
    }

    var isValid: Bool {
        !validationIssues.contains(where: { $0.severity == .error })
    }

    /// Resolves the effective rule for a declared pair of nodes. An absent
    /// edge falls back to the graph policy, making allow/deny behavior
    /// inspectable before any delivery is attempted.
    func flowPolicy(
        from sourceNodeID: AgentOrchestrationNode.ID,
        to targetNodeID: AgentOrchestrationNode.ID,
        kind: AgentOrchestrationFlowKind
    ) -> AgentOrchestrationFlowPolicy? {
        guard
            nodes.contains(where: { $0.id == sourceNodeID }),
            nodes.contains(where: { $0.id == targetNodeID })
        else { return nil }
        let edge = edges.first {
            $0.sourceNodeID == sourceNodeID && $0.targetNodeID == targetNodeID
        }
        let declared: AgentOrchestrationFlowPolicy?
        let fallback: AgentOrchestrationAuthorization
        switch kind {
        case .message:
            declared = edge?.message
            fallback = policy.unlistedMessages
        case .artifact:
            declared = edge?.artifact
            fallback = policy.unlistedArtifacts
        }
        return declared ?? AgentOrchestrationFlowPolicy(
            authorization: fallback,
            requiresAcknowledgement: false
        )
    }

    /// Conversation-bound lookup for Router/UI integration. Nil means one of
    /// the panes is not a node in this graph, not an implicit authorization.
    func flowPolicy(
        from sourceConversationID: Conversation.ID,
        to targetConversationID: Conversation.ID,
        kind: AgentOrchestrationFlowKind
    ) -> AgentOrchestrationFlowPolicy? {
        guard
            let source = nodes.first(where: { $0.conversationID == sourceConversationID }),
            let target = nodes.first(where: { $0.conversationID == targetConversationID })
        else { return nil }
        return flowPolicy(from: source.id, to: target.id, kind: kind)
    }

    func roleAssignment(for conversationID: Conversation.ID) -> AgentRoleAssignment? {
        nodes.first(where: { $0.conversationID == conversationID })?.role
    }

    mutating func bind(
        conversationID: Conversation.ID?,
        toNodeID nodeID: AgentOrchestrationNode.ID
    ) throws {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw AgentOrchestrationGraphError.unknownNode(nodeID)
        }
        if let conversationID,
           nodes.contains(where: { $0.id != nodeID && $0.conversationID == conversationID }) {
            throw AgentOrchestrationGraphError.conversationAlreadyBound(conversationID)
        }
        nodes[index].conversationID = conversationID
    }
}

enum AgentOrchestrationGraphError: Error, Equatable {
    case unknownNode(AgentOrchestrationNode.ID)
    case conversationAlreadyBound(Conversation.ID)
}

enum AgentOrchestrationPresets {
    /// N independent proposals converge on one aggregator. Ideators are
    /// intentionally inline roles: the four reusable built-ins remain the
    /// user's requested planner/executor/reviewer/aggregator vocabulary.
    static func council(ideatorCount requestedCount: Int = 3) -> AgentOrchestrationGraph {
        let ideatorCount = max(1, requestedCount)
        let ideatorRole = AgentRoleAssignment(
            roleName: "Ideator",
            instructions: "Develop an independent proposal. Send evidence, assumptions, and tradeoffs to the aggregator without forcing consensus."
        )
        let aggregator = AgentOrchestrationNode(
            id: "aggregator",
            role: AgentRoleAssignment(template: AgentRoleTemplateCatalog.aggregator)
        )
        let ideators = (1...ideatorCount).map {
            AgentOrchestrationNode(id: "ideator-\($0)", role: ideatorRole)
        }
        let edges = ideators.map {
            AgentOrchestrationEdge(
                from: $0.id,
                to: aggregator.id,
                message: .allow,
                artifact: .allow
            )
        }
        return AgentOrchestrationGraph(
            title: "Council",
            preset: .council,
            nodes: ideators + [aggregator],
            edges: edges
        )
    }

    static func plannerExecutorReviewer() -> AgentOrchestrationGraph {
        let nodes = [
            AgentOrchestrationNode(id: "planner", role: .init(template: AgentRoleTemplateCatalog.planner)),
            AgentOrchestrationNode(id: "executor", role: .init(template: AgentRoleTemplateCatalog.executor)),
            AgentOrchestrationNode(id: "reviewer", role: .init(template: AgentRoleTemplateCatalog.reviewer)),
        ]
        let edges = [
            AgentOrchestrationEdge(from: "planner", to: "executor", message: .allow, artifact: .allow),
            AgentOrchestrationEdge(from: "executor", to: "reviewer", message: .allow, artifact: .allow),
        ]
        return AgentOrchestrationGraph(
            title: "Plan → Execute → Review",
            preset: .plannerExecutorReviewer,
            nodes: nodes,
            edges: edges
        )
    }

    static func executorReviewerLoop() -> AgentOrchestrationGraph {
        let nodes = [
            AgentOrchestrationNode(id: "executor", role: .init(template: AgentRoleTemplateCatalog.executor)),
            AgentOrchestrationNode(id: "reviewer", role: .init(template: AgentRoleTemplateCatalog.reviewer)),
        ]
        let edges = [
            AgentOrchestrationEdge(from: "executor", to: "reviewer", message: .allow, artifact: .allow),
            AgentOrchestrationEdge(from: "reviewer", to: "executor", message: .allow, artifact: .allow),
        ]
        return AgentOrchestrationGraph(
            title: "Execute ↔ Review",
            preset: .executorReviewerLoop,
            nodes: nodes,
            edges: edges
        )
    }

    static func make(_ preset: AgentOrchestrationPreset) -> AgentOrchestrationGraph {
        switch preset {
        case .council:
            return council()
        case .plannerExecutorReviewer:
            return plannerExecutorReviewer()
        case .executorReviewerLoop:
            return executorReviewerLoop()
        }
    }
}

// MARK: - Workspace orchestration

/// Optional orchestration state persisted with a workspace. It can hold saved
/// topologies before any one of them is activated or bound to live panes.
struct WorkspaceOrchestration: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var roleTemplates: AgentRoleTemplateLibrary
    private(set) var graphs: [AgentOrchestrationGraph]
    private(set) var activeGraphID: AgentOrchestrationGraph.ID?

    init(
        schemaVersion: Int = currentSchemaVersion,
        roleTemplates: AgentRoleTemplateLibrary = AgentRoleTemplateLibrary(),
        graphs: [AgentOrchestrationGraph] = [],
        activeGraphID: AgentOrchestrationGraph.ID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.roleTemplates = roleTemplates
        self.graphs = graphs
        self.activeGraphID = activeGraphID
    }

    var activeGraph: AgentOrchestrationGraph? {
        guard let activeGraphID else { return nil }
        return graphs.first(where: { $0.id == activeGraphID })
    }

    mutating func saveGraph(_ graph: AgentOrchestrationGraph) throws {
        let availableIDs = Set(roleTemplates.allTemplates.map(\.id))
        let issues = AgentOrchestrationValidator.validate(
            graph: graph,
            availableRoleTemplateIDs: availableIDs
        ).filter { $0.severity == .error }
        guard issues.isEmpty else {
            throw WorkspaceOrchestrationError.invalidGraph(issues)
        }

        if let index = graphs.firstIndex(where: { $0.id == graph.id }) {
            graphs[index] = graph
        } else {
            graphs.append(graph)
        }
    }

    mutating func activateGraph(id: AgentOrchestrationGraph.ID?) throws {
        if let id, !graphs.contains(where: { $0.id == id }) {
            throw WorkspaceOrchestrationError.unknownGraph(id)
        }
        activeGraphID = id
    }

    @discardableResult
    mutating func removeGraph(id: AgentOrchestrationGraph.ID) -> AgentOrchestrationGraph? {
        guard let index = graphs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = graphs.remove(at: index)
        if activeGraphID == id {
            activeGraphID = nil
        }
        return removed
    }

    func validationIssues(
        workspaceConversationIDs: Set<Conversation.ID>? = nil
    ) -> [AgentOrchestrationValidationIssue] {
        AgentOrchestrationValidator.validate(
            orchestration: self,
            workspaceConversationIDs: workspaceConversationIDs
        )
    }
}

enum WorkspaceOrchestrationError: Error, Equatable {
    case invalidGraph([AgentOrchestrationValidationIssue])
    case unknownGraph(AgentOrchestrationGraph.ID)
}

// MARK: - Deterministic validation

struct AgentOrchestrationValidationIssue: Codable, Hashable {
    enum Severity: String, Codable, Hashable {
        case error
        case warning
    }

    enum Code: String, Codable, Hashable {
        case unsupportedSchemaVersion
        case invalidIdentifier
        case emptyTemplateName
        case emptyInstructions
        case duplicateTemplateID
        case builtInTemplateIDCollision
        case emptyGraphTitle
        case emptyGraph
        case duplicateGraphID
        case unknownActiveGraph
        case duplicateNodeID
        case duplicateConversationBinding
        case conversationOutsideWorkspace
        case unknownRoleTemplate
        case selfEdge
        case unknownSourceNode
        case unknownTargetNode
        case duplicateEdge
        case emptyEdge
    }

    var severity: Severity
    var code: Code
    /// Stable machine-readable location, suitable for UI field highlighting.
    var path: String
    var message: String
}

enum AgentOrchestrationValidator {
    static func validate(template: AgentRoleTemplate) -> [AgentOrchestrationValidationIssue] {
        var issues: [AgentOrchestrationValidationIssue] = []
        if !isValidIdentifier(template.id) {
            issues.append(issue(.invalidIdentifier, path: "template.id", "Template ID must use lowercase letters, digits, '.', '_' or '-'."))
        }
        if isBlank(template.displayName) {
            issues.append(issue(.emptyTemplateName, path: "template.displayName", "Template display name must not be empty."))
        }
        if isBlank(template.instructions) {
            issues.append(issue(.emptyInstructions, path: "template.instructions", "Template instructions must not be empty."))
        }
        return sorted(issues)
    }

    static func validate(
        graph: AgentOrchestrationGraph,
        availableRoleTemplateIDs: Set<AgentRoleTemplate.ID> = AgentRoleTemplateCatalog.builtInIDs,
        workspaceConversationIDs: Set<Conversation.ID>? = nil
    ) -> [AgentOrchestrationValidationIssue] {
        var issues: [AgentOrchestrationValidationIssue] = []
        if graph.schemaVersion != AgentOrchestrationGraph.currentSchemaVersion {
            issues.append(issue(
                .unsupportedSchemaVersion,
                path: "graph.schemaVersion",
                "Unsupported graph schema version \(graph.schemaVersion)."
            ))
        }
        if isBlank(graph.title) {
            issues.append(issue(.emptyGraphTitle, path: "graph.title", "Graph title must not be empty."))
        }
        if graph.nodes.isEmpty {
            issues.append(issue(.emptyGraph, path: "graph.nodes", "Graph must contain at least one node."))
        }

        var nodeIDs = Set<AgentOrchestrationNode.ID>()
        var conversationIDs = Set<Conversation.ID>()
        for (index, node) in graph.nodes.enumerated() {
            let nodePath = "graph.nodes[\(index)]"
            if !isValidIdentifier(node.id) {
                issues.append(issue(.invalidIdentifier, path: "\(nodePath).id", "Node ID is invalid."))
            }
            if !nodeIDs.insert(node.id).inserted {
                issues.append(issue(.duplicateNodeID, path: "\(nodePath).id", "Duplicate node ID '\(node.id)'."))
            }
            if isBlank(node.role.roleName) {
                issues.append(issue(.emptyTemplateName, path: "\(nodePath).role.roleName", "Role name must not be empty."))
            }
            if isBlank(node.role.instructions) {
                issues.append(issue(.emptyInstructions, path: "\(nodePath).role.instructions", "Role instructions must not be empty."))
            }
            if let templateID = node.role.templateID,
               !availableRoleTemplateIDs.contains(templateID) {
                issues.append(issue(
                    .unknownRoleTemplate,
                    severity: .warning,
                    path: "\(nodePath).role.templateID",
                    "Role snapshot references unavailable template '\(templateID)'."
                ))
            }
            if let conversationID = node.conversationID {
                if !conversationIDs.insert(conversationID).inserted {
                    issues.append(issue(
                        .duplicateConversationBinding,
                        path: "\(nodePath).conversationID",
                        "A conversation can bind to only one node in a graph."
                    ))
                }
                if let workspaceConversationIDs,
                   !workspaceConversationIDs.contains(conversationID) {
                    issues.append(issue(
                        .conversationOutsideWorkspace,
                        path: "\(nodePath).conversationID",
                        "Bound conversation is not part of this workspace."
                    ))
                }
            }
        }

        var edgeKeys = Set<String>()
        for (index, edge) in graph.edges.enumerated() {
            let edgePath = "graph.edges[\(index)]"
            if edge.sourceNodeID == edge.targetNodeID {
                issues.append(issue(.selfEdge, path: edgePath, "Self-edges are not allowed."))
            }
            if !nodeIDs.contains(edge.sourceNodeID) {
                issues.append(issue(.unknownSourceNode, path: "\(edgePath).sourceNodeID", "Source node does not exist."))
            }
            if !nodeIDs.contains(edge.targetNodeID) {
                issues.append(issue(.unknownTargetNode, path: "\(edgePath).targetNodeID", "Target node does not exist."))
            }
            let key = "\(edge.sourceNodeID)\u{0}\(edge.targetNodeID)"
            if !edgeKeys.insert(key).inserted {
                issues.append(issue(.duplicateEdge, path: edgePath, "Duplicate directed edge."))
            }
            if edge.message == nil, edge.artifact == nil {
                issues.append(issue(.emptyEdge, path: edgePath, "Edge must define a message or artifact policy."))
            }
        }
        return sorted(issues)
    }

    static func validate(
        orchestration: WorkspaceOrchestration,
        workspaceConversationIDs: Set<Conversation.ID>? = nil
    ) -> [AgentOrchestrationValidationIssue] {
        var issues: [AgentOrchestrationValidationIssue] = []
        if orchestration.schemaVersion != WorkspaceOrchestration.currentSchemaVersion {
            issues.append(issue(
                .unsupportedSchemaVersion,
                path: "orchestration.schemaVersion",
                "Unsupported workspace orchestration schema version \(orchestration.schemaVersion)."
            ))
        }

        var templateIDs = AgentRoleTemplateCatalog.builtInIDs
        for (index, template) in orchestration.roleTemplates.customTemplates.enumerated() {
            for var templateIssue in validate(template: template) {
                templateIssue.path = templateIssue.path.replacingOccurrences(
                    of: "template",
                    with: "orchestration.roleTemplates.customTemplates[\(index)]",
                    options: [.anchored]
                )
                issues.append(templateIssue)
            }
            if AgentRoleTemplateCatalog.builtInIDs.contains(template.id) {
                issues.append(issue(
                    .builtInTemplateIDCollision,
                    path: "orchestration.roleTemplates.customTemplates[\(index)].id",
                    "Custom template cannot replace built-in template '\(template.id)'."
                ))
            }
            if !templateIDs.insert(template.id).inserted,
               !AgentRoleTemplateCatalog.builtInIDs.contains(template.id) {
                issues.append(issue(
                    .duplicateTemplateID,
                    path: "orchestration.roleTemplates.customTemplates[\(index)].id",
                    "Duplicate custom template ID '\(template.id)'."
                ))
            }
        }

        var graphIDs = Set<AgentOrchestrationGraph.ID>()
        for (index, graph) in orchestration.graphs.enumerated() {
            if !graphIDs.insert(graph.id).inserted {
                issues.append(issue(
                    .duplicateGraphID,
                    path: "orchestration.graphs[\(index)].id",
                    "Duplicate graph ID '\(graph.id.uuidString)'."
                ))
            }
            for var graphIssue in validate(
                graph: graph,
                availableRoleTemplateIDs: templateIDs,
                workspaceConversationIDs: workspaceConversationIDs
            ) {
                graphIssue.path = graphIssue.path.replacingOccurrences(
                    of: "graph",
                    with: "orchestration.graphs[\(index)]",
                    options: [.anchored]
                )
                issues.append(graphIssue)
            }
        }

        if let activeGraphID = orchestration.activeGraphID,
           !graphIDs.contains(activeGraphID) {
            issues.append(issue(
                .unknownActiveGraph,
                path: "orchestration.activeGraphID",
                "Active graph does not exist in this workspace."
            ))
        }
        return sorted(issues)
    }

    private static func issue(
        _ code: AgentOrchestrationValidationIssue.Code,
        severity: AgentOrchestrationValidationIssue.Severity = .error,
        path: String,
        _ message: String
    ) -> AgentOrchestrationValidationIssue {
        AgentOrchestrationValidationIssue(
            severity: severity,
            code: code,
            path: path,
            message: message
        )
    }

    private static func sorted(
        _ issues: [AgentOrchestrationValidationIssue]
    ) -> [AgentOrchestrationValidationIssue] {
        issues.sorted {
            ($0.path, $0.code.rawValue, $0.severity.rawValue, $0.message)
                < ($1.path, $1.code.rawValue, $1.severity.rawValue, $1.message)
        }
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.lowercased() else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
