//
//  InstancePickerViewController.swift
//  MacTerminal
//
//  NSPopover content for picking a Soyeht instance and opening it as a tab.
//  Mirrors the iOS attachToWorkspace() logic: list workspaces for the instance;
//  if none exist, call createWorkspace(); use the sessionId in buildWebSocketURL.
//

import Cocoa
import SoyehtCore

/// NSTableView subclass that opens the selected row when Return is pressed.
private class InstanceTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { // Return or numpad Enter
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

class InstancePickerViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

    private var instances: [SoyehtInstance] = []
    private var isLoading = false

    private let tableView = InstanceTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Loading instances...")
    private let spinner = NSProgressIndicator()
    private var serverPopUp: NSPopUpButton?

    // Called after an instance tab is opened so the popover can close
    var onDismiss: (() -> Void)?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 320, height: 340))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Show cached instances immediately, then refresh from network
        let cached = SoyehtAPIClient.shared.store.loadInstances()
        if !cached.isEmpty {
            instances = cached.filter { $0.isOnline }
            tableView.reloadData()
            statusLabel.stringValue = "\(instances.count) instance(s)"
            selectFirstRowIfNeeded()
        }
        loadInstances()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Give the table first-responder status so keyboard navigation works
        view.window?.makeFirstResponder(tableView)
    }

    private func selectFirstRowIfNeeded() {
        if tableView.selectedRow < 0, !instances.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func buildUI() {
        // Server picker (if multiple servers)
        let store = SessionStore.shared
        if store.pairedServers.count > 1 {
            let popUp = NSPopUpButton()
            popUp.translatesAutoresizingMaskIntoConstraints = false
            for server in store.pairedServers {
                popUp.addItem(withTitle: server.name)
            }
            if let active = store.activeServer,
               let idx = store.pairedServers.firstIndex(where: { $0.id == active.id }) {
                popUp.selectItem(at: idx)
            }
            popUp.target = self
            popUp.action = #selector(serverChanged(_:))
            view.addSubview(popUp)
            serverPopUp = popUp

            NSLayoutConstraint.activate([
                popUp.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                popUp.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                popUp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            ])
        }

        // Table
        let column = NSTableColumn(identifier: .init("instance"))
        column.title = "Instances"
        column.width = 280
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.onReturn = { [weak self] in self?.instanceDoubleTapped() }
        tableView.doubleAction = #selector(instanceDoubleTapped)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(statusLabel)

        // Spinner
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        view.addSubview(spinner)

        // Open button — Return key triggers it
        let openButton = NSButton(title: "Open Tab", target: self, action: #selector(instanceDoubleTapped))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(openButton)

        let topAnchor = serverPopUp?.bottomAnchor ?? view.topAnchor
        let topConstant: CGFloat = serverPopUp != nil ? 4 : 8

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -4),

            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            openButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            openButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    // MARK: - Data Loading

    private func loadInstances() {
        guard !isLoading else { return }
        isLoading = true
        statusLabel.stringValue = "Loading instances..."
        spinner.isHidden = false
        spinner.startAnimation(nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await SoyehtAPIClient.shared.getInstances()
                await MainActor.run {
                    self.isLoading = false
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.instances = list.filter { $0.isOnline }
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = self.instances.isEmpty
                        ? "No online instances" : "\(self.instances.count) instance(s)"
                    self.selectFirstRowIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    if self.isAuthError(error) {
                        self.statusLabel.stringValue = "Session expired — re-login required"
                        self.onDismiss?()
                        (NSApp.delegate as? AppDelegate)?.showLoginSheet()
                    } else {
                        self.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func isAuthError(_ error: Error) -> Bool {
        if case SoyehtAPIClient.APIError.httpError(let code, _) = error, code == 401 { return true }
        if case SoyehtAPIClient.APIError.noSession = error { return true }
        return false
    }

    @objc private func serverChanged(_ sender: NSPopUpButton) {
        let store = SessionStore.shared
        let selectedIdx = sender.indexOfSelectedItem
        guard selectedIdx >= 0 && selectedIdx < store.pairedServers.count else { return }
        let server = store.pairedServers[selectedIdx]
        store.setActiveServer(id: server.id)
        instances = []
        tableView.reloadData()
        loadInstances()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        instances.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let instance = instances[row]
        let cell = tableView.makeView(withIdentifier: .init("instanceCell"), owner: nil)
            as? NSTableCellView
            ?? NSTableCellView()

        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
        }

        let statusIcon = instance.isOnline ? "●" : "○"
        cell.textField?.stringValue = "\(statusIcon) \(instance.name)"
        cell.identifier = .init("instanceCell")
        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // MARK: - Open Instance

    @objc private func instanceDoubleTapped() {
        let row = tableView.selectedRow
        guard row >= 0, row < instances.count else { return }
        let instance = instances[row]
        openInstance(instance)
    }

    private func openInstance(_ instance: SoyehtInstance) {
        statusLabel.stringValue = "Connecting..."
        spinner.isHidden = false
        spinner.startAnimation(nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let wsURL = try await self.resolveWorkspaceURL(for: instance) else {
                    // User cancelled the workspace picker — reset UI
                    await MainActor.run {
                        self.spinner.stopAnimation(nil)
                        self.spinner.isHidden = true
                        self.statusLabel.stringValue = "\(self.instances.count) instance(s)"
                    }
                    return
                }
                await MainActor.run {
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.statusLabel.stringValue = ""
                    (NSApp.delegate as? AppDelegate)?.openSoyehtTab(
                        instance: instance,
                        wsURL: wsURL.url,
                        sessionName: wsURL.sessionName
                    )
                    self.onDismiss?()
                }
            } catch {
                await MainActor.run {
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // Mirror iOS attachToWorkspace() from InstanceListView.swift:1295.
    // Returns nil if the user cancelled the workspace picker; throws on API errors.
    private func resolveWorkspaceURL(for instance: SoyehtInstance) async throws -> (url: String, sessionName: String)? {
        let client = SoyehtAPIClient.shared
        let store = SessionStore.shared

        guard let host = store.apiHost, let token = store.sessionToken else {
            throw SoyehtAPIClient.APIError.noSession
        }

        let workspaces = try await client.listWorkspaces(container: instance.container)

        let sessionName: String
        if workspaces.isEmpty {
            let response = try await client.createWorkspace(container: instance.container)
            sessionName = response.workspace.sessionId
        } else if workspaces.count == 1 {
            sessionName = workspaces[0].sessionName
        } else {
            // Multiple sessions — let the user pick one.
            guard let chosen = await pickWorkspace(from: workspaces, instanceName: instance.name) else {
                return nil
            }
            sessionName = chosen.sessionName
        }

        let url = client.buildWebSocketURL(
            host: host,
            container: instance.container,
            sessionId: sessionName,
            token: token
        )
        return (url, sessionName)
    }

    /// Shows a modal NSAlert with a pop-up button listing workspaces.
    /// Returns the chosen workspace, or nil if the user cancelled.
    @MainActor
    private func pickWorkspace(from workspaces: [SoyehtWorkspace], instanceName: String) async -> SoyehtWorkspace? {
        let alert = NSAlert()
        alert.messageText = "Select Session — \(instanceName)"
        alert.informativeText = "This instance has \(workspaces.count) tmux sessions. Choose one to open."

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for ws in workspaces {
            let attachedSuffix = ws.isAttached ? "  [attached]" : ""
            popUp.addItem(withTitle: "\(ws.displayName)\(attachedSuffix)  ·  \(ws.displayCreated)")
        }
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let idx = popUp.indexOfSelectedItem
        return (idx >= 0 && idx < workspaces.count) ? workspaces[idx] : nil
    }
}
