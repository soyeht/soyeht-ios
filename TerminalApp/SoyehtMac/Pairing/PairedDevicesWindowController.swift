import Cocoa
import SoyehtCore

class PairedDevicesWindowController: NSWindowController {

    static let shared = PairedDevicesWindowController()

    private init() {
        let contentVC = PairedDevicesViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dispositivos pareados"
        window.contentViewController = contentVC
        window.minSize = NSSize(width: 420, height: 260)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use PairedDevicesWindowController.shared") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: -

final class PairedDevicesViewController: NSViewController {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Nenhum iPhone pareado ainda. Clique no botão QR de um pane e escaneie com o app Soyeht iOS.")
    private let revokeSelectedButton = NSButton(title: "Revogar selecionado", target: nil, action: nil)
    private let revokeAllButton = NSButton(title: "Revogar todos", target: nil, action: nil)

    private var devices: [PairedDevice] = []
    private var relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 560, height: 360))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        PairingStore.shared.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        reload()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Avoid retaining the window controller in a callback.
        PairingStore.shared.onChange = nil
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
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Nome"
        nameColumn.minWidth = 160
        nameColumn.width = 200
        tableView.addTableColumn(nameColumn)

        let modelColumn = NSTableColumn(identifier: .init("model"))
        modelColumn.title = "Modelo"
        modelColumn.minWidth = 100
        modelColumn.width = 140
        tableView.addTableColumn(modelColumn)

        let lastSeenColumn = NSTableColumn(identifier: .init("last_seen"))
        lastSeenColumn.title = "Último uso"
        lastSeenColumn.minWidth = 120
        lastSeenColumn.width = 160
        tableView.addTableColumn(lastSeenColumn)

        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        revokeSelectedButton.translatesAutoresizingMaskIntoConstraints = false
        revokeSelectedButton.target = self
        revokeSelectedButton.action = #selector(revokeSelectedTapped)
        revokeSelectedButton.isEnabled = false
        revokeSelectedButton.bezelStyle = .rounded

        revokeAllButton.translatesAutoresizingMaskIntoConstraints = false
        revokeAllButton.target = self
        revokeAllButton.action = #selector(revokeAllTapped)
        revokeAllButton.bezelStyle = .rounded
        revokeAllButton.hasDestructiveAction = true

        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(revokeSelectedButton)
        view.addSubview(revokeAllButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: revokeSelectedButton.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),

            revokeSelectedButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            revokeSelectedButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            revokeAllButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            revokeAllButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Reload

    @MainActor
    private func reload() {
        devices = PairingStore.shared.devices
        tableView.reloadData()
        emptyLabel.isHidden = !devices.isEmpty
        scrollView.isHidden = devices.isEmpty
        revokeAllButton.isEnabled = !devices.isEmpty
        revokeSelectedButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Actions

    @MainActor @objc private func revokeSelectedTapped() {
        let row = tableView.selectedRow
        guard devices.indices.contains(row) else { return }
        let device = devices[row]
        guard confirmRevoke(prompt: "Revogar “\(device.name)”?",
                            text: "Esse iPhone não poderá mais abrir panes deste Mac sem um novo pareamento.") else {
            return
        }
        LocalTerminalHandoffManager.shared.disconnectDevice(device.deviceID)
        PairingStore.shared.revoke(deviceID: device.deviceID)
    }

    @MainActor @objc private func revokeAllTapped() {
        guard !devices.isEmpty else { return }
        guard confirmRevoke(prompt: "Revogar todos os iPhones pareados?",
                            text: "Todas as sessões ativas serão encerradas. Cada iPhone precisará escanear um novo QR pra voltar.") else {
            return
        }
        for device in devices {
            LocalTerminalHandoffManager.shared.disconnectDevice(device.deviceID)
        }
        PairingStore.shared.revokeAll()
    }

    @MainActor
    private func confirmRevoke(prompt: String, text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.informativeText = text
        alert.alertStyle = .warning
        let confirm = alert.addButton(withTitle: "Revogar")
        alert.addButton(withTitle: "Cancelar")
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension PairedDevicesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let device = devices[row]
        let id = NSUserInterfaceItemIdentifier(rawValue: "cell.\(column.identifier.rawValue)")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeTextCell(identifier: id)
        switch column.identifier.rawValue {
        case "name":
            cell.textField?.stringValue = device.name
        case "model":
            cell.textField?.stringValue = Self.prettyModel(device.model)
        case "last_seen":
            cell.textField?.stringValue = relativeFormatter.localizedString(for: device.lastSeenAt, relativeTo: Date())
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        revokeSelectedButton.isEnabled = tableView.selectedRow >= 0
    }

    private static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// "iPhone16,1" → "iPhone 16,1" for readability. No lookup table — keeps it
    /// truthful and lets the user know the raw identifier.
    private static func prettyModel(_ raw: String) -> String {
        guard raw.hasPrefix("iPhone") || raw.hasPrefix("iPad") || raw.hasPrefix("iPod") else { return raw }
        // Insert a space between the letters and the first digit run.
        if let firstDigit = raw.firstIndex(where: { $0.isNumber }) {
            return raw[..<firstDigit] + " " + raw[firstDigit...]
        }
        return raw
    }
}
