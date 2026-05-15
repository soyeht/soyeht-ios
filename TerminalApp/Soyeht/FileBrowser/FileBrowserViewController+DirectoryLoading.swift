import SoyehtCore
import UIKit

extension FileBrowserViewController {
    @objc func refreshPulled() {
        loadDirectory(path: currentPath ?? requestedInitialPath ?? "~", recordHistory: false)
    }

    func loadInitialDirectory() {
        loadingView.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let initialPath = Self.initialDirectoryPath(
                requestedInitialPath: self.requestedInitialPath,
                panePath: nil
            )
            await MainActor.run {
                self.loadDirectory(path: initialPath, recordHistory: true)
            }
        }
    }

    func loadDirectory(path: String, recordHistory: Bool) {
        let requestedPath = Self.normalizedBrowserPath(path)
        let remotePath = Self.remoteBrowserPath(path)
        currentPath = requestedPath
        loadingView.startAnimating()
        if !refreshControl.isRefreshing {
            refreshControl.beginRefreshing()
        }
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listing = try await SoyehtAPIClient.shared.listRemoteDirectory(
                    container: self.containerId,
                    session: self.sessionName,
                    path: remotePath,
                    context: self.serverContext
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    let displayPath = Self.normalizedBrowserPath(listing.path)
                    self.currentPath = displayPath
                    self.entries = listing.entries.sorted { lhs, rhs in
                        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    if recordHistory {
                        self.historyStore.record(path: displayPath, container: self.containerId, session: self.sessionName)
                    }
                    self.breadcrumbBar.update(path: displayPath)
                    self.updatedLabel.text = String(localized: "fileBrowser.updated.now")
                    self.updatedLabel.isHidden = false
                    self.collectionView.reloadData()
                    self.loadingView.stopAnimating()
                    self.refreshControl.endRefreshing()
                    self.updateBackgroundView()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.loadingView.stopAnimating()
                    self.refreshControl.endRefreshing()
                    self.updateBackgroundView()
                    self.showErrorAlert(title: String(localized: "fileBrowser.alert.loadDirectoryFailed.title"), error: error)
                }
            }
        }
    }

    /// `nonisolated` — pure function, no view state. Tests in
    /// `SoyehtAPIClientTests` exercise this from a non-main context, and
    /// the type's new explicit `@MainActor` would otherwise prevent that.
    nonisolated static func initialDirectoryPath(requestedInitialPath: String?, panePath: String?) -> String {
        requestedInitialPath ?? panePath ?? "~"
    }

    func updateBackgroundView() {
        if !loadingView.isAnimating && entries.isEmpty {
            collectionView.backgroundView = emptyLabel
        } else if loadingView.isAnimating {
            collectionView.backgroundView = loadingContainer
        } else {
            collectionView.backgroundView = nil
        }
        updateCollectionAccessibilitySummary()
    }

    private static func normalizedBrowserPath(_ path: String) -> String {
        if path == "/root" {
            return "~"
        }
        if path.hasPrefix("/root/") {
            return "~" + String(path.dropFirst("/root".count))
        }
        return path
    }

    private static func remoteBrowserPath(_ path: String) -> String {
        if path == "~" {
            return "/root"
        }
        if path.hasPrefix("~/") {
            return "/root/" + path.dropFirst(2)
        }
        return path
    }
}
