import SoyehtCore
import UIKit

extension FileBrowserViewController {
    func beginQuickLookDownload(for entry: RemoteDirectoryEntry, openOnCompletion: Bool) {
        let requiresInlineDelay = requiresInlineQuickLookPreviewDelay(for: entry)
        if requiresInlineDelay {
            inlineQuickLookDelayPaths.insert(entry.path)
        } else {
            inlineQuickLookDelayPaths.remove(entry.path)
        }

        if case .downloading = downloadStates[entry.path]?.phase {
            return
        }

        if let localURL = existingPreviewURL(for: entry) {
            if requiresInlineDelay {
                let startedAt = Date().timeIntervalSinceReferenceDate
                downloadStates[entry.path] = FileRowDownloadState(
                    phase: .downloading(progress: 1.0, speedText: nil),
                    opensPreviewOnCompletion: openOnCompletion,
                    startedAt: startedAt
                )
                updateCollectionAccessibilitySummary()
                reloadEntry(path: entry.path)

                let workItem = DispatchWorkItem { [weak self] in
                    self?.finalizeCompletedDownload(remotePath: entry.path, localURL: localURL)
                }
                deferredPreviewWorkItems[entry.path]?.cancel()
                deferredPreviewWorkItems[entry.path] = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.minimumInlineDownloadDuration,
                    execute: workItem
                )
                return
            }
            presentFilePreview(entry: entry, content: .quickLook(localURL: localURL, mimeType: localURL.pathExtension))
            return
        }

        do {
            let request = try SoyehtAPIClient.shared.makeRemoteFileDownloadRequest(
                container: containerId,
                session: sessionName,
                path: entry.path,
                context: serverContext
            )
            downloadStates[entry.path] = FileRowDownloadState(
                phase: .downloading(progress: 0, speedText: nil),
                opensPreviewOnCompletion: openOnCompletion,
                startedAt: Date().timeIntervalSinceReferenceDate
            )
            updateCollectionAccessibilitySummary()
            reloadEntry(path: entry.path)
            remoteDownloadManager.startPreviewDownload(
                request: request,
                container: containerId,
                remotePath: entry.path
            )
        } catch {
            showErrorAlert(title: "Unable to Download File", error: error)
        }
    }

    func cancelDownload(for entry: RemoteDirectoryEntry) {
        deferredPreviewWorkItems.removeValue(forKey: entry.path)?.cancel()
        remoteDownloadManager.cancel(remotePath: entry.path)
        downloadStates.removeValue(forKey: entry.path)
        inlineQuickLookDelayPaths.remove(entry.path)
        updateCollectionAccessibilitySummary()
        if let temporaryURL = try? downloadsManager.temporaryPreviewURL(container: containerId, remotePath: entry.path),
           FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        reloadEntry(path: entry.path)
    }

    func handleCompletedDownload(remotePath: String, localURL: URL) {
        deferredPreviewWorkItems.removeValue(forKey: remotePath)?.cancel()
        let shouldOpen = downloadStates[remotePath]?.opensPreviewOnCompletion ?? false
        let startedAt = downloadStates[remotePath]?.startedAt ?? Date().timeIntervalSinceReferenceDate
        let elapsed = Date().timeIntervalSinceReferenceDate - startedAt
        let shouldDelay = inlineQuickLookDelayPaths.contains(remotePath)
            || shouldDelayPreview(remotePath: remotePath, localURL: localURL)

        if shouldDelay, elapsed < Self.minimumInlineDownloadDuration {
            let remainingDelay = Self.minimumInlineDownloadDuration - elapsed
            downloadStates[remotePath] = FileRowDownloadState(
                phase: .downloading(progress: 1.0, speedText: nil),
                opensPreviewOnCompletion: shouldOpen,
                startedAt: startedAt
            )
            updateCollectionAccessibilitySummary()
            reloadEntry(path: remotePath)

            let workItem = DispatchWorkItem { [weak self] in
                self?.finalizeCompletedDownload(remotePath: remotePath, localURL: localURL)
            }
            deferredPreviewWorkItems[remotePath] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay, execute: workItem)
            return
        }

        finalizeCompletedDownload(remotePath: remotePath, localURL: localURL)
    }

    private func existingPreviewURL(for entry: RemoteDirectoryEntry) -> URL? {
        if let tempURL = try? downloadsManager.temporaryPreviewURL(container: containerId, remotePath: entry.path),
           FileManager.default.fileExists(atPath: tempURL.path) {
            return tempURL
        }
        if let persistentURL = try? downloadsManager.remoteDownloadDestination(container: containerId, remotePath: entry.path),
           FileManager.default.fileExists(atPath: persistentURL.path) {
            return persistentURL
        }
        return nil
    }

    private func finalizeCompletedDownload(remotePath: String, localURL: URL) {
        deferredPreviewWorkItems.removeValue(forKey: remotePath)?.cancel()
        let shouldOpen = downloadStates[remotePath]?.opensPreviewOnCompletion ?? false
        downloadStates.removeValue(forKey: remotePath)
        inlineQuickLookDelayPaths.remove(remotePath)
        updateCollectionAccessibilitySummary()
        reloadEntry(path: remotePath)
        if !shouldOpen {
            showToast(message: "Download complete")
        }
        guard shouldOpen,
              let entry = entries.first(where: { $0.path == remotePath }) else { return }
        presentFilePreview(entry: entry, content: .quickLook(localURL: localURL, mimeType: localURL.pathExtension))
    }

    private func shouldDelayPreview(remotePath: String, localURL: URL) -> Bool {
        if let fileSize = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize >= Self.inlineDownloadThresholdBytes {
            return true
        }

        if let entry = entries.first(where: { $0.path == remotePath }),
           let sizeBytes = entry.sizeBytes,
           sizeBytes >= Self.inlineDownloadThresholdBytes {
            return true
        }
        return false
    }
}
