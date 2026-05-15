import AppKit
import SoyehtCore
import os

/// Result surfaced to the presenter when the user taps "Create".
/// Phase 6 scope: pure UI + validation. Phase 7 wires this into ConversationStore +
/// WebSocket URL building + pane binding.
struct NewConversationRequest {
    let handle: String
    let agent: AgentType
    let workspaceID: Workspace.ID?
    let workspaceName: String
    let projectPath: URL?
    let useWorktree: Bool
    /// Server container to host the tmux session. Required to actually connect
    /// the terminal — nil means the user didn't pick an instance and the pane
    /// will stay in the "no instance attached" placeholder state.
    let instanceContainer: String?
    /// Optional existing tmux sessionId to attach to. When nil the presenter
    /// calls `createWorkspace` to mint a fresh session.
    let attachSessionId: String?
}

/// Modal-sheet controller for creating a new Conversation.
/// Presented via `presentAsSheet` from `SoyehtMainWindowController`.
@MainActor
final class NewConversationSheetController: NSViewController {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "newconv.sheet")

    let store: WorkspaceStore
    let windowID: String

    /// Called with the collected request when the user taps Create. Caller is
    /// responsible for dismissing the sheet (`dismiss(self)`).
    var onCreate: ((NewConversationRequest) -> Void)?

    // MARK: - UI
    private let handleField = NSTextField()
    private let agentPopup = NSPopUpButton()
    private let workspacePopup = NSPopUpButton()
    private let instancePopup = NSPopUpButton()
    private let sessionPopup = NSPopUpButton()
    private let instanceStatus = NSTextField(labelWithString: String(localized: "newconv.status.loadingInstances", comment: "Inline status shown while listing available instances for the new-conversation sheet."))
    private let pathField = NSTextField(labelWithString: String(localized: "newconv.status.noFolder", comment: "Shown next to the Choose… button when no project folder has been selected."))
    private let choosePathButton = NSButton(title: String(localized: "newconv.button.choose", comment: "Button that opens the NSOpenPanel to pick a project folder."), target: nil, action: nil)
    private let worktreeCheckbox = NSButton(checkboxWithTitle: String(localized: "newconv.checkbox.worktree", comment: "Checkbox — create the workspace as a git-worktree (isolated branch checkout)."), target: nil, action: nil)
    private let createButton = NSButton(title: String(localized: "common.button.create", comment: "Generic Create."), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "common.button.cancel", comment: "Generic Cancel."), target: nil, action: nil)

    private var selectedPath: URL?
    private var instances: [SoyehtInstance] = []
    /// Sessions for the currently selected instance. First entry (tag 0) is
    /// the synthetic "Create new session" option; others are real sessionIds.
    private var sessions: [SoyehtWorkspace] = []

    init(store: WorkspaceStore, windowID: String) {
        self.store = store
        self.windowID = windowID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
        root.wantsLayer = true
        self.view = root
        buildUI()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: String(localized: "newconv.title", comment: "Header of the New Conversation sheet."))
        title.font = MacTypography.NSFonts.sheetTitle

        handleField.placeholderString = String(localized: "newconv.placeholder.handle", comment: "Placeholder showing the handle format (leading @).")
        handleField.font = MacTypography.NSFonts.sheetInput

        for agent in AgentType.canonicalCases {
            agentPopup.addItem(withTitle: agent.displayName)
        }

        workspacePopup.removeAllItems()
        workspacePopup.addItem(withTitle: String(localized: "newconv.workspace.new", comment: "First option in the workspace picker — creates a new workspace."))
        for ws in store.orderedWorkspaces(in: windowID) {
            workspacePopup.addItem(withTitle: ws.name)
            workspacePopup.lastItem?.representedObject = ws.id
        }

        instancePopup.target = self
        instancePopup.action = #selector(instanceChanged(_:))
        instancePopup.addItem(withTitle: String(localized: "common.status.loading", comment: "Generic Loading… placeholder in a picker."))
        instancePopup.isEnabled = false

        sessionPopup.removeAllItems()
        sessionPopup.addItem(withTitle: String(localized: "newconv.session.createNew", comment: "First option in the session picker — mints a fresh tmux session."))
        sessionPopup.lastItem?.representedObject = nil
        sessionPopup.isEnabled = false

        instanceStatus.font = MacTypography.NSFonts.sheetStatus
        instanceStatus.textColor = .tertiaryLabelColor

        choosePathButton.target = self
        choosePathButton.action = #selector(choosePath(_:))

        createButton.target = self
        createButton.action = #selector(createTapped(_:))
        createButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let handleLabel    = label(String(localized: "newconv.field.handle", comment: "Field label — conversation @handle."))
        let agentLabel     = label(String(localized: "newconv.field.agent", comment: "Field label — agent type picker."))
        let workspaceLabel = label(String(localized: "newconv.field.workspace", comment: "Field label — destination workspace."))
        let instanceLabel  = label(String(localized: "newconv.field.instance", comment: "Field label — server instance picker."))
        let sessionLabel   = label(String(localized: "newconv.field.session", comment: "Field label — tmux session picker."))
        let pathLabel      = label(String(localized: "newconv.field.projectFolder", comment: "Field label — selected project folder."))

        let pathRow = NSStackView(views: [pathField, choosePathButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [NSView(), cancelButton, createButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let form = NSStackView(views: [
            title,
            handleLabel,    handleField,
            agentLabel,     agentPopup,
            workspaceLabel, workspacePopup,
            instanceLabel,  instancePopup,
            sessionLabel,   sessionPopup,
            instanceStatus,
            pathLabel,      pathRow,
            worktreeCheckbox,
            actions,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            handleField.widthAnchor.constraint(equalToConstant: 360),
            agentPopup.widthAnchor.constraint(equalToConstant: 220),
            workspacePopup.widthAnchor.constraint(equalToConstant: 320),
            instancePopup.widthAnchor.constraint(equalToConstant: 420),
            sessionPopup.widthAnchor.constraint(equalToConstant: 420),
            actions.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadInstances()
    }

    private func loadInstances() {
        Task { @MainActor in
            do {
                let list = try await SoyehtAPIClient.shared.getInstances()
                self.instances = list.filter { $0.isOnline }
                self.instancePopup.removeAllItems()
                if self.instances.isEmpty {
                    self.instancePopup.addItem(withTitle: String(localized: "newconv.instance.noneAvailable", comment: "Picker item shown when the server returned zero online instances."))
                    self.instancePopup.isEnabled = false
                    self.instanceStatus.stringValue = String(localized: "newconv.status.pairFirst", comment: "Hint shown when there are no instances — user must pair one on the server.")
                    self.instanceStatus.textColor = .systemOrange
                } else {
                    for inst in self.instances {
                        self.instancePopup.addItem(withTitle: "\(inst.name) \(inst.displayTag)")
                        self.instancePopup.lastItem?.representedObject = inst.container
                    }
                    self.instancePopup.isEnabled = true
                    self.instanceStatus.stringValue = ""
                    self.loadSessions(for: self.instances[0].container)
                }
            } catch {
                self.instancePopup.removeAllItems()
                self.instancePopup.addItem(withTitle: String(localized: "common.status.error", comment: "Generic Error label in a picker that failed to populate."))
                self.instancePopup.isEnabled = false
                self.instanceStatus.stringValue = String(
                    localized: "newconv.status.loadFailed",
                    defaultValue: "Failed to load: \(error.localizedDescription)",
                    comment: "Error shown when instance listing failed. %@ = underlying error."
                )
                self.instanceStatus.textColor = .systemRed
            }
        }
    }

    @objc private func instanceChanged(_ sender: Any?) {
        guard let container = instancePopup.selectedItem?.representedObject as? String else { return }
        loadSessions(for: container)
    }

    private func loadSessions(for container: String) {
        sessionPopup.removeAllItems()
        sessionPopup.addItem(withTitle: "Create new session")
        sessionPopup.lastItem?.representedObject = nil
        sessionPopup.isEnabled = true
        Task { @MainActor in
            do {
                let list = try await SoyehtAPIClient.shared.listWorkspaces(container: container)
                self.sessions = list
                for ws in list {
                    self.sessionPopup.addItem(withTitle: ws.displayName)
                    self.sessionPopup.lastItem?.representedObject = ws.sessionId
                }
            } catch {
                Self.logger.warning("listWorkspaces failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func label(_ s: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: s)
        lbl.font = MacTypography.NSFonts.sheetFieldLabel
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    // MARK: - Actions

    @objc private func choosePath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "newconv.openPanel.prompt", comment: "Confirm button in the folder chooser — 'Choose'.")
        panel.message = String(localized: "newconv.openPanel.message", comment: "Prompt at the top of the folder chooser.")
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectedPath = url
            self?.pathField.stringValue = url.path
        }
    }

    @objc private func cancelTapped(_ sender: Any?) {
        presentingViewController?.dismiss(self)
    }

    @objc private func createTapped(_ sender: Any?) {
        let rawHandle = handleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHandle.isEmpty else {
            flashInvalid(handleField)
            return
        }
        let handle = rawHandle.hasPrefix("@") ? rawHandle : "@\(rawHandle)"
        let agent = AgentType.canonicalCases[agentPopup.indexOfSelectedItem]
        let wsID  = workspacePopup.selectedItem?.representedObject as? Workspace.ID
        let wsName = workspacePopup.indexOfSelectedItem == 0
            ? String(localized: "newconv.workspace.defaultName", comment: "Default workspace name when the user picked 'New workspace…' without typing one.")
            : (workspacePopup.selectedItem?.title ?? String(localized: "newconv.workspace.defaultName", comment: "Default workspace name fallback."))

        let container = instancePopup.selectedItem?.representedObject as? String
        let attachSessionId = sessionPopup.selectedItem?.representedObject as? String
        let req = NewConversationRequest(
            handle: handle,
            agent: agent,
            workspaceID: wsID,
            workspaceName: wsName,
            projectPath: selectedPath,
            useWorktree: worktreeCheckbox.state == .on,
            instanceContainer: container,
            attachSessionId: attachSessionId
        )
        Self.logger.info("create tapped: handle=\(handle, privacy: .public) agent=\(agent.displayName, privacy: .public)")
        onCreate?(req)
        presentingViewController?.dismiss(self)
    }

    private func flashInvalid(_ field: NSTextField) {
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = NSColor.systemRed.cgColor
        field.becomeFirstResponder()
    }
}
