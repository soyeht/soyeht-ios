//
//  AgentMessagingSettingsViews.swift
//  Soyeht
//

import AppKit
import SoyehtCore

@MainActor
final class AgentMessagingPolicyAccessoryView: NSView {
    enum ReceiveMode: Int {
        case everyone = 0
        case sameWorkspace = 1
        case nobody = 2
    }

    private let receivePopup = NSPopUpButton()
    private var blockButtons: [(button: NSButton, paneID: Conversation.ID)] = []

    var receiveMode: ReceiveMode {
        ReceiveMode(rawValue: receivePopup.indexOfSelectedItem) ?? .everyone
    }

    var blockedPaneIDs: Set<Conversation.ID> {
        Set(blockButtons.compactMap { $0.button.state == .on ? $0.paneID : nil })
    }

    init(
        conversation: Conversation,
        candidates: [Conversation],
        workspaceName: (Workspace.ID) -> String
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: max(150, 88 + candidates.count * 23)))
        receivePopup.addItems(withTitles: [
            "Everyone",
            "Only this workspace",
            "Nobody",
        ])
        if !conversation.agentCommunicationPolicy.incoming.isEnabled {
            receivePopup.selectItem(at: ReceiveMode.nobody.rawValue)
        } else if !conversation.agentCommunicationPolicy.incoming.allowsCrossWorkspace {
            receivePopup.selectItem(at: ReceiveMode.sameWorkspace.rawValue)
        } else {
            receivePopup.selectItem(at: ReceiveMode.everyone.rawValue)
        }

        let receiveLabel = NSTextField(labelWithString: "Who can message this agent")
        receiveLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let blockLabel = NSTextField(labelWithString: "Blocked agents")
        blockLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let blockViews: [NSView]
        if candidates.isEmpty {
            let empty = NSTextField(labelWithString: "No other terminal agents are available.")
            empty.textColor = .secondaryLabelColor
            blockViews = [empty]
        } else {
            blockViews = candidates.map { candidate in
                let endpoint = AgentMessageEndpoint(
                    paneID: candidate.id,
                    workspaceID: candidate.workspaceID,
                    handle: candidate.handle
                )
                let button = NSButton(
                    checkboxWithTitle: "\(endpoint.displayLabel) — \(workspaceName(candidate.workspaceID))",
                    target: nil,
                    action: nil
                )
                button.state = conversation.agentCommunicationPolicy.incoming.blockedPaneIDs.contains(candidate.id)
                    ? .on : .off
                blockButtons.append((button, candidate.id))
                return button
            }
        }
        let blockStack = NSStackView(views: blockViews)
        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.spacing = 3

        let stack = NSStackView(views: [receiveLabel, receivePopup, blockLabel, blockStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            receivePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}
@MainActor
final class AgentRoleOrchestrationAccessoryView: NSView {
    private static let noneRoleID = "ui.none"
    private static let newRoleID = "ui.new-custom"

    private let rolePopup = NSPopUpButton()
    private let roleNameField = NSTextField()
    private let instructionsView = NSTextView()
    private let presetPopup = NSPopUpButton()
    private let managerAuthorizationCheckbox = NSButton(
        checkboxWithTitle: "Allow this agent to manage roles and topology in this workspace",
        target: nil,
        action: nil
    )
    private let templates: [AgentRoleTemplate]

    var isManagementAuthorized: Bool {
        managerAuthorizationCheckbox.state == .on
    }

    var selectedPreset: AgentOrchestrationPreset? {
        guard let raw = presetPopup.selectedItem?.representedObject as? String else { return nil }
        return AgentOrchestrationPreset(rawValue: raw)
    }

    init(
        conversationID: Conversation.ID,
        assignment: AgentRoleAssignment?,
        orchestration: WorkspaceOrchestration?
    ) {
        self.templates = orchestration?.roleTemplates.allTemplates ?? AgentRoleTemplateCatalog.builtIn
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 340))

        addPopupItem(title: "No role", represented: Self.noneRoleID, to: rolePopup)
        for template in templates {
            addPopupItem(title: template.displayName, represented: template.id, to: rolePopup)
        }
        addPopupItem(title: "New custom template…", represented: Self.newRoleID, to: rolePopup)
        rolePopup.target = self
        rolePopup.action = #selector(roleSelectionChanged)

        roleNameField.placeholderString = "Role name"
        instructionsView.isRichText = false
        instructionsView.font = .systemFont(ofSize: NSFont.systemFontSize)
        let instructionScroll = NSScrollView()
        instructionScroll.hasVerticalScroller = true
        instructionScroll.borderType = .bezelBorder
        instructionScroll.documentView = instructionsView
        instructionScroll.translatesAutoresizingMaskIntoConstraints = false
        instructionScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        instructionScroll.widthAnchor.constraint(equalToConstant: 540).isActive = true

        addPopupItem(title: "No active topology", represented: "", to: presetPopup)
        addPopupItem(title: "Council (N ideas → aggregator)", represented: AgentOrchestrationPreset.council.rawValue, to: presetPopup)
        addPopupItem(title: "Plan → Execute → Review", represented: AgentOrchestrationPreset.plannerExecutorReviewer.rawValue, to: presetPopup)
        addPopupItem(title: "Execute ↔ Review", represented: AgentOrchestrationPreset.executorReviewerLoop.rawValue, to: presetPopup)
        managerAuthorizationCheckbox.state = orchestration?.canManageRolesAndTopology(conversationID) == true
            ? .on
            : .off
        managerAuthorizationCheckbox.toolTip = "Only the user can grant or revoke this privilege. Multiple agents may be authorized."

        let stack = NSStackView(views: [
            sectionLabel("Role template"), rolePopup,
            sectionLabel("Role name"), roleNameField,
            sectionLabel("Instructions"), instructionScroll,
            sectionLabel("Workspace topology"), presetPopup,
            managerAuthorizationCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rolePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            roleNameField.widthAnchor.constraint(equalToConstant: 540),
            presetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        if let assignment,
           let index = templates.firstIndex(where: { $0.id == assignment.templateID }) {
            rolePopup.selectItem(at: index + 1)
            roleNameField.stringValue = assignment.roleName
            instructionsView.string = assignment.instructions
        } else if let assignment {
            rolePopup.selectItem(withTitle: "New custom template…")
            roleNameField.stringValue = assignment.roleName
            instructionsView.string = assignment.instructions
        } else {
            rolePopup.selectItem(at: 0)
        }
        if let preset = orchestration?.activeGraph?.preset,
           let item = presetPopup.itemArray.first(where: {
               ($0.representedObject as? String) == preset.rawValue
           }) {
            presetPopup.select(item)
        }
        updateRoleFieldEditability()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func resolvedAssignment(
        updating orchestration: inout WorkspaceOrchestration
    ) throws -> AgentRoleAssignment? {
        guard let selected = rolePopup.selectedItem?.representedObject as? String else { return nil }
        if selected == Self.noneRoleID { return nil }
        if selected == Self.newRoleID {
            let name = roleNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let instructions = instructionsView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = name.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let template = AgentRoleTemplate(
                id: "custom.\(slug.isEmpty ? UUID().uuidString.lowercased() : slug)",
                displayName: name,
                instructions: instructions
            )
            try orchestration.roleTemplates.save(template)
            return AgentRoleAssignment(template: template)
        }
        guard let template = orchestration.roleTemplates.template(id: selected)
            ?? AgentRoleTemplateCatalog.template(id: selected) else { return nil }
        if AgentRoleTemplateCatalog.builtInIDs.contains(selected) {
            return AgentRoleAssignment(template: template)
        }
        let updated = AgentRoleTemplate(
            id: selected,
            displayName: roleNameField.stringValue,
            instructions: instructionsView.string
        )
        try orchestration.roleTemplates.save(updated)
        return AgentRoleAssignment(template: updated)
    }

    @objc private func roleSelectionChanged() {
        guard let selected = rolePopup.selectedItem?.representedObject as? String else { return }
        if let template = templates.first(where: { $0.id == selected }) {
            roleNameField.stringValue = template.displayName
            instructionsView.string = template.instructions
        } else if selected == Self.noneRoleID {
            roleNameField.stringValue = ""
            instructionsView.string = ""
        } else {
            roleNameField.stringValue = ""
            instructionsView.string = ""
        }
        updateRoleFieldEditability()
    }

    private func updateRoleFieldEditability() {
        let selected = rolePopup.selectedItem?.representedObject as? String
        let editable = selected == Self.newRoleID
            || (selected.map { !AgentRoleTemplateCatalog.builtInIDs.contains($0) && $0 != Self.noneRoleID } ?? false)
        roleNameField.isEditable = editable
        instructionsView.isEditable = editable
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private func addPopupItem(title: String, represented: String, to popup: NSPopUpButton) {
        popup.addItem(withTitle: title)
        popup.lastItem?.representedObject = represented
    }
}
