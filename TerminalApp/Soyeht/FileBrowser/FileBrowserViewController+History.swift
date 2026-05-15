import SoyehtCore
import UIKit

extension FileBrowserViewController {
    func presentHistorySheet() {
        let entries = historyStore.entries(container: containerId, session: sessionName)
        let controller = BreadcrumbHistoryViewController(entries: entries)
        controller.onSelectPath = { [weak self] path in
            self?.loadDirectory(path: path, recordHistory: true)
        }
        controller.onTogglePin = { [weak self] path in
            guard let self else { return }
            self.historyStore.togglePinned(path: path, container: self.containerId, session: self.sessionName)
        }
        controller.onDeletePath = { [weak self] path in
            guard let self else { return }
            self.historyStore.remove(path: path, container: self.containerId, session: self.sessionName)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(navigation, animated: true)
    }
}

private final class BreadcrumbHistoryViewController: UITableViewController {
    private var entries: [NavigationHistoryEntry]
    var onSelectPath: ((String) -> Void)?
    var onTogglePin: ((String) -> Void)?
    var onDeletePath: ((String) -> Void)?

    init(entries: [NavigationHistoryEntry]) {
        self.entries = entries
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "fileBrowser.history.title")
        tableView.accessibilityIdentifier = AccessibilityID.FileBrowser.historySheet
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "HistoryCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionEntries(section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? String(localized: "fileBrowser.history.section.pinned")
            : String(localized: "fileBrowser.history.section.recent")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HistoryCell", for: indexPath)
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.path
        content.textProperties.font = Typography.monoUICardMedium
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = AccessibilityID.FileBrowser.historyRow(entry.path)

        let starButton = UIButton(type: .system)
        starButton.setImage(
            UIImage(systemName: entry.pinned ? "star.fill" : "star"),
            for: .normal
        )
        starButton.tintColor = entry.pinned ? SoyehtTheme.uiAttachDocument : SoyehtTheme.uiTextSecondary
        starButton.tag = flattenedIndex(for: entry.path)
        starButton.addTarget(self, action: #selector(togglePinned(_:)), for: .touchUpInside)
        cell.accessoryView = starButton
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        dismiss(animated: true) { [onSelectPath] in
            onSelectPath?(entry.path)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: String(localized: "common.button.delete")) { [weak self] _, _, completion in
            self?.onDeletePath?(entry.path)
            self?.entries.removeAll { $0.path == entry.path }
            tableView.deleteRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private func togglePinned(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < entries.count else { return }
        let entry = entries[sender.tag]
        onTogglePin?(entry.path)
        entries[sender.tag] = NavigationHistoryEntry(
            path: entry.path,
            lastAccessedAt: entry.lastAccessedAt,
            pinned: !entry.pinned
        )
        tableView.reloadData()
    }

    private func sectionEntries(_ section: Int) -> [NavigationHistoryEntry] {
        let pinned = entries.filter(\.pinned)
        let recent = entries.filter { !$0.pinned }
        return section == 0 ? pinned : recent
    }

    private func flattenedIndex(for path: String) -> Int {
        entries.firstIndex(where: { $0.path == path }) ?? 0
    }
}
