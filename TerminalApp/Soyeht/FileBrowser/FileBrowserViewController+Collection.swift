import SoyehtCore
import UIKit

extension FileBrowserViewController {
    func configure(cell: FileBrowserCell, with entry: RemoteDirectoryEntry) {
        let state = downloadStates[entry.path]
        cell.configure(
            entry: entry,
            subtitle: subtitleText(for: entry),
            icon: icon(for: entry),
            iconTint: iconTint(for: entry),
            state: state
        )
        cell.accessibilityIdentifier = AccessibilityID.FileBrowser.row(entry.path)
        cell.onCancelTapped = { [weak self] in
            self?.cancelDownload(for: entry)
        }
        cell.onRetryTapped = { [weak self] in
            self?.beginQuickLookDownload(for: entry, openOnCompletion: true)
        }
    }

    func reloadEntry(path: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else {
            collectionView.reloadData()
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        if collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.reloadItems(at: [indexPath])
        } else {
            collectionView.reloadData()
        }
    }

    func updateCollectionAccessibilitySummary() {
        if let active = downloadStates.first(where: {
            if case .downloading = $0.value.phase { return true }
            return false
        }) {
            let name = (active.key as NSString).lastPathComponent
            if case .downloading(let progress, let speedText) = active.value.phase {
                let summary = progressSummary(progress: progress, speedText: speedText)
                collectionView.accessibilityValue = String(
                    localized: "fileBrowser.download.progress.a11y",
                    defaultValue: "Downloading \(name) · \(summary)",
                    comment: "Accessibility value while a file is downloading. First value is filename, second is progress summary."
                )
                return
            }
        }

        if let failed = downloadStates.first(where: {
            if case .failed = $0.value.phase { return true }
            return false
        }) {
            let name = (failed.key as NSString).lastPathComponent
            if case .failed(let message) = failed.value.phase {
                collectionView.accessibilityValue = String(
                    localized: "fileBrowser.download.failed.a11y",
                    defaultValue: "Download failed for \(name) · \(message)",
                    comment: "Accessibility value when a file download failed. First value is filename, second is error message."
                )
                return
            }
        }

        collectionView.accessibilityValue = nil
    }

    private func subtitleText(for entry: RemoteDirectoryEntry) -> String {
        if entry.isDirectory {
            return entry.path
        }

        var parts: [String] = []
        if let sizeBytes = entry.sizeBytes {
            parts.append(fileSizeFormatter.string(fromByteCount: Int64(sizeBytes)))
        }
        if let modifiedAt = entry.modifiedAt {
            parts.append(formattedModifiedAt(modifiedAt))
        }
        return parts.isEmpty ? entry.path : parts.joined(separator: " · ")
    }

    private func formattedModifiedAt(_ value: String) -> String {
        if let date = ISO8601DateFormatter().date(from: value) {
            return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        }
        return value
    }

    private func icon(for entry: RemoteDirectoryEntry) -> UIImage? {
        let name: String
        if entry.isDirectory {
            name = "folder.fill"
        } else {
            switch selectionAction(for: entry) {
            case .markdown:
                name = "doc.richtext"
            case .text:
                name = "doc.text"
            case .quickLook:
                name = "doc"
            case .unsupported, .previewLimit:
                name = "doc"
            }
        }
        return UIImage(systemName: name)
    }

    private func iconTint(for entry: RemoteDirectoryEntry) -> UIColor {
        if entry.isDirectory { return SoyehtTheme.uiAccentGreen }
        switch selectionAction(for: entry) {
        case .markdown, .text:
            return SoyehtTheme.uiAttachDocument
        case .quickLook:
            return SoyehtTheme.uiTextPrimary
        case .unsupported, .previewLimit:
            return SoyehtTheme.uiTextSecondary
        }
    }

    private func contextMenu(for entry: RemoteDirectoryEntry) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: entry.path as NSString, previewProvider: nil) { [self] _ in
            let openTitle = entry.isDirectory
                ? String(localized: "fileBrowser.context.openFolder")
                : String(localized: "fileBrowser.context.openPreview")
            let openAction = UIAction(title: openTitle, image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.handleSelection(for: entry)
            }
            let copyAction = UIAction(title: String(localized: "fileBrowser.context.copyPath"), image: UIImage(systemName: "square.on.square")) { _ in
                UIPasteboard.general.string = entry.path
            }
            let insertAction = UIAction(
                title: String(localized: "fileBrowser.context.insertIntoTerminal"),
                image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                self?.insertIntoTerminal(entry.path)
            }
            insertAction.attributes = isCommander ? [] : [.disabled]
            let shareAction = UIAction(title: String(localized: "fileBrowser.context.sharePath"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.shareText(entry.path, sourceView: self?.collectionView ?? UIView())
            }
            return UIMenu(title: "", children: [openAction, copyAction, insertAction, shareAction])
        }
    }

    private func insertIntoTerminal(_ text: String) {
        NotificationCenter.default.post(
            name: .soyehtInsertIntoTerminal,
            object: nil,
            userInfo: [
                SoyehtNotificationKey.container: containerId,
                SoyehtNotificationKey.session: sessionName,
                SoyehtNotificationKey.text: text,
            ]
        )
    }

    private func shareText(_ text: String, sourceView: UIView) {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = sourceView.bounds
        present(controller, animated: true)
    }

    private func progressSummary(progress: Double, speedText: String?) -> String {
        let percent = Int((progress * 100).rounded())
        if let speedText, !speedText.isEmpty {
            return "\(percent)% · \(speedText)"
        }
        return "\(percent)%"
    }
}

extension FileBrowserViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(
            using: cellRegistration,
            for: indexPath,
            item: entries[indexPath.item]
        )
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        handleSelection(for: entries[indexPath.item])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        contextMenu(for: entries[indexPath.item])
    }
}
