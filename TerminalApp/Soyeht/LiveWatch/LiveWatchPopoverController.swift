import UIKit
import SoyehtCore

private enum LiveWatchUITestSupport {
    static let isEnabled: Bool = {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("-SoyehtUITest") ||
            ProcessInfo.processInfo.environment["SOYEHT_UI_TEST"] == "1" {
            defaults.set(true, forKey: "SoyehtUITestMode")
            return true
        }
        return defaults.bool(forKey: "SoyehtUITestMode")
    }()
    static let peekDismissDelay: TimeInterval = isEnabled ? 2.5 : 0
    static let copyAccessibilityMaxChars = 512
}

private final class PaneStreamSocket: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable {
        case idle
        case connecting
        case open
        case reconnecting(attempt: Int)
        case closed

        var statusText: String {
            switch self {
            case .idle:
                return "idle"
            case .connecting:
                return "connecting"
            case .open:
                return "live"
            case .reconnecting(let attempt):
                return "reconnecting \(attempt)/3"
            case .closed:
                return "closed"
            }
        }
    }

    private static let transientCodes: Set<Int> = [-1005, -1001, -1004, -1009]

    var onTextChunk: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let request: URLRequest
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [onStateChange, state] in
                onStateChange?(state)
            }
        }
    }

    init(request: URLRequest) {
        self.request = request
        super.init()
    }

    deinit {
        stop()
    }

    func start() {
        guard webSocketTask == nil else { return }
        reconnectAttempt = 0
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .closed
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func connect() {
        state = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveLoop()
    }

    private func scheduleReconnect(after delay: TimeInterval, error: Error) {
        guard reconnectAttempt < maxReconnectAttempts else {
            DispatchQueue.main.async { [onFailure] in
                onFailure?(error)
            }
            stop()
            return
        }

        reconnectAttempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect()
            }
        }
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            self?.handleReceiveResult(result)
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        switch result {
        case .success(let message):
            if case .connecting = state {
                state = .open
            }
            reconnectAttempt = 0

            switch message {
            case .data(let data):
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { [onTextChunk] in
                    onTextChunk?(text)
                }
            case .string(let text):
                DispatchQueue.main.async { [onTextChunk] in
                    onTextChunk?(text)
                }
            @unknown default:
                break
            }
            receiveLoop()
        case .failure(let error):
            let nsError = error as NSError
            let isTransient = Self.transientCodes.contains(nsError.code)
            if isTransient {
                let delay = TimeInterval(max(reconnectAttempt, 1))
                scheduleReconnect(after: delay, error: error)
            } else {
                DispatchQueue.main.async { [onFailure] in
                    onFailure?(error)
                }
                stop()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        reconnectAttempt = 0
        state = .open
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        if closeCode == .normalClosure || closeCode == .goingAway {
            stop()
            return
        }
        let error = URLError(.networkConnectionLost)
        scheduleReconnect(after: TimeInterval(max(reconnectAttempt, 1)), error: error)
    }
}

private enum PaneTextSanitizer {
    private static let escapeRegex = try! NSRegularExpression(
        pattern: "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*\u{0007}|[@-_])",
        options: []
    )

    static func sanitize(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = escapeRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    static func normalized(_ text: String) -> String {
        sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class PaneTextBuffer {
    private(set) var raw = ""
    private var awaitingBootstrapChunk = false

    func reset(with snapshot: String) -> String {
        raw = snapshot
        awaitingBootstrapChunk = true
        return PaneTextSanitizer.sanitize(snapshot)
    }

    func append(_ chunk: String, maxCharacters: Int) -> String {
        if awaitingBootstrapChunk {
            awaitingBootstrapChunk = false
            let normalizedChunk = PaneTextSanitizer.normalized(chunk)
            let normalizedCurrent = PaneTextSanitizer.normalized(raw)
            if !normalizedChunk.isEmpty &&
                (normalizedChunk == normalizedCurrent ||
                 normalizedChunk.hasSuffix(normalizedCurrent) ||
                 normalizedCurrent.hasSuffix(normalizedChunk)) {
                return PaneTextSanitizer.sanitize(raw)
            }
        }

        raw += chunk
        if raw.count > maxCharacters {
            raw = String(raw.suffix(maxCharacters))
        }
        return PaneTextSanitizer.sanitize(raw)
    }

    var text: String {
        PaneTextSanitizer.sanitize(raw)
    }
}

private final class PeekCardView: UIView {
    private let textView = UITextView()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        layer.borderWidth = 1
        layer.cornerRadius = 0
        accessibilityIdentifier = AccessibilityID.DiffViewer.peekCard
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = SoyehtTheme.uiTextPrimary
        textView.font = Typography.monoUIFont(size: 12, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = Typography.monoUIFont(size: 11, weight: .medium)
        hintLabel.textColor = SoyehtTheme.uiTextSecondary
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textView)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -12),

            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String, scanning: Bool) {
        textView.text = text
        hintLabel.text = scanning ? "arraste ↓ para escanear" : "pressione mais → full diff"
        layer.borderColor = (scanning ? SoyehtTheme.uiAttachDocument : SoyehtTheme.uiAccentGreen).cgColor
    }
}

final class LiveWatchPopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let containerId: String
    private let sessionName: String
    private let paneId: String
    private let panePath: String

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let textView = UITextView()
    private let openButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusOuterRingView = UIView()
    private let statusInnerDotView = UIView()
    private let dimmingView = UIView()
    private let peekCardView = PeekCardView()
    private var appDidEnterBackgroundObserver: NSObjectProtocol?
    private var appWillEnterForegroundObserver: NSObjectProtocol?
    private var snapshotTask: Task<Void, Never>?
    private var isCommander: Bool
    private let streamClient: PaneStreamSocket
    private let paneTextBuffer = PaneTextBuffer()
    private var peekPromotionWorkItem: DispatchWorkItem?
    private var peekDismissWorkItem: DispatchWorkItem?
    private var peekBaseLineIndex = 0
    private var peekCurrentLineIndex = 0
    private var peekOriginPoint = CGPoint.zero
    private var isPeekPresented = false
    private var isPeekScanning = false
    private var didPromoteFromPeek = false
    private let peekLineCount = 20
    var onStreamActivity: (() -> Void)?

    private let serverContext: ServerContext

    init(container: String, session: String, paneId: String, panePath: String, isCommander: Bool, serverContext: ServerContext) {
        self.containerId = container
        self.sessionName = session
        self.paneId = paneId
        self.panePath = panePath
        self.isCommander = isCommander
        self.serverContext = serverContext
        let request = (try? SoyehtAPIClient.shared.makePaneStreamWebSocketRequest(
            container: container,
            session: session,
            paneId: paneId,
            context: serverContext
        )) ?? URLRequest(url: URL(string: "ws://invalid.local")!)
        self.streamClient = PaneStreamSocket(request: request)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        snapshotTask?.cancel()
        peekPromotionWorkItem?.cancel()
        peekDismissWorkItem?.cancel()
        streamClient.stop()
        if let observer = appDidEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appWillEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.accessibilityIdentifier = AccessibilityID.LiveWatch.popover
        preferredContentSize = CGSize(width: 380, height: 420)

        titleLabel.font = Typography.monoUIFont(size: 14, weight: .semibold)
        titleLabel.textColor = SoyehtTheme.uiTextPrimary
        titleLabel.text = panePath

        statusLabel.font = Typography.monoUIFont(size: 11, weight: .regular)
        statusLabel.textColor = SoyehtTheme.uiTextSecondary
        statusLabel.text = "pane \(paneId) · connecting"

        textView.isEditable = false
        textView.backgroundColor = SoyehtTheme.uiBgPrimary
        textView.textColor = SoyehtTheme.uiTextPrimary
        textView.font = Typography.monoUIFont(size: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.accessibilityIdentifier = AccessibilityID.LiveWatch.list
        textView.translatesAutoresizingMaskIntoConstraints = false
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePeekLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        textView.addGestureRecognizer(longPress)
        if LiveWatchUITestSupport.isEnabled {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePeekPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            textView.addGestureRecognizer(pan)
        }

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "Open Full Screen"
        buttonConfiguration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        buttonConfiguration.imagePadding = 6
        buttonConfiguration.baseBackgroundColor = SoyehtTheme.uiBgKeybar
        buttonConfiguration.baseForegroundColor = SoyehtTheme.uiTextPrimary
        buttonConfiguration.cornerStyle = .fixed
        buttonConfiguration.background.cornerRadius = 0
        openButton.configuration = buttonConfiguration
        openButton.layer.cornerRadius = 0
        openButton.accessibilityIdentifier = AccessibilityID.LiveWatch.openFullScreenButton
        openButton.addTarget(self, action: #selector(openFullScreenTapped), for: .touchUpInside)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusOuterRingView.translatesAutoresizingMaskIntoConstraints = false
        statusInnerDotView.translatesAutoresizingMaskIntoConstraints = false
        statusOuterRingView.layer.cornerRadius = 8
        statusOuterRingView.layer.borderWidth = 2
        statusOuterRingView.layer.borderColor = SoyehtTheme.uiAccentGreen.withAlphaComponent(0.5).cgColor
        statusOuterRingView.alpha = 0
        statusInnerDotView.layer.cornerRadius = 4
        statusInnerDotView.backgroundColor = SoyehtTheme.uiAccentGreen

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimmingView.alpha = 0
        dimmingView.isUserInteractionEnabled = false

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(statusOuterRingView)
        view.addSubview(statusInnerDotView)
        view.addSubview(textView)
        view.addSubview(openButton)
        view.addSubview(spinner)
        view.addSubview(dimmingView)
        view.addSubview(peekCardView)
        peekCardView.alpha = 0

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: statusOuterRingView.leadingAnchor, constant: -12),

            statusOuterRingView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusOuterRingView.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            statusOuterRingView.widthAnchor.constraint(equalToConstant: 16),
            statusOuterRingView.heightAnchor.constraint(equalToConstant: 16),

            statusInnerDotView.centerXAnchor.constraint(equalTo: statusOuterRingView.centerXAnchor),
            statusInnerDotView.centerYAnchor.constraint(equalTo: statusOuterRingView.centerYAnchor),
            statusInnerDotView.widthAnchor.constraint(equalToConstant: 8),
            statusInnerDotView.heightAnchor.constraint(equalToConstant: 8),

            textView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -12),

            openButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            openButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            openButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            openButton.heightAnchor.constraint(equalToConstant: 40),

            spinner.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            peekCardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            peekCardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            peekCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            peekCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            peekCardView.heightAnchor.constraint(equalToConstant: 260),
        ])

        streamClient.onStateChange = { [weak self] state in
            self?.updateStatus(for: state)
        }
        streamClient.onTextChunk = { [weak self] chunk in
            self?.handleIncomingChunk(chunk)
        }
        streamClient.onFailure = { [weak self] error in
            self?.statusLabel.text = error.localizedDescription
            self?.stopStatusPulse()
        }

        appDidEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.streamClient.stop()
            self?.stopStatusPulse()
        }

        appWillEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadSnapshotAndResumeStream()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadSnapshotAndResumeStream()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        peekPromotionWorkItem?.cancel()
        peekDismissWorkItem?.cancel()
        hidePeekCard(animated: false)
        streamClient.stop()
        stopStatusPulse()
        snapshotTask?.cancel()
    }

    func updateCommanderState(_ isCommander: Bool) {
        self.isCommander = isCommander
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }

    @objc private func openFullScreenTapped() {
        presentFullScreenViewer()
    }

    private func presentFullScreenViewer() {
        let controller = DiffViewerViewController(
            container: containerId,
            session: sessionName,
            paneId: paneId,
            panePath: panePath,
            isCommander: isCommander,
            serverContext: serverContext
        )
        let presenter = presentingViewController
        dismiss(animated: true) {
            if let navigationController =
                (presenter as? UINavigationController) ??
                presenter?.navigationController ??
                self.navigationController {
                navigationController.pushViewController(controller, animated: true)
            } else {
                presenter?.present(controller, animated: true)
            }
        }
    }

    private func reloadSnapshotAndResumeStream() {
        spinner.startAnimating()
        snapshotTask?.cancel()
        streamClient.stop()
        stopStatusPulse()
        textView.text = nil
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await SoyehtAPIClient.shared.capturePaneContent(
                    container: self.containerId,
                    session: self.sessionName,
                    paneId: self.paneId,
                    context: self.serverContext
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.textView.text = self.paneTextBuffer.reset(with: snapshot)
                    self.view.layoutIfNeeded()
                    self.textView.layoutIfNeeded()
                    self.scrollToBottom()
                    DispatchQueue.main.async { [weak self] in
                        self?.scrollToBottom()
                    }
                    self.streamClient.start()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func handleIncomingChunk(_ chunk: String) {
        let previous = textView.text ?? ""
        let merged = paneTextBuffer.append(chunk, maxCharacters: 120_000)
        textView.text = merged
        scrollToBottom()
        if merged != previous {
            onStreamActivity?()
            refreshPeekCard()
        }
    }

    private func updateStatus(for state: PaneStreamSocket.State) {
        statusLabel.text = "pane \(paneId) · \(state.statusText)"
        switch state {
        case .open:
            startStatusPulse()
        default:
            stopStatusPulse()
        }
    }

    private func startStatusPulse() {
        guard statusOuterRingView.layer.animation(forKey: "soyeht.liveWatch.pulse") == nil else { return }
        statusOuterRingView.alpha = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.15
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        statusOuterRingView.layer.add(group, forKey: "soyeht.liveWatch.pulse")
    }

    private func stopStatusPulse() {
        statusOuterRingView.layer.removeAnimation(forKey: "soyeht.liveWatch.pulse")
        statusOuterRingView.alpha = 0
    }

    private func scrollToBottom() {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return }
        textView.layoutIfNeeded()
        let insets = textView.adjustedContentInset
        let maxOffsetY = max(-insets.top, textView.contentSize.height - textView.bounds.height + insets.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
    }

    @objc private func handlePeekLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: textView)
        switch gesture.state {
        case .began:
            didPromoteFromPeek = false
            peekDismissWorkItem?.cancel()
            peekOriginPoint = location
            peekBaseLineIndex = lineIndex(for: location)
            peekCurrentLineIndex = peekBaseLineIndex
            isPeekScanning = false
            showPeekCard()
            schedulePeekPromotion()
        case .changed:
            guard isPeekPresented else { return }
            updatePeekSelection(for: location)
        case .ended, .cancelled, .failed:
            peekPromotionWorkItem?.cancel()
            if !didPromoteFromPeek {
                schedulePeekDismiss()
            }
        default:
            break
        }
    }

    @objc private func handlePeekPan(_ gesture: UIPanGestureRecognizer) {
        guard LiveWatchUITestSupport.isEnabled, isPeekPresented else { return }
        let location = gesture.location(in: textView)
        switch gesture.state {
        case .began:
            peekDismissWorkItem?.cancel()
            peekOriginPoint = location
            peekBaseLineIndex = peekCurrentLineIndex
        case .changed:
            updatePeekSelection(for: location)
        case .ended, .cancelled, .failed:
            schedulePeekDismiss()
        default:
            break
        }
    }

    private func schedulePeekPromotion() {
        peekPromotionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPeekPresented else { return }
            self.didPromoteFromPeek = true
            self.hidePeekCard(animated: false)
            self.presentFullScreenViewer()
        }
        peekPromotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func showPeekCard() {
        peekDismissWorkItem?.cancel()
        isPeekPresented = true
        refreshPeekCard()
        UIView.animate(withDuration: 0.18) {
            self.dimmingView.alpha = 1
            self.peekCardView.alpha = 1
        }
    }

    private func hidePeekCard(animated: Bool) {
        peekDismissWorkItem?.cancel()
        isPeekPresented = false
        isPeekScanning = false
        let animations = {
            self.dimmingView.alpha = 0
            self.peekCardView.alpha = 0
        }
        if animated {
            UIView.animate(withDuration: 0.16, animations: animations)
        } else {
            animations()
        }
    }

    private func refreshPeekCard() {
        guard isPeekPresented else { return }
        let snippet = snippetAround(lineIndex: peekCurrentLineIndex)
        peekCardView.update(text: snippet, scanning: isPeekScanning)
    }

    private func updatePeekSelection(for location: CGPoint) {
        let delta = location.y - peekOriginPoint.y
        let steps = Int(delta / 28.0)
        let candidateLine = max(0, peekBaseLineIndex + (steps * 6))
        isPeekScanning = abs(delta) > 24
        if candidateLine != peekCurrentLineIndex {
            peekCurrentLineIndex = candidateLine
        }
        refreshPeekCard()
    }

    private func schedulePeekDismiss() {
        peekDismissWorkItem?.cancel()
        guard LiveWatchUITestSupport.peekDismissDelay > 0 else {
            hidePeekCard(animated: true)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hidePeekCard(animated: true)
        }
        peekDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + LiveWatchUITestSupport.peekDismissDelay, execute: workItem)
    }

    private func lineIndex(for point: CGPoint) -> Int {
        let lineHeight = textView.font?.lineHeight ?? 16
        let adjustedY = max(0, point.y + textView.contentOffset.y - textView.textContainerInset.top)
        return Int(adjustedY / lineHeight)
    }

    private func snippetAround(lineIndex: Int) -> String {
        let lines = paneTextBuffer.text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }
        let start = max(0, lineIndex - (peekLineCount / 2))
        let end = min(lines.count, start + peekLineCount)
        return lines[start..<end].joined(separator: "\n")
    }
}

final class DiffViewerViewController: UIViewController {
    private let containerId: String
    private let sessionName: String
    private let paneId: String
    private let panePath: String
    private var isCommander: Bool

    private let textView = UITextView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private var snapshotTask: Task<Void, Never>?
    private let streamClient: PaneStreamSocket
    private let paneTextBuffer = PaneTextBuffer()
    private var appDidEnterBackgroundObserver: NSObjectProtocol?
    private var appWillEnterForegroundObserver: NSObjectProtocol?

    private let serverContext: ServerContext

    init(container: String, session: String, paneId: String, panePath: String, isCommander: Bool, serverContext: ServerContext) {
        self.containerId = container
        self.sessionName = session
        self.paneId = paneId
        self.panePath = panePath
        self.isCommander = isCommander
        self.serverContext = serverContext
        let request = (try? SoyehtAPIClient.shared.makePaneStreamWebSocketRequest(
            container: container,
            session: session,
            paneId: paneId,
            context: serverContext
        )) ?? URLRequest(url: URL(string: "ws://invalid.local")!)
        self.streamClient = PaneStreamSocket(request: request)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        snapshotTask?.cancel()
        streamClient.stop()
        if let observer = appDidEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appWillEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.accessibilityIdentifier = AccessibilityID.DiffViewer.fullScreen
        title = panePath

        textView.isEditable = false
        textView.backgroundColor = SoyehtTheme.uiBgPrimary
        textView.textColor = SoyehtTheme.uiTextPrimary
        textView.font = Typography.monoUIFont(size: 12, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isAccessibilityElement = true
        textView.accessibilityIdentifier = AccessibilityID.DiffViewer.textView
        textView.accessibilityLabel = "Live watch content"

        statusLabel.font = Typography.monoUIFont(size: 11, weight: .regular)
        statusLabel.textColor = SoyehtTheme.uiTextSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "pane \(paneId)"

        spinner.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = UIStackView(arrangedSubviews: [previousButton, nextButton, insertButton, copyButton, shareButton])
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fillEqually
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        configureToolbarButton(previousButton, title: "Top", icon: "arrow.up", action: #selector(topTapped))
        configureToolbarButton(nextButton, title: "Bottom", icon: "arrow.down", action: #selector(bottomTapped))
        configureToolbarButton(insertButton, title: "Add to prompt", icon: "text.insert", action: #selector(insertTapped))
        configureToolbarButton(copyButton, title: "Copy", icon: "square.on.square", action: #selector(copyTapped))
        configureToolbarButton(shareButton, title: "Share", icon: "square.and.arrow.up", action: #selector(shareTapped))

        previousButton.accessibilityIdentifier = AccessibilityID.DiffViewer.previousButton
        nextButton.accessibilityIdentifier = AccessibilityID.DiffViewer.nextButton
        insertButton.accessibilityIdentifier = AccessibilityID.DiffViewer.insertButton
        copyButton.accessibilityIdentifier = AccessibilityID.DiffViewer.copyButton
        shareButton.accessibilityIdentifier = AccessibilityID.DiffViewer.shareButton

        view.addSubview(statusLabel)
        view.addSubview(textView)
        view.addSubview(toolbar)
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            spinner.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
        ])

        streamClient.onStateChange = { [weak self] state in
            self?.statusLabel.text = "pane \(self?.paneId ?? "") · \(state.statusText)"
        }
        streamClient.onTextChunk = { [weak self] chunk in
            self?.appendText(chunk)
        }
        streamClient.onFailure = { [weak self] error in
            self?.statusLabel.text = error.localizedDescription
        }
        insertButton.isEnabled = isCommander

        appDidEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.streamClient.stop()
        }

        appWillEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadSnapshotAndResumeStream()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadSnapshotAndResumeStream()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        streamClient.stop()
        snapshotTask?.cancel()
    }

    private func configureToolbarButton(_ button: UIButton, title: String, icon: String, action: Selector) {
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
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func reloadSnapshotAndResumeStream() {
        spinner.startAnimating()
        snapshotTask?.cancel()
        streamClient.stop()
        textView.text = nil
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await SoyehtAPIClient.shared.capturePaneContent(
                    container: self.containerId,
                    session: self.sessionName,
                    paneId: self.paneId,
                    context: self.serverContext
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.textView.text = self.paneTextBuffer.reset(with: snapshot)
                    self.textView.layoutIfNeeded()
                    self.updateCopyAccessibilityValue()
                    self.updateViewportAccessibilityValue()
                    self.scrollToBottom()
                    self.updateViewportAccessibilityValue()
                    DispatchQueue.main.async { [weak self] in
                        self?.textView.layoutIfNeeded()
                        self?.updateViewportAccessibilityValue()
                    }
                    self.streamClient.start()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func appendText(_ chunk: String) {
        let merged = paneTextBuffer.append(chunk, maxCharacters: 240_000)
        textView.text = merged
        updateCopyAccessibilityValue()
        textView.layoutIfNeeded()
        scrollToBottom()
        updateViewportAccessibilityValue()
    }

    private func scrollToBottom() {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return }
        textView.layoutIfNeeded()
        let endLocation = max((textView.text as NSString?)?.length ?? 0, 1) - 1
        textView.scrollRangeToVisible(NSRange(location: endLocation, length: 1))
        let insets = textView.adjustedContentInset
        let maxOffsetY = max(-insets.top, textView.contentSize.height - textView.bounds.height + insets.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
        updateViewportAccessibilityValue()
    }

    private func updateCopyAccessibilityValue() {
        let excerpt = String((textView.text ?? "").prefix(LiveWatchUITestSupport.copyAccessibilityMaxChars))
        copyButton.accessibilityValue = excerpt.isEmpty ? nil : "copied: \(excerpt)"
    }

    private func updateViewportAccessibilityValue() {
        let lines = paneTextBuffer.text.components(separatedBy: "\n")
        let totalLines = max(lines.count, 1)
        let lineHeight = max(textView.font?.lineHeight ?? 16, 1)
        let topInset = textView.textContainerInset.top
        let visibleHeight = max(textView.bounds.height - textView.textContainerInset.top - textView.textContainerInset.bottom, lineHeight)
        let rawFirstLine = Int(floor((textView.contentOffset.y + topInset) / lineHeight))
        let firstLine = min(max(rawFirstLine, 0), max(totalLines - 1, 0))
        let visibleLineCount = max(Int(ceil(visibleHeight / lineHeight)), 1)
        let lastLine = min(totalLines - 1, firstLine + visibleLineCount - 1)
        let viewport = "viewport:first=\(firstLine);last=\(lastLine);total=\(totalLines)"
        textView.accessibilityValue = viewport
        previousButton.accessibilityValue = viewport
        nextButton.accessibilityValue = viewport
    }

    @objc private func topTapped() {
        textView.layoutIfNeeded()
        let topOffset = CGPoint(x: 0, y: -textView.adjustedContentInset.top)
        textView.setContentOffset(topOffset, animated: false)
        updateViewportAccessibilityValue()
    }

    @objc private func bottomTapped() {
        scrollToBottom()
        updateViewportAccessibilityValue()
    }

    @objc private func insertTapped() {
        guard isCommander else { return }
        let text = String((textView.text ?? "").suffix(4_096))
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

    @objc private func copyTapped() {
        UIPasteboard.general.string = textView.text
        updateCopyAccessibilityValue()
    }

    @objc private func shareTapped() {
        let controller = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.maxY - 40,
            width: 1,
            height: 1
        )
        present(controller, animated: true)
    }
}
