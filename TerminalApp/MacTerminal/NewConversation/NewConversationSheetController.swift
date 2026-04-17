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

    /// Called with the collected request when the user taps Create. Caller is
    /// responsible for dismissing the sheet (`dismiss(self)`).
    var onCreate: ((NewConversationRequest) -> Void)?

    // MARK: - UI
    private let handleField = NSTextField()
    private let agentPopup = NSPopUpButton()
    private let workspacePopup = NSPopUpButton()
    private let instancePopup = NSPopUpButton()
    private let sessionPopup = NSPopUpButton()
    private let instanceStatus = NSTextField(labelWithString: "Loading instances…")
    private let pathField = NSTextField(labelWithString: "No folder selected")
    private let choosePathButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let worktreeCheckbox = NSButton(checkboxWithTitle: "Create as worktree workspace", target: nil, action: nil)
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var selectedPath: URL?
    private var instances: [SoyehtInstance] = []
    /// Sessions for the currently selected instance. First entry (tag 0) is
    /// the synthetic "Create new session" option; others are real sessionIds.
    private var sessions: [SoyehtWorkspace] = []

    init(store: WorkspaceStore) {
        self.store = store
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
        let title = NSTextField(labelWithString: "New Conversation")
        title.font = Typography.monoNSFont(size: 20, weight: .semibold)

        handleField.placeholderString = "@handle (e.g. @auth-refactor)"
        handleField.font = Typography.monoNSFont(size: 14, weight: .regular)

        for agent in AgentType.allCases {
            agentPopup.addItem(withTitle: agent.displayName)
        }

        workspacePopup.removeAllItems()
        workspacePopup.addItem(withTitle: "New workspace…")
        for ws in store.orderedWorkspaces {
            workspacePopup.addItem(withTitle: ws.name)
            workspacePopup.lastItem?.representedObject = ws.id
        }

        instancePopup.target = self
        instancePopup.action = #selector(instanceChanged(_:))
        instancePopup.addItem(withTitle: "Loading…")
        instancePopup.isEnabled = false

        sessionPopup.removeAllItems()
        sessionPopup.addItem(withTitle: "Create new session")
        sessionPopup.lastItem?.representedObject = nil
        sessionPopup.isEnabled = false

        instanceStatus.font = Typography.monoNSFont(size: 11, weight: .regular)
        instanceStatus.textColor = .tertiaryLabelColor

        choosePathButton.target = self
        choosePathButton.action = #selector(choosePath(_:))

        createButton.target = self
        createButton.action = #selector(createTapped(_:))
        createButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let handleLabel    = label("Handle")
        let agentLabel     = label("Agent")
        let workspaceLabel = label("Workspace")
        let instanceLabel  = label("Instance")
        let sessionLabel   = label("Session")
        let pathLabel      = label("Project folder")

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
                    self.instancePopup.addItem(withTitle: "No instances available")
                    self.instancePopup.isEnabled = false
                    self.instanceStatus.stringValue = "Pair an instance on the server first."
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
                self.instancePopup.addItem(withTitle: "Error")
                self.instancePopup.isEnabled = false
                self.instanceStatus.stringValue = "Failed to load: \(error.localizedDescription)"
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
        lbl.font = Typography.monoNSFont(size: 11, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    // MARK: - Actions

    @objc private func choosePath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the project folder for this conversation"
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
        let agent = AgentType.allCases[agentPopup.indexOfSelectedItem]
        let wsID  = workspacePopup.selectedItem?.representedObject as? Workspace.ID
        let wsName = workspacePopup.indexOfSelectedItem == 0
            ? "Workspace"
            : (workspacePopup.selectedItem?.title ?? "Workspace")

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
