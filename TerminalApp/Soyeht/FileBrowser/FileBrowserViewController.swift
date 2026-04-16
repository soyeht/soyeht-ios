import QuickLook
import SoyehtCore
import SwiftUI
import UIKit
import WebKit

struct SessionFileBrowserContainer: UIViewControllerRepresentable {
    let container: String
    let session: String
    let instanceName: String
    let windowIndex: Int
    let initialPath: String?
    let isCommander: Bool
    let forceCommanderAccess: Bool

    func makeUIViewController(context: Context) -> UINavigationController {
        let browser = FileBrowserViewController(
            container: container,
            session: session,
            instanceName: instanceName,
            windowIndex: windowIndex,
            initialPath: initialPath,
            isCommander: isCommander,
            forceCommanderAccess: forceCommanderAccess
        )
        let navigationController = UINavigationController(rootViewController: browser)
        navigationController.modalPresentationStyle = .fullScreen
        navigationController.navigationBar.prefersLargeTitles = false
        navigationController.navigationBar.tintColor = SoyehtTheme.uiTextPrimary
        navigationController.navigationBar.barTintColor = SoyehtTheme.uiBgPrimary
        navigationController.navigationBar.isTranslucent = false
        browser.onClose = { [weak navigationController] in
            navigationController?.dismiss(animated: true)
        }
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        guard let browser = uiViewController.viewControllers.first as? FileBrowserViewController else { return }
        browser.updateCommanderState(isCommander)
    }
}

private enum BrowserSelectionAction {
    case markdown
    case text
    case quickLook
    case unsupported
    case previewLimit
}

private enum FileRowPhase: Equatable {
    case idle
    case downloading(progress: Double, speedText: String?)
    case failed(message: String)
}

private struct FileRowDownloadState: Equatable {
    var phase: FileRowPhase
    var opensPreviewOnCompletion: Bool
    var startedAt: TimeInterval
}

private enum FilePreviewContent {
    case markdown(RemoteFilePreview)
    case text(RemoteFilePreview)
    case quickLook(localURL: URL, mimeType: String)
}

final class FileBrowserViewController: UIViewController {
    private static let maxTextPreviewBytes = 524_288
    private static let inlineDownloadThresholdBytes = 5_000_000
    // Keep large-file downloads visible long enough for the inline progress
    // state to be perceivable on-device and by Appium before Quick Look takes over.
    private static let minimumInlineDownloadDuration: TimeInterval = 5.0
    private static let uiTestForceFallbackRoot = ProcessInfo.processInfo.environment["SOYEHT_UI_TEST_FORCE_BROWSER_FALLBACK"] == "1"
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let textPreviewExtensions: Set<String> = [
        "txt", "log", "swift", "json", "yml", "yaml", "sh"
    ]
    private static let quickLookExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "webp",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav",
        "ppt", "pptx", "key"
    ]

    private let containerId: String
    private let sessionName: String
    private let instanceName: String
    private let windowIndex: Int
    private let requestedInitialPath: String?
    private let historyStore = NavigationHistoryStore.shared
    private let attachmentRouter = AttachmentSourceRouter()
    private let downloadsManager = DownloadsManager.shared
    private let remoteDownloadManager = RemoteFileDownloadManager()
    private let fileSizeFormatter = ByteCountFormatter()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let sessionStore = SessionStore.shared

    private lazy var collectionView = makeCollectionView()
    private lazy var refreshControl = makeRefreshControl()
    private let breadcrumbBar = BreadcrumbBar()
    private let sourceChipStrip = SourceChipStrip()
    private let updatedLabel = UILabel()
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let loadingContainer = UIView()
    private let emptyLabel = UILabel()

    private var cellRegistration: UICollectionView.CellRegistration<FileBrowserCell, RemoteDirectoryEntry>!

    private var currentPath: String?
    private var entries: [RemoteDirectoryEntry] = []
    private var downloadStates: [String: FileRowDownloadState] = [:]
    private var inlineQuickLookDelayPaths: Set<String> = []
    private var deferredPreviewWorkItems: [String: DispatchWorkItem] = [:]
    private var loadTask: Task<Void, Never>?
    private var isCommander: Bool
    private let forceCommanderAccess: Bool

    var onClose: (() -> Void)?

    init(
        container: String,
        session: String,
        instanceName: String,
        windowIndex: Int,
        initialPath: String?,
        isCommander: Bool,
        forceCommanderAccess: Bool
    ) {
        self.containerId = container
        self.sessionName = session
        self.instanceName = instanceName
        self.windowIndex = windowIndex
        self.requestedInitialPath = initialPath
        self.forceCommanderAccess = forceCommanderAccess
        self.isCommander = forceCommanderAccess ||
            isCommander ||
            SessionStore.shared.hasLocalCommanderClaim(container: container, session: session)
        super.init(nibName: nil, bundle: nil)
        cellRegistration = UICollectionView.CellRegistration<FileBrowserCell, RemoteDirectoryEntry> { [weak self] cell, _, entry in
            self?.configure(cell: cell, with: entry)
        }
        attachmentRouter.container = container
        attachmentRouter.sessionName = session
        fileSizeFormatter.countStyle = .file
        fileSizeFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        relativeDateFormatter.unitsStyle = .abbreviated
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        remoteDownloadManager.cancelAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.accessibilityIdentifier = AccessibilityID.FileBrowser.container
        title = instanceName
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        setupLayout()
        configureCallbacks()
        loadInitialDirectory()
    }

    func updateCommanderState(_ isCommander: Bool) {
        guard !forceCommanderAccess else { return }
        self.isCommander = isCommander || sessionStore.hasLocalCommanderClaim(container: containerId, session: sessionName)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func refreshPulled() {
        loadDirectory(path: currentPath ?? requestedInitialPath ?? "~", recordHistory: false)
    }

    private func setupLayout() {
        updatedLabel.font = Typography.monoUIFont(size: 11, weight: .medium)
        updatedLabel.textColor = SoyehtTheme.uiTextSecondary
        updatedLabel.textAlignment = .center
        updatedLabel.isHidden = true

        let rootStack = UIStackView(arrangedSubviews: [
            breadcrumbBar,
            sourceChipStrip,
            collectionView,
            updatedLabel,
        ])
        rootStack.axis = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            breadcrumbBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            sourceChipStrip.heightAnchor.constraint(equalToConstant: 42),
            updatedLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        loadingContainer.addSubview(loadingView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor),
        ])

        emptyLabel.text = "No files in this directory"
        emptyLabel.textColor = SoyehtTheme.uiTextSecondary
        emptyLabel.font = Typography.monoUIFont(size: 13, weight: .medium)
        emptyLabel.textAlignment = .center

        collectionView.backgroundView = loadingContainer
    }

    private func configureCallbacks() {
        attachmentRouter.hostController = self
        attachmentRouter.onUploadSuccess = { [weak self] remotePath in
            self?.showToast(message: "Uploaded to \(remotePath)")
        }
        attachmentRouter.onUploadError = { [weak self] error in
            self?.showErrorAlert(title: "Upload Failed", error: error)
        }

        sourceChipStrip.onOptionSelected = { [weak self] option in
            self?.attachmentRouter.route(option)
        }

        breadcrumbBar.onSegmentTapped = { [weak self] segmentPath in
            self?.loadDirectory(path: segmentPath, recordHistory: true)
        }
        breadcrumbBar.onSegmentLongPressed = { [weak self] in
            self?.presentHistorySheet()
        }

        remoteDownloadManager.onProgress = { [weak self] remotePath, progress, speedText in
            guard let self else { return }
            self.downloadStates[remotePath] = FileRowDownloadState(
                phase: .downloading(progress: progress, speedText: speedText),
                opensPreviewOnCompletion: self.downloadStates[remotePath]?.opensPreviewOnCompletion ?? true,
                startedAt: self.downloadStates[remotePath]?.startedAt ?? Date().timeIntervalSinceReferenceDate
            )
            self.updateCollectionAccessibilitySummary()
            self.reloadEntry(path: remotePath)
        }
        remoteDownloadManager.onCompletion = { [weak self] remotePath, localURL in
            guard let self else { return }
            self.handleCompletedDownload(remotePath: remotePath, localURL: localURL)
        }
        remoteDownloadManager.onFailure = { [weak self] remotePath, error in
            guard let self else { return }
            self.deferredPreviewWorkItems.removeValue(forKey: remotePath)?.cancel()
            self.inlineQuickLookDelayPaths.remove(remotePath)
            self.downloadStates[remotePath] = FileRowDownloadState(
                phase: .failed(message: "Download failed"),
                opensPreviewOnCompletion: true,
                startedAt: Date().timeIntervalSinceReferenceDate
            )
            self.updateCollectionAccessibilitySummary()
            self.reloadEntry(path: remotePath)
            self.showToast(message: error.localizedDescription)
        }
    }

    private func makeCollectionView() -> UICollectionView {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = SoyehtTheme.uiBgPrimary
        config.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.backgroundColor = SoyehtTheme.uiBgPrimary
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = AccessibilityID.FileBrowser.collection
        collectionView.refreshControl = refreshControl
        return collectionView
    }

    private func makeRefreshControl() -> UIRefreshControl {
        let control = UIRefreshControl()
        control.tintColor = SoyehtTheme.uiAccentGreen
        control.accessibilityIdentifier = AccessibilityID.FileBrowser.refreshControl
        control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        return control
    }

    private func configure(cell: FileBrowserCell, with entry: RemoteDirectoryEntry) {
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

    private func loadInitialDirectory() {
        loadingView.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let paneContext: BreadcrumbCurrentDirectory?
            if Self.uiTestForceFallbackRoot {
                paneContext = nil
            } else {
                paneContext = try? await SoyehtAPIClient.shared.fetchCurrentWorkingDirectory(
                    container: self.containerId,
                    session: self.sessionName,
                    windowIndex: self.windowIndex
                )
            }
            guard !Task.isCancelled else { return }
            let initialPath = self.requestedInitialPath ?? (paneContext == nil ? "~" : "~/Downloads")
            await MainActor.run {
                self.loadDirectory(path: initialPath, recordHistory: true)
            }
        }
    }

    private func loadDirectory(path: String, recordHistory: Bool) {
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
                    path: remotePath
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
                    self.updatedLabel.text = "Atualizado agora"
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
                    self.showErrorAlert(title: "Unable to Load Directory", error: error)
                }
            }
        }
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

    private func updateBackgroundView() {
        if !loadingView.isAnimating && entries.isEmpty {
            collectionView.backgroundView = emptyLabel
        } else if loadingView.isAnimating {
            collectionView.backgroundView = loadingContainer
        } else {
            collectionView.backgroundView = nil
        }
        updateCollectionAccessibilitySummary()
    }

    private func presentHistorySheet() {
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

    private func handleSelection(for entry: RemoteDirectoryEntry) {
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

    private func selectionAction(for entry: RemoteDirectoryEntry) -> BrowserSelectionAction {
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
                    knownFileSizeBytes: entry.sizeBytes
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

    private func beginQuickLookDownload(for entry: RemoteDirectoryEntry, openOnCompletion: Bool) {
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
                path: entry.path
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

    private func cancelDownload(for entry: RemoteDirectoryEntry) {
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

    private func presentFilePreview(entry: RemoteDirectoryEntry, content: FilePreviewContent) {
        let controller = FilePreviewViewController(
            container: containerId,
            remotePath: entry.path,
            content: content,
            entry: entry
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func handleCompletedDownload(remotePath: String, localURL: URL) {
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

    private func requiresInlineQuickLookPreviewDelay(for entry: RemoteDirectoryEntry) -> Bool {
        guard selectionAction(for: entry) == .quickLook else { return false }
        guard let sizeBytes = entry.sizeBytes else { return false }
        return sizeBytes >= Self.inlineDownloadThresholdBytes
    }

    private func contextMenu(for entry: RemoteDirectoryEntry) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: entry.path as NSString, previewProvider: nil) { [self] _ in
            let openTitle = entry.isDirectory ? "Open Folder" : "Open Preview"
            let openAction = UIAction(title: openTitle, image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.handleSelection(for: entry)
            }
            let copyAction = UIAction(title: "Copy Path", image: UIImage(systemName: "square.on.square")) { _ in
                UIPasteboard.general.string = entry.path
            }
            let insertAction = UIAction(
                title: "Insert into Terminal",
                image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                self?.insertIntoTerminal(entry.path)
            }
            insertAction.attributes = isCommander ? [] : [.disabled]
            let shareAction = UIAction(title: "Share Path", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
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

    private func reloadEntry(path: String) {
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

    private func updateCollectionAccessibilitySummary() {
        if let active = downloadStates.first(where: {
            if case .downloading = $0.value.phase { return true }
            return false
        }) {
            let name = (active.key as NSString).lastPathComponent
            if case .downloading(let progress, let speedText) = active.value.phase {
                let summary = progressSummary(progress: progress, speedText: speedText)
                collectionView.accessibilityValue = "Downloading \(name) · \(summary)"
                return
            }
        }

        if let failed = downloadStates.first(where: {
            if case .failed = $0.value.phase { return true }
            return false
        }) {
            let name = (failed.key as NSString).lastPathComponent
            if case .failed(let message) = failed.value.phase {
                collectionView.accessibilityValue = "Download failed for \(name) · \(message)"
                return
            }
        }

        collectionView.accessibilityValue = nil
    }

    private func progressSummary(progress: Double, speedText: String?) -> String {
        let percent = Int((progress * 100).rounded())
        if let speedText, !speedText.isEmpty {
            return "\(percent)% · \(speedText)"
        }
        return "\(percent)%"
    }

    private func showErrorAlert(title: String, error: Error) {
        showSimpleAlert(title: title, message: error.localizedDescription)
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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

private final class FileBrowserCell: UICollectionViewListCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorBanner = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let actionButton = UIButton(type: .system)

    var onCancelTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCancelTapped = nil
        onRetryTapped = nil
    }

    private func setup() {
        contentView.backgroundColor = SoyehtTheme.uiBgPrimary
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = Typography.monoUIFont(size: 14, weight: .medium)
        titleLabel.textColor = SoyehtTheme.uiTextPrimary
        titleLabel.numberOfLines = 1
        titleLabel.isAccessibilityElement = false

        subtitleLabel.font = Typography.monoUIFont(size: 11, weight: .regular)
        subtitleLabel.textColor = SoyehtTheme.uiTextSecondary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isAccessibilityElement = false

        progressLabel.font = Typography.monoUIFont(size: 11, weight: .semibold)
        progressLabel.textColor = SoyehtTheme.uiAccentGreen
        progressLabel.isHidden = true
        progressLabel.isAccessibilityElement = false

        progressView.tintColor = SoyehtTheme.uiAccentGreen
        progressView.trackTintColor = SoyehtTheme.uiDivider
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.accessibilityIdentifier = AccessibilityID.FilePreview.progressView
        progressView.isAccessibilityElement = false

        errorBanner.font = Typography.monoUIFont(size: 11, weight: .semibold)
        errorBanner.textColor = .white
        errorBanner.backgroundColor = SoyehtTheme.uiBgKill
        errorBanner.textAlignment = .center
        errorBanner.numberOfLines = 0
        errorBanner.layer.cornerRadius = 0
        errorBanner.clipsToBounds = true
        errorBanner.isHidden = true
        errorBanner.isAccessibilityElement = false

        chevronView.tintColor = SoyehtTheme.uiTextSecondary
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.contentMode = .scaleAspectFit
        chevronView.isAccessibilityElement = false

        actionButton.titleLabel?.font = Typography.monoUIFont(size: 11, weight: .semibold)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isAccessibilityElement = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progressLabel, progressView, errorBanner])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = UIStackView(arrangedSubviews: [iconView, textStack, actionButton, chevronView])
        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 16),

            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    func configure(
        entry: RemoteDirectoryEntry,
        subtitle: String,
        icon: UIImage?,
        iconTint: UIColor,
        state: FileRowDownloadState?
    ) {
        iconView.image = icon
        iconView.tintColor = iconTint
        titleLabel.text = entry.name
        subtitleLabel.text = subtitle
        accessibilityLabel = entry.name
        accessibilityValue = subtitle
        progressLabel.accessibilityIdentifier = AccessibilityID.FileBrowser.rowProgress(entry.path)
        errorBanner.accessibilityIdentifier = AccessibilityID.FileBrowser.rowError(entry.path)
        actionButton.accessibilityIdentifier = AccessibilityID.FileBrowser.rowAction(entry.path)
        progressLabel.isAccessibilityElement = false
        errorBanner.isAccessibilityElement = false
        actionButton.isAccessibilityElement = false
        chevronView.isHidden = !entry.isDirectory
        actionButton.isHidden = true
        progressLabel.isHidden = true
        progressView.isHidden = true
        errorBanner.isHidden = true
        subtitleLabel.isHidden = false

        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = SoyehtTheme.uiBgPrimary
        background.strokeColor = SoyehtTheme.uiDivider
        background.strokeWidth = 1
        background.cornerRadius = 0
        background.backgroundInsets = .zero
        self.backgroundConfiguration = background

        switch state?.phase ?? .idle {
        case .idle:
            break
        case .downloading(let progress, let speedText):
            subtitleLabel.isHidden = true
            progressLabel.isHidden = false
            progressView.isHidden = false
            progressView.progress = Float(progress)
            let summary = progressSummary(progress: progress, speedText: speedText)
            progressLabel.text = summary
            accessibilityValue = summary
            progressLabel.accessibilityValue = summary
            progressLabel.isAccessibilityElement = true
            actionButton.isHidden = false
            chevronView.isHidden = true
            actionButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            actionButton.setTitle(nil, for: .normal)
            actionButton.tintColor = SoyehtTheme.uiTextSecondary
            actionButton.accessibilityLabel = "Cancel download"
            actionButton.isAccessibilityElement = true
            actionButton.removeTarget(nil, action: nil, for: .allEvents)
            actionButton.addAction(UIAction { [weak self] _ in self?.onCancelTapped?() }, for: .touchUpInside)
        case .failed(let message):
            subtitleLabel.isHidden = true
            errorBanner.isHidden = false
            errorBanner.text = "  \(message)  "
            accessibilityValue = message
            errorBanner.accessibilityValue = message
            errorBanner.isAccessibilityElement = true
            actionButton.isHidden = false
            chevronView.isHidden = true
            actionButton.setImage(nil, for: .normal)
            actionButton.setTitle("Tentar de novo", for: .normal)
            actionButton.setTitleColor(SoyehtTheme.uiAccentGreen, for: .normal)
            actionButton.accessibilityLabel = "Retry download"
            actionButton.isAccessibilityElement = true
            actionButton.removeTarget(nil, action: nil, for: .allEvents)
            actionButton.addAction(UIAction { [weak self] _ in self?.onRetryTapped?() }, for: .touchUpInside)
        }
    }

    private func progressSummary(progress: Double, speedText: String?) -> String {
        let percent = Int((progress * 100).rounded())
        if let speedText, !speedText.isEmpty {
            return "\(percent)% · \(speedText)"
        }
        return "\(percent)%"
    }
}

private final class BreadcrumbBar: UIView {
    var onSegmentTapped: ((String) -> Void)?
    var onSegmentLongPressed: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var segmentPaths: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SoyehtTheme.uiBgKeybar
        layer.borderColor = SoyehtTheme.uiDivider.cgColor
        layer.borderWidth = 1
        accessibilityIdentifier = AccessibilityID.FileBrowser.breadcrumbBar

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(path: String) {
        segmentPaths = buildSegmentPaths(for: path)
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, segmentPath) in segmentPaths.enumerated() {
            let title = segmentTitle(for: segmentPath)
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            button.configuration = configuration
            button.setTitle(title, for: .normal)
            button.setTitleColor(SoyehtTheme.uiTextPrimary, for: .normal)
            button.titleLabel?.font = Typography.monoUIFont(size: 13, weight: .medium)
            button.tag = index
            button.addTarget(self, action: #selector(segmentTapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = AccessibilityID.FileBrowser.breadcrumbSegment(index)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(segmentLongPressed(_:)))
            button.addGestureRecognizer(longPress)
            stackView.addArrangedSubview(button)

            if index < segmentPaths.count - 1 {
                let separator = UILabel()
                separator.text = "/"
                separator.font = Typography.monoUIFont(size: 12, weight: .regular)
                separator.textColor = SoyehtTheme.uiTextSecondary
                stackView.addArrangedSubview(separator)
            }
        }
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        guard sender.tag < segmentPaths.count else { return }
        onSegmentTapped?(segmentPaths[sender.tag])
    }

    @objc private func segmentLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onSegmentLongPressed?()
    }

    private func buildSegmentPaths(for path: String) -> [String] {
        if path == "/" { return ["/"] }

        let parts = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/") {
            var result = ["/"]
            var accumulator = ""
            for part in parts {
                accumulator += "/\(part)"
                result.append(accumulator)
            }
            return result
        }

        var result: [String] = []
        var accumulator = ""
        for part in parts {
            accumulator = accumulator.isEmpty ? part : "\(accumulator)/\(part)"
            result.append(accumulator)
        }
        return result
    }

    private func segmentTitle(for path: String) -> String {
        if path == "/" { return path }
        return (path as NSString).lastPathComponent
    }
}

private final class SourceChipStrip: UIView {
    var onOptionSelected: ((AttachmentOption) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let options: [(String, AttachmentOption, UIColor, String)] = [
        ("Photos", .photos, SoyehtTheme.uiAttachPhoto, "photo"),
        ("Camera", .camera, SoyehtTheme.uiAttachCamera, "camera"),
        ("Documents", .document, SoyehtTheme.uiAttachDocument, "doc.text"),
        ("Files", .files, SoyehtTheme.uiAttachFiles, "folder"),
        ("Location", .location, SoyehtTheme.uiAttachLocation, "mappin"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = AccessibilityID.FileBrowser.sourceChipStrip
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        options.enumerated().forEach { index, item in
            var configuration = UIButton.Configuration.plain()
            configuration.title = item.0
            configuration.image = UIImage(systemName: item.3)
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            configuration.cornerStyle = .fixed

            let button = UIButton(type: .system)
            button.configuration = configuration
            button.tintColor = item.2
            button.setTitleColor(SoyehtTheme.uiTextPrimary, for: .normal)
            button.titleLabel?.font = Typography.monoUIFont(size: 12, weight: .semibold)
            button.backgroundColor = SoyehtTheme.uiBgKeybar
            button.layer.cornerRadius = 0
            button.layer.borderColor = item.2.cgColor
            button.layer.borderWidth = 1
            button.tag = index
            button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = AccessibilityID.FileBrowser.sourceChip(item.0)
            stackView.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func chipTapped(_ sender: UIButton) {
        onOptionSelected?(options[sender.tag].1)
    }
}

private struct NavigationHistoryEntry: Codable, Hashable {
    let path: String
    let lastAccessedAt: Date
    let pinned: Bool
}

private final class NavigationHistoryStore {
    static let shared = NavigationHistoryStore()

    private let defaults = UserDefaults.standard

    func entries(container: String, session: String) -> [NavigationHistoryEntry] {
        let key = storageKey(container: container, session: session)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NavigationHistoryEntry].self, from: data) else {
            return []
        }
        return decoded.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }
    }

    func record(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        let pinned = current.first(where: { $0.path == path })?.pinned ?? false
        current.removeAll { $0.path == path }
        current.insert(
            NavigationHistoryEntry(path: path, lastAccessedAt: Date(), pinned: pinned),
            at: 0
        )
        persist(current.prefix(24), container: container, session: session)
    }

    func togglePinned(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        guard let index = current.firstIndex(where: { $0.path == path }) else { return }
        let entry = current[index]
        current[index] = NavigationHistoryEntry(
            path: entry.path,
            lastAccessedAt: entry.lastAccessedAt,
            pinned: !entry.pinned
        )
        persist(current, container: container, session: session)
    }

    func remove(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        current.removeAll { $0.path == path }
        persist(current, container: container, session: session)
    }

    private func persist<S: Sequence>(_ entries: S, container: String, session: String) where S.Element == NavigationHistoryEntry {
        let key = storageKey(container: container, session: session)
        let array = Array(entries)
        if let data = try? JSONEncoder().encode(array) {
            defaults.set(data, forKey: key)
        }
    }

    private func storageKey(container: String, session: String) -> String {
        "soyeht.fileBrowser.history.\(container).\(session)"
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
        title = "Recent & Pinned"
        tableView.accessibilityIdentifier = AccessibilityID.FileBrowser.historySheet
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "HistoryCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionEntries(section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Pinned" : "Recent"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HistoryCell", for: indexPath)
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.path
        content.textProperties.font = Typography.monoUIFont(size: 13, weight: .medium)
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
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
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

final class FilePreviewViewController: UIViewController {
    private let containerId: String
    private let remotePath: String
    private let content: FilePreviewContent
    private let entry: RemoteDirectoryEntry

    private let contentContainer = UIView()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let saveAsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private let textView: UITextView = {
        if #available(iOS 15.0, *) {
            let view = UITextView(usingTextLayoutManager: true)
            view.isEditable = false
            view.backgroundColor = SoyehtTheme.uiBgPrimary
            view.textColor = SoyehtTheme.uiTextPrimary
            view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
            return view
        } else {
            let view = UITextView()
            view.isEditable = false
            view.backgroundColor = SoyehtTheme.uiBgPrimary
            view.textColor = SoyehtTheme.uiTextPrimary
            view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
            return view
        }
    }()

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.isOpaque = false
        view.scrollView.backgroundColor = SoyehtTheme.uiBgPrimary
        view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
        return view
    }()

    private var quickLookController: QuickLookChildController?

    fileprivate init(container: String, remotePath: String, content: FilePreviewContent, entry: RemoteDirectoryEntry) {
        self.containerId = container
        self.remotePath = remotePath
        self.content = content
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        title = (remotePath as NSString).lastPathComponent

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.accessibilityIdentifier = AccessibilityID.FilePreview.textView
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Typography.monoUIFont(size: 11, weight: .regular)
        statusLabel.textColor = SoyehtTheme.uiTextSecondary
        statusLabel.numberOfLines = 0
        statusLabel.text = summaryText()

        let actions = UIStackView(arrangedSubviews: [saveButton, saveAsButton, shareButton])
        actions.axis = .vertical
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(saveButton, title: "Salvar no iPhone", icon: "square.and.arrow.down")
        configureActionButton(saveAsButton, title: "Salvar em…", icon: "square.and.arrow.down.on.square")
        configureActionButton(shareButton, title: "Compartilhar", icon: "square.and.arrow.up")

        saveButton.accessibilityIdentifier = AccessibilityID.FilePreview.saveButton
        saveAsButton.accessibilityIdentifier = AccessibilityID.FilePreview.downloadButton
        shareButton.accessibilityIdentifier = AccessibilityID.FilePreview.shareButton

        saveButton.addTarget(self, action: #selector(saveToIPhoneTapped), for: .touchUpInside)
        saveAsButton.addTarget(self, action: #selector(saveAsTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        view.addSubview(contentContainer)
        view.addSubview(statusLabel)
        view.addSubview(actions)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),

            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        renderContent()
    }

    private func configureActionButton(_ button: UIButton, title: String, icon: String) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = SoyehtTheme.uiBgKeybar
        configuration.baseForegroundColor = SoyehtTheme.uiTextPrimary
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        button.configuration = configuration
        button.layer.cornerRadius = 0
    }

    private func renderContent() {
        switch content {
        case .markdown(let preview):
            webView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            webView.loadHTMLString(MarkdownHTMLRenderer.render(preview.content), baseURL: nil)
        case .text(let preview):
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.font = Typography.monoUIFont(size: 13, weight: .regular)
            textView.text = preview.content
            contentContainer.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                textView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        case .quickLook(let localURL, _):
            let controller = QuickLookChildController(localURL: localURL)
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            controller.didMove(toParent: self)
            quickLookController = controller
        }
    }

    private func summaryText() -> String {
        var parts: [String] = []
        switch content {
        case .markdown(let preview), .text(let preview):
            parts.append(preview.mimeType)
            if preview.isTruncated {
                parts.append("preview capped at 512 KB")
            }
        case .quickLook(_, let mimeType):
            parts.append(mimeType)
        }
        if let sizeBytes = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if let modifiedAt = entry.modifiedAt, !modifiedAt.isEmpty {
            parts.append(modifiedAt)
        }
        return parts.joined(separator: " · ")
    }

    @objc private func saveToIPhoneTapped() {
        do {
            _ = try persistentFileURL()
            showToast(message: "Saved")
        } catch {
            showSimpleAlert(title: "Unable to Save", message: error.localizedDescription)
        }
    }

    @objc private func saveAsTapped() {
        do {
            let fileURL = try exportableFileURL()
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            present(picker, animated: true)
        } catch {
            showSimpleAlert(title: "Unable to Save", message: error.localizedDescription)
        }
    }

    @objc private func shareTapped() {
        do {
            let fileURL = try exportableFileURL()
            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = shareButton
            controller.popoverPresentationController?.sourceRect = shareButton.bounds
            present(controller, animated: true)
        } catch {
            showSimpleAlert(title: "Unable to Share", message: error.localizedDescription)
        }
    }

    private func exportableFileURL() throws -> URL {
        switch content {
        case .quickLook(let localURL, _):
            return localURL
        case .markdown(let preview), .text(let preview):
            let tempURL = try DownloadsManager.shared.temporaryPreviewURL(container: containerId, remotePath: remotePath)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            guard let data = preview.content.data(using: .utf8) else {
                throw SoyehtAPIClient.APIError.invalidURL
            }
            try data.write(to: tempURL)
            return tempURL
        }
    }

    private func persistentFileURL() throws -> URL {
        switch content {
        case .quickLook(let localURL, _):
            return try DownloadsManager.shared.copyRemoteDownload(
                from: localURL,
                container: containerId,
                remotePath: remotePath
            )
        case .markdown(let preview), .text(let preview):
            guard let data = preview.content.data(using: .utf8) else {
                throw SoyehtAPIClient.APIError.invalidURL
            }
            return try DownloadsManager.shared.writeRemotePreviewData(
                data,
                container: containerId,
                remotePath: remotePath
            )
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class QuickLookChildController: QLPreviewController, QLPreviewControllerDataSource {
    private let previewItem: QuickLookPreviewItem

    init(localURL: URL) {
        self.previewItem = QuickLookPreviewItem(url: localURL)
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewItem
    }
}

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        self.previewItemURL = url
        super.init()
    }
}

private enum MarkdownHTMLRenderer {
    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var htmlLines: [String] = []
        var inUL = false
        var inOL = false

        func closeListsIfNeeded() {
            if inUL {
                htmlLines.append("</ul>")
                inUL = false
            }
            if inOL {
                htmlLines.append("</ol>")
                inOL = false
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeListsIfNeeded()
                continue
            }

            if line.hasPrefix("### ") {
                closeListsIfNeeded()
                htmlLines.append("<h3>\(inlineHTML(String(line.dropFirst(4))))</h3>")
                continue
            }
            if line.hasPrefix("## ") {
                closeListsIfNeeded()
                htmlLines.append("<h2>\(inlineHTML(String(line.dropFirst(3))))</h2>")
                continue
            }
            if line.hasPrefix("# ") {
                closeListsIfNeeded()
                htmlLines.append("<h1>\(inlineHTML(String(line.dropFirst(2))))</h1>")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if inOL {
                    htmlLines.append("</ol>")
                    inOL = false
                }
                if !inUL {
                    htmlLines.append("<ul>")
                    inUL = true
                }
                htmlLines.append("<li>\(inlineHTML(String(line.dropFirst(2))))</li>")
                continue
            }
            if let orderedMatch = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                if inUL {
                    htmlLines.append("</ul>")
                    inUL = false
                }
                if !inOL {
                    htmlLines.append("<ol>")
                    inOL = true
                }
                htmlLines.append("<li>\(inlineHTML(String(line[orderedMatch.upperBound...])))</li>")
                continue
            }

            closeListsIfNeeded()
            htmlLines.append("<p>\(inlineHTML(line))</p>")
        }

        closeListsIfNeeded()

        let styles = """
        <style>
        \(Typography.webFontFaceCSS)
        :root { color-scheme: dark; }
        body {
          margin: 0;
          padding: 16px;
          background: #000000;
          color: #F5F5F5;
          font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
          font-size: 14px;
          line-height: 1.5;
        }
        a { color: #10B981; }
        h1, h2, h3 { color: #FFFFFF; margin: 0 0 12px 0; }
        p, ul, ol { margin: 0 0 12px 0; }
        code {
          background: #111111;
          padding: 1px 4px;
        }
        </style>
        """

        return """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            \(styles)
          </head>
          <body>\(htmlLines.joined())</body>
        </html>
        """
    }

    private static func inlineHTML(_ raw: String) -> String {
        var html = escape(raw)

        let replacements: [(String, String)] = [
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"`(.+?)`"#, "<code>$1</code>"),
        ]
        for (pattern, template) in replacements {
            html = html.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }

        html = html.replacingOccurrences(
            of: #"\[(.+?)\]\((https?://[^\s]+)\)"#,
            with: #"<a href="$2">$1</a>"#,
            options: .regularExpression
        )
        return html
    }

    private static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class RemoteFileDownloadManager: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((String, Double, String?) -> Void)?
    var onCompletion: ((String, URL) -> Void)?
    var onFailure: ((String, Error) -> Void)?

    private struct Context {
        let remotePath: String
        let container: String
        var lastWrittenBytes: Int64
        var lastSampleAt: TimeInterval
        var temporaryURL: URL?
    }

    private lazy var urlSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: .main
    )

    private var contextsByTaskIdentifier: [Int: Context] = [:]
    private var tasksByRemotePath: [String: URLSessionDownloadTask] = [:]

    func startPreviewDownload(
        request: URLRequest,
        container: String,
        remotePath: String
    ) {
        cancel(remotePath: remotePath)
        let task = urlSession.downloadTask(with: request)
        let context = Context(
            remotePath: remotePath,
            container: container,
            lastWrittenBytes: 0,
            lastSampleAt: Date().timeIntervalSinceReferenceDate,
            temporaryURL: nil
        )
        contextsByTaskIdentifier[task.taskIdentifier] = context
        tasksByRemotePath[remotePath] = task
        task.resume()
    }

    func cancel(remotePath: String) {
        guard let task = tasksByRemotePath.removeValue(forKey: remotePath) else { return }
        contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    func cancelAll() {
        tasksByRemotePath.keys.forEach(cancel(remotePath:))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard var context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let deltaBytes = totalBytesWritten - context.lastWrittenBytes
        let deltaTime = max(now - context.lastSampleAt, 0.001)
        context.lastWrittenBytes = totalBytesWritten
        context.lastSampleAt = now
        contextsByTaskIdentifier[downloadTask.taskIdentifier] = context

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }

        let bytesPerSecond = Double(deltaBytes) / deltaTime
        let speedText: String?
        if bytesPerSecond > 0 {
            speedText = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        } else {
            speedText = nil
        }

        onProgress?(context.remotePath, progress, speedText)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard var context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else { return }
        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = try DownloadsManager.shared.temporaryPreviewURL(
                container: context.container,
                remotePath: context.remotePath
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            context.temporaryURL = destination
            contextsByTaskIdentifier[downloadTask.taskIdentifier] = context
        } catch {
            contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier)
            tasksByRemotePath.removeValue(forKey: context.remotePath)
            onFailure?(context.remotePath, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else { return }
        tasksByRemotePath.removeValue(forKey: context.remotePath)

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue {
                return
            }
            onFailure?(context.remotePath, error)
            return
        }

        guard let temporaryURL = context.temporaryURL else {
            onFailure?(context.remotePath, URLError(.unknown))
            return
        }
        onCompletion?(context.remotePath, temporaryURL)
    }
}

private extension UIViewController {
    func showToast(message: String) {
        let toast = UILabel()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.text = message
        toast.accessibilityIdentifier = AccessibilityID.FilePreview.toast
        toast.isAccessibilityElement = true
        toast.accessibilityLabel = message
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        toast.textAlignment = .center
        toast.font = Typography.monoUIFont(size: 12, weight: .semibold)
        toast.numberOfLines = 0
        toast.alpha = 0
        view.addSubview(toast)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        UIView.animate(withDuration: 0.18, animations: {
            toast.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.18, delay: 1.0, options: []) {
                toast.alpha = 0
            } completion: { _ in
                toast.removeFromSuperview()
            }
        })
    }
}
