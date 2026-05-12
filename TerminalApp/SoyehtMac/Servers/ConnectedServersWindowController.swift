import Cocoa
import SoyehtCore

@MainActor
final class ConnectedServersWindowController: NSWindowController {

    static let shared = ConnectedServersWindowController()

    private init() {
        let contentVC = ConnectedServersViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "servers.window.title",
            defaultValue: "Connected Servers",
            comment: "Title of the window listing connected theyOS servers."
        )
        window.contentViewController = contentVC
        window.minSize = NSSize(width: 620, height: 300)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use ConnectedServersWindowController.shared") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: -

@MainActor
private final class ConnectedServersViewController: NSViewController {

    private enum ProbeState: Equatable, Sendable {
        case unknown
        case checking
        case online
        case offline(String)
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: String(
            localized: "servers.empty.message",
            defaultValue: "No theyOS servers connected. Use the theyOS install or connect flow to add one.",
            comment: "Empty-state message shown when no theyOS servers are paired."
        )
    )
    private let setActiveButton = NSButton(
        title: String(
            localized: "servers.button.setActive",
            defaultValue: "Set Active",
            comment: "Button that makes the selected theyOS server active."
        ),
        target: nil,
        action: nil
    )
    private let disconnectButton = NSButton(
        title: String(
            localized: "servers.button.disconnect",
            defaultValue: "Disconnect",
            comment: "Button that removes the selected theyOS server."
        ),
        target: nil,
        action: nil
    )
    private let refreshButton = NSButton(
        title: String(
            localized: "servers.button.refresh",
            defaultValue: "Refresh",
            comment: "Button that reloads and probes the theyOS server list."
        ),
        target: nil,
        action: nil
    )

    private let store = SessionStore.shared
    private var servers: [PairedServer] = []
    private var probeStates: [String: ProbeState] = [:]
    private var refreshTask: Task<Void, Never>?
    private var activeServerObserver: NSObjectProtocol?

    private lazy var pairedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 780, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        activeServerObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadAndProbe()
            }
        }
        reloadAndProbe()
    }

    deinit {
        refreshTask?.cancel()
        if let activeServerObserver {
            NotificationCenter.default.removeObserver(activeServerObserver)
        }
    }

    // MARK: - Layout

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        addColumn("status", title: String(localized: "connectedServers.column.status"), minWidth: 105, width: 120)
        addColumn("name", title: String(localized: "connectedServers.column.name"), minWidth: 150, width: 180)
        addColumn("host", title: String(localized: "connectedServers.column.host"), minWidth: 190, width: 230)
        addColumn("role", title: String(localized: "connectedServers.column.role"), minWidth: 80, width: 95)
        addColumn("paired", title: String(localized: "connectedServers.column.paired"), minWidth: 130, width: 150)
        addColumn("expires", title: String(localized: "connectedServers.column.expires"), minWidth: 110, width: 130)

        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        setActiveButton.translatesAutoresizingMaskIntoConstraints = false
        setActiveButton.target = self
        setActiveButton.action = #selector(setActiveTapped)
        setActiveButton.bezelStyle = .rounded
        setActiveButton.isEnabled = false

        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        disconnectButton.bezelStyle = .rounded
        disconnectButton.hasDestructiveAction = true
        disconnectButton.isEnabled = false

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.bezelStyle = .rounded

        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(setActiveButton)
        view.addSubview(disconnectButton)
        view.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: setActiveButton.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),

            setActiveButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            setActiveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            disconnectButton.leadingAnchor.constraint(equalTo: setActiveButton.trailingAnchor, constant: 8),
            disconnectButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            refreshButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    private func addColumn(_ identifier: String, title: String, minWidth: CGFloat, width: CGFloat) {
        let column = NSTableColumn(identifier: .init(identifier))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        tableView.addTableColumn(column)
    }

    // MARK: - Reload

    private func reloadAndProbe() {
        reload()
        probeServers()
    }

    private func reload() {
        let activeId = store.activeServerId
        servers = store.pairedServers.sorted {
            if $0.id == activeId { return true }
            if $1.id == activeId { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        probeStates = probeStates.filter { id, _ in
            servers.contains(where: { $0.id == id })
        }
        tableView.reloadData()
        emptyLabel.isHidden = !servers.isEmpty
        scrollView.isHidden = servers.isEmpty
        updateButtons()
    }

    private func probeServers() {
        refreshTask?.cancel()
        let contexts = servers.compactMap { store.context(for: $0.id) }
        guard !contexts.isEmpty else {
            refreshButton.isEnabled = true
            tableView.reloadData()
            return
        }

        for context in contexts {
            probeStates[context.serverId] = .checking
        }
        tableView.reloadData()
        refreshButton.isEnabled = false

        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (String, ProbeState).self) { group in
                for context in contexts {
                    group.addTask {
                        let state = await ConnectedServersViewController.probe(context: context)
                        return (context.serverId, state)
                    }
                }

                for await (serverId, state) in group {
                    await MainActor.run {
                        guard let self, !Task.isCancelled else { return }
                        self.probeStates[serverId] = state
                        self.tableView.reloadData()
                    }
                }
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.refreshButton.isEnabled = true
                self.refreshTask = nil
            }
        }
    }

    nonisolated private static func probe(context: ServerContext) async -> ProbeState {
        do {
            let url = try SoyehtAPIClient.shared.buildURL(host: context.host, path: "/api/v1/mobile/status")
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .offline("No HTTP response")
            }
            return (200...299).contains(http.statusCode)
                ? .online
                : .offline("HTTP \(http.statusCode)")
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        reloadAndProbe()
    }

    @objc private func setActiveTapped() {
        let row = tableView.selectedRow
        guard servers.indices.contains(row) else { return }
        store.setActiveServer(id: servers[row].id)
        reloadAndProbe()
    }

    @objc private func disconnectTapped() {
        let row = tableView.selectedRow
        guard servers.indices.contains(row) else { return }
        let server = servers[row]
        guard confirmDisconnect(server: server) else { return }
        store.removeServer(id: server.id)
        NotificationCenter.default.post(name: ClawStoreNotifications.activeServerChanged, object: nil)
        reloadAndProbe()
    }

    private func confirmDisconnect(server: PairedServer) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "servers.alert.disconnect.title",
            defaultValue: "Disconnect “\(server.name)”?",
            comment: "Confirm alert title when removing a connected theyOS server."
        )
        alert.informativeText = String(
            localized: "servers.alert.disconnect.message",
            defaultValue: "This removes the saved token for \(server.host). You can connect it again with a theyOS link.",
            comment: "Confirm alert body when removing a connected theyOS server."
        )
        alert.alertStyle = .warning
        let confirm = alert.addButton(
            withTitle: String(
                localized: "servers.alert.button.disconnect",
                defaultValue: "Disconnect",
                comment: "Destructive confirm button that removes a connected theyOS server."
            )
        )
        alert.addButton(
            withTitle: String(
                localized: "common.button.cancel",
                defaultValue: "Cancel",
                comment: "Generic Cancel."
            )
        )
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        guard servers.indices.contains(row) else {
            setActiveButton.isEnabled = false
            disconnectButton.isEnabled = false
            return
        }
        let server = servers[row]
        disconnectButton.isEnabled = true
        setActiveButton.isEnabled = server.id != store.activeServerId && store.context(for: server.id) != nil
    }

    private func statusText(for server: PairedServer) -> String {
        guard store.context(for: server.id) != nil else {
            return String(localized: "servers.status.missingToken")
        }
        let prefix = server.id == store.activeServerId
            ? String(localized: "servers.status.active")
            : String(localized: "servers.status.paired")
        switch probeStates[server.id] ?? .unknown {
        case .unknown:
            return prefix
        case .checking:
            return String(
                localized: "servers.status.checking",
                defaultValue: "\(prefix), checking",
                comment: "Connected server status while probing. %@ = Active or Paired."
            )
        case .online:
            return String(
                localized: "servers.status.online",
                defaultValue: "\(prefix), online",
                comment: "Connected server status after a successful probe. %@ = Active or Paired."
            )
        case .offline(let reason):
            return String(
                localized: "servers.status.offline",
                defaultValue: "\(prefix), offline (\(reason))",
                comment: "Connected server status after a failed probe. First %@ = Active or Paired; second %@ = failure reason."
            )
        }
    }

    private func expiresText(for server: PairedServer) -> String {
        guard let expires = server.expiresAt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expires.isEmpty else {
            return String(localized: "servers.expires.never")
        }
        return expires
    }
}

extension ConnectedServersViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { servers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, servers.indices.contains(row) else { return nil }
        let server = servers[row]
        let id = NSUserInterfaceItemIdentifier(rawValue: "server.cell.\(column.identifier.rawValue)")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeTextCell(identifier: id)
        switch column.identifier.rawValue {
        case "status":
            cell.textField?.stringValue = statusText(for: server)
        case "name":
            cell.textField?.stringValue = server.name
        case "host":
            cell.textField?.stringValue = server.host
        case "role":
            cell.textField?.stringValue = server.role ?? "-"
        case "paired":
            cell.textField?.stringValue = pairedFormatter.string(from: server.pairedAt)
        case "expires":
            cell.textField?.stringValue = expiresText(for: server)
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
