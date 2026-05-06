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

// Explicit `@MainActor` — see `ViewController.swift` for the rationale.
@MainActor
final class FileBrowserViewController: UIViewController {
    static let maxTextPreviewBytes = 524_288
    static let inlineDownloadThresholdBytes = 5_000_000
    // Keep large-file downloads visible long enough for the inline progress
    // state to be perceivable on-device and by Appium before Quick Look takes over.
    static let minimumInlineDownloadDuration: TimeInterval = 5.0
    private static let uiTestForceFallbackRoot = ProcessInfo.processInfo.environment["SOYEHT_UI_TEST_FORCE_BROWSER_FALLBACK"] == "1"
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let textPreviewExtensions: Set<String> = [
        "txt", "log", "swift", "json", "yml", "yaml", "sh"
    ]
    static let quickLookExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "webp",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav",
        "ppt", "pptx", "key"
    ]

    let containerId: String
    let sessionName: String
    private let instanceName: String
    let requestedInitialPath: String?
    let serverContext: ServerContext
    let historyStore = NavigationHistoryStore.shared
    let attachmentRouter = AttachmentSourceRouter()
    let downloadsManager = DownloadsManager.shared
    let remoteDownloadManager = RemoteFileDownloadManager()
    let fileSizeFormatter = ByteCountFormatter()
    let relativeDateFormatter = RelativeDateTimeFormatter()
    private let sessionStore = SessionStore.shared

    lazy var collectionView = makeCollectionView()
    lazy var refreshControl = makeRefreshControl()
    let breadcrumbBar = BreadcrumbBar()
    let sourceChipStrip = SourceChipStrip()
    let updatedLabel = UILabel()
    let loadingView = UIActivityIndicatorView(style: .medium)
    let loadingContainer = UIView()
    let emptyLabel = UILabel()

    var cellRegistration: UICollectionView.CellRegistration<FileBrowserCell, RemoteDirectoryEntry>!

    var currentPath: String?
    var entries: [RemoteDirectoryEntry] = []
    var downloadStates: [String: FileRowDownloadState] = [:]
    var inlineQuickLookDelayPaths: Set<String> = []
    var deferredPreviewWorkItems: [String: DispatchWorkItem] = [:]
    var loadTask: Task<Void, Never>?
    var isCommander: Bool
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

    func showErrorAlert(title: String, error: Error) {
        showSimpleAlert(title: title, message: error.localizedDescription)
    }

    func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
