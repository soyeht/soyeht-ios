import SoyehtCore
import SwiftUI
import UIKit

struct SessionFileBrowserContainer: UIViewControllerRepresentable {
    let container: String
    let session: String
    let instanceName: String
    let initialPath: String?
    let isCommander: Bool
    let forceCommanderAccess: Bool
    let serverContext: ServerContext

    func makeUIViewController(context: Context) -> UINavigationController {
        let browser = FileBrowserViewController(
            container: container,
            session: session,
            instanceName: instanceName,
            initialPath: initialPath,
            isCommander: isCommander,
            forceCommanderAccess: forceCommanderAccess,
            serverContext: serverContext
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
    private let requestedInitialPath: String?
    private let serverContext: ServerContext
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
        initialPath: String?,
        isCommander: Bool,
        forceCommanderAccess: Bool,
        serverContext: ServerContext
    ) {
        self.containerId = container
        self.sessionName = session
        self.instanceName = instanceName
        self.requestedInitialPath = initialPath
        self.forceCommanderAccess = forceCommanderAccess
        self.serverContext = serverContext
        self.isCommander = forceCommanderAccess ||
            isCommander ||
            SessionStore.shared.hasLocalCommanderClaim(container: container, session: session)
        super.init(nibName: nil, bundle: nil)
        cellRegistration = UICollectionView.CellRegistration<FileBrowserCell, RemoteDirectoryEntry> { [weak self] cell, _, entry in
            self?.configure(cell: cell, with: entry)
        }
        attachmentRouter.container = container
        attachmentRouter.sessionName = session
        attachmentRouter.context = serverContext
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
        updatedLabel.font = Typography.monoUILabelMedium
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
        emptyLabel.font = Typography.monoUICardMedium
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
            let initialPath = Self.initialDirectoryPath(
                requestedInitialPath: self.requestedInitialPath,
                panePath: nil
            )
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

    static func initialDirectoryPath(requestedInitialPath: String?, panePath: String?) -> String {
        requestedInitialPath ?? panePath ?? "~"
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
