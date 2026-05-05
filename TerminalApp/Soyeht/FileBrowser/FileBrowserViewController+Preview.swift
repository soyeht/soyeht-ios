import SoyehtCore
import UIKit

enum BrowserSelectionAction {
    case markdown
    case text
    case quickLook
    case unsupported
    case previewLimit
}

extension FileBrowserViewController {
    func handleSelection(for entry: RemoteDirectoryEntry) {
        if entry.isDirectory {
            loadDirectory(path: entry.path, recordHistory: true)
            return
        }

        switch selectionAction(for: entry) {
        case .markdown:
            loadTextPreview(for: entry, asMarkdown: true)
        case .text:
            loadTextPreview(for: entry, asMarkdown: false)
        case .quickLook:
            let openOnCompletion = !requiresInlineQuickLookPreviewDelay(for: entry)
            beginQuickLookDownload(for: entry, openOnCompletion: openOnCompletion)
        case .unsupported:
            showSimpleAlert(
                title: "Preview Unavailable",
                message: "Preview not available for this file type."
            )
        case .previewLimit:
            showSimpleAlert(
                title: "Preview Unavailable",
                message: "Preview is limited to UTF-8 text files up to 512 KB."
            )
        }
    }

    func selectionAction(for entry: RemoteDirectoryEntry) -> BrowserSelectionAction {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            if let sizeBytes = entry.sizeBytes, sizeBytes > Self.maxTextPreviewBytes {
                return .previewLimit
            }
            return .markdown
        }
        if Self.textPreviewExtensions.contains(ext) {
            if let sizeBytes = entry.sizeBytes, sizeBytes > Self.maxTextPreviewBytes {
                return .previewLimit
            }
            return .text
        }
        if Self.quickLookExtensions.contains(ext) {
            return .quickLook
        }
        return .unsupported
    }

    func presentFilePreview(entry: RemoteDirectoryEntry, content: FilePreviewContent) {
        let controller = FilePreviewViewController(
            container: containerId,
            remotePath: entry.path,
            content: content,
            entry: entry
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    func requiresInlineQuickLookPreviewDelay(for entry: RemoteDirectoryEntry) -> Bool {
        guard selectionAction(for: entry) == .quickLook else { return false }
        guard let sizeBytes = entry.sizeBytes else { return false }
        return sizeBytes >= Self.inlineDownloadThresholdBytes
    }

    private func loadTextPreview(for entry: RemoteDirectoryEntry, asMarkdown: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let maxBytes = min(entry.sizeBytes ?? Self.maxTextPreviewBytes, Self.maxTextPreviewBytes)
                let preview = try await SoyehtAPIClient.shared.loadRemoteFilePreview(
                    container: self.containerId,
                    session: self.sessionName,
                    path: entry.path,
                    maxBytes: maxBytes,
                    knownFileSizeBytes: entry.sizeBytes,
                    context: self.serverContext
                )
                await MainActor.run {
                    let normalizedPreview: RemoteFilePreview
                    if asMarkdown && preview.mimeType == "text/plain" {
                        normalizedPreview = RemoteFilePreview(
                            path: preview.path,
                            mimeType: "text/markdown",
                            sizeBytes: preview.sizeBytes,
                            content: preview.content,
                            isTruncated: preview.isTruncated
                        )
                    } else {
                        normalizedPreview = preview
                    }
                    let content: FilePreviewContent = asMarkdown ? .markdown(normalizedPreview) : .text(normalizedPreview)
                    self.presentFilePreview(entry: entry, content: content)
                }
            } catch {
                await MainActor.run {
                    self.showErrorAlert(title: "Unable to Load Preview", error: error)
                }
            }
        }
    }
}
