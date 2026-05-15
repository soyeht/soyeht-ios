import Cocoa
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import SoyehtCore

final class PreferencesTabViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let general = NSTabViewItem(viewController: PreferencesViewController())
        general.label = String(
            localized: "prefs.tab.general",
            defaultValue: "General",
            comment: "Preferences tab title for general app settings."
        )
        addTabViewItem(general)

        let devices = NSTabViewItem(viewController: DevicesPreferencesViewController())
        devices.label = String(
            localized: "prefs.tab.devices",
            defaultValue: "Devices",
            comment: "Preferences tab title for Mac and iPhone device settings."
        )
        addTabViewItem(devices)
    }
}

@MainActor
final class DevicesPreferencesViewController: NSViewController {
    private let localConnectionsLabel = NSTextField(labelWithString: "")
    private var pairingWindowController: MacIPhonePairingWindowController?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 700, height: 430))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        refreshLocalConnectionCount()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLocalConnectionCount()
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let title = NSTextField(labelWithString: String(
            localized: "prefs.devices.title",
            defaultValue: "Devices",
            comment: "Title for the Preferences Devices tab."
        ))
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let note = NSTextField(wrappingLabelWithString: String(
            localized: "prefs.devices.network.note",
            defaultValue: "Add an iPhone when this Mac and the iPhone can reach each other on the same LAN or Wi-Fi, or through Tailscale.",
            comment: "Network note for adding an iPhone from Preferences."
        ))
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(card(
            symbolName: "desktopcomputer",
            title: PairingStore.shared.macName,
            subtitle: String(
                localized: "prefs.devices.mac.subtitle",
                defaultValue: "This Mac is ready to use Soyeht.",
                comment: "Subtitle for the Mac device card in Preferences."
            ),
            accessory: nil
        ))

        let addButton = NSButton(
            title: String(
                localized: "prefs.devices.iphone.add",
                defaultValue: "Add iPhone",
                comment: "Button in Preferences that opens iPhone pairing."
            ),
            target: self,
            action: #selector(addIPhone)
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large

        let manageButton = NSButton(
            title: String(
                localized: "prefs.devices.local.manage",
                defaultValue: "Manage Local Connections",
                comment: "Button in Preferences that opens local iPhone connection management."
            ),
            target: self,
            action: #selector(manageLocalConnections)
        )
        manageButton.bezelStyle = .rounded

        let accessory = NSStackView(views: [addButton, manageButton])
        accessory.orientation = .horizontal
        accessory.spacing = 8

        stack.addArrangedSubview(card(
            symbolName: "iphone",
            title: String(
                localized: "prefs.devices.iphone.title",
                defaultValue: "iPhone",
                comment: "Title for the iPhone device card in Preferences."
            ),
            subtitle: String(
                localized: "prefs.devices.iphone.subtitle",
                defaultValue: "Use Add iPhone for household setup. Local connections are for terminal handoff and presence.",
                comment: "Subtitle explaining household iPhone pairing versus local Mac connections."
            ),
            accessory: accessory
        ))

        localConnectionsLabel.textColor = .secondaryLabelColor
        localConnectionsLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(localConnectionsLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func card(symbolName: String, title: String, subtitle: String, accessory: NSView?) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 8

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        [icon, textStack].forEach(container.addSubview)
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(accessory)
        }

        var constraints = [
            container.widthAnchor.constraint(equalToConstant: 636),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18),
        ]
        if let accessory {
            constraints.append(contentsOf: [
                accessory.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
                accessory.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -16),
            ])
        } else {
            constraints.append(textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func refreshLocalConnectionCount() {
        PairingStore.shared.reloadPersistedState()
        let count = PairingStore.shared.devices.count
        localConnectionsLabel.stringValue = String(
            localized: "prefs.devices.local.count",
            defaultValue: "\(count) local iPhone connection(s)",
            comment: "Count of locally paired iPhones for Mac terminal handoff. %lld = count."
        )
    }

    @objc private func addIPhone() {
        let controller = MacIPhonePairingWindowController()
        pairingWindowController = controller
        if let window = view.window, let sheet = controller.window {
            window.beginSheet(sheet) { [weak self] _ in
                self?.pairingWindowController = nil
                self?.refreshLocalConnectionCount()
            }
        } else {
            controller.showWindow(self)
        }
    }

    @objc private func manageLocalConnections() {
        PairedDevicesWindowController.shared.showWindow(nil)
    }
}

@MainActor
final class MacIPhonePairingWindowController: NSWindowController {
    private static let windowSize = NSSize(width: 440, height: 620)

    init() {
        let content = MacIPhonePairingHostingController()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "prefs.devices.addIPhone.window.title",
            defaultValue: "Add iPhone",
            comment: "Title of the Preferences Add iPhone sheet."
        )
        window.contentViewController = content
        content.preferredContentSize = Self.windowSize
        content.view.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.setContentSize(Self.windowSize)
        window.minSize = Self.windowSize
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

@MainActor
private final class MacIPhonePairingHostingController: NSHostingController<MacIPhonePairingPreferencesView> {
    private let pairingModel: MacIPhonePairingPreferencesModel

    init() {
        let model = MacIPhonePairingPreferencesModel()
        self.pairingModel = model
        super.init(rootView: MacIPhonePairingPreferencesView(model: model, closeAction: {}))
        rootView = MacIPhonePairingPreferencesView(model: model) { [weak self] in
            self?.closeSheet()
        }
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        pairingModel.stop()
    }

    private func closeSheet() {
        if let sheetParent = view.window?.sheetParent, let window = view.window {
            sheetParent.endSheet(window)
        } else {
            view.window?.close()
        }
    }
}

@MainActor
private final class MacIPhonePairingPreferencesModel: ObservableObject {
    @Published var instructions: [LocalizedStringResource] = [
        LocalizedStringResource(
            "prefs.devices.addIPhone.loading",
            defaultValue: "Preparing this Mac for iPhone pairing...",
            comment: "Loading text while Preferences prepares the iPhone pairing link."
        ),
    ]
    @Published var homeCodeWords: [String]?
    @Published var status: IPhonePairingSheetStatus? = IPhonePairingSheetStatus(
        message: LocalizedStringResource(
            "prefs.devices.addIPhone.loading.status",
            defaultValue: "Preparing...",
            comment: "Compact loading status while Preferences prepares iPhone pairing."
        ),
        showsProgress: true
    )
    @Published var pairingURI = ""
    @Published var showFallbackPairing = false
    @Published var copiedPairLink = false

    private var didStart = false
    private var loadTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?

    func start() {
        guard !didStart else { return }
        didStart = true
        loadTask = Task { await loadPairingLink() }
    }

    func stop() {
        loadTask?.cancel()
        listenerTask?.cancel()
        pollTask?.cancel()
        copyResetTask?.cancel()
        loadTask = nil
        listenerTask = nil
        pollTask = nil
        copyResetTask = nil
        didStart = false
    }

    func copyPairingLink() {
        guard !pairingURI.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingURI, forType: .string)
        copiedPairLink = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedPairLink = false
        }
    }

    private func loadPairingLink() async {
        do {
            let response = try await BootstrapPairDeviceURIClient(
                baseURL: TheyOSEnvironment.bootstrapBaseURL
            ).fetch()
            presentPairing(PairingPayload(
                houseName: response.houseName,
                hostLabel: response.hostLabel,
                pairingURI: response.pairDeviceURI,
                isFirstOwnerPairing: true,
                initialDeviceCount: await Self.currentDeviceCount()
            ))
        } catch {
            do {
                presentPairing(try await makeDevicePairingPayload())
            } catch {
                instructions = [
                    LocalizedStringResource(
                        "prefs.devices.addIPhone.unavailable",
                        defaultValue: "This Mac is not ready to add an iPhone yet.",
                        comment: "Shown when iPhone pairing cannot be prepared from Preferences."
                    ),
                ]
                homeCodeWords = nil
                status = nil
                pairingURI = ""
                showFallbackPairing = false
            }
        }
    }

    private func presentPairing(_ payload: PairingPayload) {
        if payload.isFirstOwnerPairing {
            instructions = [
                LocalizedStringResource(
                    "prefs.devices.addIPhone.instructions.open",
                    defaultValue: "Open Soyeht on your iPhone and start looking for this Mac.",
                    comment: "Primary instruction shown in the Add iPhone sheet."
                ),
                LocalizedStringResource(
                    "prefs.devices.addIPhone.instructions.network",
                    defaultValue: "Keep both devices on the same LAN or Wi-Fi, or connected through Tailscale. Guest networks can block pairing.",
                    comment: "Network note shown in the Add iPhone sheet."
                ),
            ]
        } else {
            instructions = [
                LocalizedStringResource(
                    "prefs.devices.addIPhone.existingOwner.instructions.open",
                    defaultValue: "Open Soyeht on the new iPhone and start looking for this Mac.",
                    comment: "Primary instruction shown when adding another iPhone to an existing home."
                ),
                LocalizedStringResource(
                    "prefs.devices.addIPhone.existingOwner.instructions.approve",
                    defaultValue: "Then approve it from an iPhone that already belongs to this home.",
                    comment: "Approval instruction shown when adding another iPhone to an existing home."
                ),
            ]
        }
        homeCodeWords = Self.homeCodeWords(for: payload.pairingURI)
        status = IPhonePairingSheetStatus(
            message: LocalizedStringResource(
                "prefs.devices.addIPhone.waiting",
                defaultValue: "Waiting for iPhone...",
                comment: "Status shown while the Mac is listening for an iPhone."
            ),
            showsProgress: true
        )
        pairingURI = payload.pairingURI
        showFallbackPairing = false
        copiedPairLink = false
        startListening(payload)
        startPollingForReady(payload)
    }

    private func startListening(_ payload: PairingPayload) {
        listenerTask?.cancel()
        let existingHouse = SetupInvitationExistingHouse(
            name: payload.houseName,
            hostLabel: payload.hostLabel,
            pairDeviceURI: payload.pairingURI
        )
        listenerTask = Task {
            while !Task.isCancelled {
                let listener = SetupInvitationListener(
                    engineBaseURL: TheyOSEnvironment.bootstrapBaseURL,
                    existingHouse: existingHouse
                )
                let outcome = await listener.listen()
                switch outcome {
                case .invitationClaimed:
                    showIPhoneFound(payload)
                    return
                case .notFound, .failed:
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startPollingForReady(_ payload: PairingPayload) {
        pollTask?.cancel()
        pollTask = Task {
            let client = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)
            var initialDeviceCount = payload.initialDeviceCount
            while !Task.isCancelled {
                if let status = try? await client.fetch() {
                    if initialDeviceCount == nil {
                        initialDeviceCount = status.deviceCount
                    }
                    let pairedNewDevice = initialDeviceCount.map { status.deviceCount > $0 } ?? payload.isFirstOwnerPairing
                    if status.state != .ready || !pairedNewDevice {
                        try? await Task.sleep(for: .milliseconds(700))
                        continue
                    }
                    self.status = IPhonePairingSheetStatus(
                        message: LocalizedStringResource(
                            "prefs.devices.addIPhone.connected",
                            defaultValue: "iPhone connected. You can close this window.",
                            comment: "Shown after iPhone pairing completes from Preferences."
                        ),
                        showsProgress: false
                    )
                    listenerTask?.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func makeDevicePairingPayload() async throws -> PairingPayload {
        let identity = try await HouseholdIdentityFetcher(baseURL: TheyOSEnvironment.bootstrapBaseURL).fetch()
        let endpoint = await MacPairingReachability.reachableEngineURL(
            localEngineBaseURL: TheyOSEnvironment.bootstrapBaseURL
        )
        let link = HouseholdDevicePairingLink(
            endpoint: endpoint,
            householdId: identity.householdId,
            householdPublicKey: identity.householdPublicKey,
            householdName: identity.name,
            pairingNonce: PairingCrypto.randomBytes(count: HouseholdDevicePairingLink.pairingNonceLength)
        )
        return PairingPayload(
            houseName: identity.name,
            hostLabel: Host.current().localizedName ?? "Mac",
            pairingURI: try link.url().absoluteString,
            isFirstOwnerPairing: false,
            initialDeviceCount: await Self.currentDeviceCount()
        )
    }

    private func showIPhoneFound(_ payload: PairingPayload) {
        status = IPhonePairingSheetStatus(
            message: payload.isFirstOwnerPairing ? LocalizedStringResource(
                "prefs.devices.addIPhone.found",
                defaultValue: "iPhone found. Confirm the home security code matches, then finish on your iPhone.",
                comment: "Shown when the Mac discovers the iPhone during first-owner pairing."
            ) : LocalizedStringResource(
                "prefs.devices.addIPhone.existingOwner.found",
                defaultValue: "iPhone found. Finish approval on an iPhone that already belongs to this home.",
                comment: "Shown when a new iPhone starts delegated device pairing."
            ),
            showsProgress: false
        )
    }

    private static func homeCodeWords(for pairingURI: String) -> [String]? {
        guard let url = URL(string: pairingURI),
              let input = try? householdFingerprintInput(from: url),
              let fingerprint = try? OperatorFingerprint.derive(
                machinePublicKey: input.householdPublicKey,
                pairingNonce: input.pairingNonce,
                wordlist: try BIP39Wordlist()
              ),
              fingerprint.words.count == OperatorFingerprint.wordCount else {
            return nil
        }
        return fingerprint.words
    }

    private static func householdFingerprintInput(from url: URL) throws -> (householdPublicKey: Data, pairingNonce: Data) {
        if isHouseholdDevicePairingURL(url) {
            let link = try HouseholdDevicePairingLink(url: url)
            return (link.householdPublicKey, link.pairingNonce)
        }
        let qr = try PairDeviceQR(url: url, now: Date())
        return (qr.householdPublicKey, qr.nonce)
    }

    private static func isHouseholdDevicePairingURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/device-pairing"
    }

    private static func currentDeviceCount() async -> UInt8? {
        try? await BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL).fetch().deviceCount
    }

    private struct PairingPayload {
        let houseName: String
        let hostLabel: String
        let pairingURI: String
        let isFirstOwnerPairing: Bool
        let initialDeviceCount: UInt8?
    }
}

private struct MacIPhonePairingPreferencesView: View {
    @ObservedObject var model: MacIPhonePairingPreferencesModel
    let closeAction: () -> Void

    var body: some View {
        IPhonePairingSheetContent(
            title: LocalizedStringResource(
                "prefs.devices.addIPhone.title",
                defaultValue: "Add iPhone",
                comment: "Title inside the Add iPhone pairing sheet."
            ),
            instructions: model.instructions,
            homeCodeWords: model.homeCodeWords,
            status: model.status,
            pairingURI: model.pairingURI,
            showFallbackPairing: $model.showFallbackPairing,
            copiedPairLink: model.copiedPairLink,
            onCopyPairLink: { model.copyPairingLink() },
            closeAction: closeAction
        )
        .task { model.start() }
    }
}

@MainActor
private final class MacIPhonePairingViewController: NSViewController {
    private static let qrContext = CIContext()

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let securityCodeBox = NSView()
    private let securityCodeField = NSTextField(labelWithString: "")
    private let waitingIndicator = NSProgressIndicator()
    private let waitingLabel = NSTextField(labelWithString: "")
    private let qrImageView = NSImageView()
    private let pairLinkField = NSTextField()
    private let fallbackButton = NSButton()
    private let copyButton = NSButton()
    private var loadTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private struct PairingPayload {
        let houseName: String
        let hostLabel: String
        let pairingURI: String
        let isFirstOwnerPairing: Bool
        let initialDeviceCount: UInt8?
    }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 520, height: 470))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadTask = Task { await loadPairingLink() }
    }

    deinit {
        loadTask?.cancel()
        listenerTask?.cancel()
        pollTask?.cancel()
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let title = NSTextField(labelWithString: String(
            localized: "prefs.devices.addIPhone.title",
            defaultValue: "Add iPhone",
            comment: "Title inside the Add iPhone pairing sheet."
        ))
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4
        statusLabel.preferredMaxLayoutWidth = 450

        securityCodeBox.translatesAutoresizingMaskIntoConstraints = false
        securityCodeBox.wantsLayer = true
        securityCodeBox.layer?.cornerRadius = 10
        securityCodeBox.layer?.borderWidth = 1
        securityCodeBox.layer?.borderColor = NSColor.separatorColor.cgColor
        securityCodeBox.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        securityCodeBox.isHidden = true

        let securityTitle = NSTextField(labelWithString: String(
            localized: "prefs.devices.addIPhone.security.title",
            defaultValue: "Security code",
            comment: "Header above the security words shown while pairing an iPhone."
        ))
        securityTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        securityTitle.textColor = .secondaryLabelColor

        securityCodeField.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        securityCodeField.textColor = .labelColor
        securityCodeField.maximumNumberOfLines = 3
        securityCodeField.alignment = .left

        let securityHint = NSTextField(wrappingLabelWithString: String(
            localized: "prefs.devices.addIPhone.security.hint",
            defaultValue: "Compare these words with your iPhone before connecting.",
            comment: "Short instruction for validating the Mac/iPhone security code."
        ))
        securityHint.font = .systemFont(ofSize: 12)
        securityHint.textColor = .secondaryLabelColor
        securityHint.maximumNumberOfLines = 2

        let securityStack = NSStackView(views: [securityTitle, securityCodeField, securityHint])
        securityStack.orientation = .vertical
        securityStack.alignment = .leading
        securityStack.spacing = 8
        securityStack.translatesAutoresizingMaskIntoConstraints = false
        securityCodeBox.addSubview(securityStack)

        waitingIndicator.style = .spinning
        waitingIndicator.controlSize = .small
        waitingIndicator.isDisplayedWhenStopped = false
        waitingIndicator.startAnimation(nil)

        waitingLabel.stringValue = String(
            localized: "prefs.devices.addIPhone.waiting",
            defaultValue: "Waiting for iPhone...",
            comment: "Status shown while the Mac is listening for an iPhone."
        )
        waitingLabel.textColor = .secondaryLabelColor

        let waitingStack = NSStackView(views: [waitingIndicator, waitingLabel])
        waitingStack.orientation = .horizontal
        waitingStack.alignment = .centerY
        waitingStack.spacing = 8
        waitingStack.isHidden = true

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.cornerRadius = 8
        qrImageView.isHidden = true

        pairLinkField.isEditable = false
        pairLinkField.isSelectable = true
        pairLinkField.isBezeled = true
        pairLinkField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pairLinkField.lineBreakMode = .byTruncatingMiddle
        pairLinkField.isHidden = true

        fallbackButton.title = String(
            localized: "prefs.devices.addIPhone.fallback",
            defaultValue: "Use QR/link instead",
            comment: "Button that reveals the manual QR and link fallback."
        )
        fallbackButton.target = self
        fallbackButton.action = #selector(showFallbackPairing)
        fallbackButton.isHidden = true

        copyButton.title = String(
            localized: "prefs.devices.addIPhone.copy",
            defaultValue: "Copy Pairing Link",
            comment: "Button that copies the iPhone pairing link from Preferences."
        )
        copyButton.target = self
        copyButton.action = #selector(copyPairingLink)
        copyButton.isHidden = true

        let closeButton = NSButton(
            title: String(localized: "common.button.close", defaultValue: "Close"),
            target: self,
            action: #selector(closeSheet)
        )

        [
            title,
            statusLabel,
            securityCodeBox,
            waitingStack,
            qrImageView,
            pairLinkField,
            copyButton,
            fallbackButton,
            closeButton,
        ].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            securityCodeBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            securityStack.topAnchor.constraint(equalTo: securityCodeBox.topAnchor, constant: 14),
            securityStack.leadingAnchor.constraint(equalTo: securityCodeBox.leadingAnchor, constant: 16),
            securityStack.trailingAnchor.constraint(equalTo: securityCodeBox.trailingAnchor, constant: -16),
            securityStack.bottomAnchor.constraint(equalTo: securityCodeBox.bottomAnchor, constant: -14),
            qrImageView.widthAnchor.constraint(equalToConstant: 220),
            qrImageView.heightAnchor.constraint(equalToConstant: 220),
            pairLinkField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showLoading()
    }

    private func showLoading() {
        statusLabel.stringValue = String(
            localized: "prefs.devices.addIPhone.loading",
            defaultValue: "Preparing this Mac for iPhone pairing...",
            comment: "Loading text while Preferences prepares the iPhone pairing link."
        )
        waitingIndicator.superview?.isHidden = true
        securityCodeBox.isHidden = true
        fallbackButton.isHidden = true
        hideFallbackPairing()
    }

    private func loadPairingLink() async {
        do {
            let response = try await BootstrapPairDeviceURIClient(
                baseURL: TheyOSEnvironment.bootstrapBaseURL
            ).fetch()
            presentPairing(PairingPayload(
                houseName: response.houseName,
                hostLabel: response.hostLabel,
                pairingURI: response.pairDeviceURI,
                isFirstOwnerPairing: true,
                initialDeviceCount: await Self.currentDeviceCount()
            ))
        } catch {
            do {
                presentPairing(try await makeDevicePairingPayload())
            } catch {
                statusLabel.stringValue = String(
                    localized: "prefs.devices.addIPhone.unavailable",
                    defaultValue: "This Mac is not ready to add an iPhone yet.",
                    comment: "Shown when iPhone pairing cannot be prepared from Preferences."
                )
                waitingIndicator.superview?.isHidden = true
                securityCodeBox.isHidden = true
                fallbackButton.isHidden = true
                hideFallbackPairing()
            }
        }
    }

    private func presentPairing(_ payload: PairingPayload) {
        if payload.isFirstOwnerPairing {
            statusLabel.stringValue = String(
                localized: "prefs.devices.addIPhone.instructions",
                defaultValue: "Open Soyeht on your iPhone and start looking for this Mac. Keep both devices on the same LAN or Wi-Fi, or connected through Tailscale.",
                comment: "Instructions shown in the Add iPhone sheet."
            )
        } else {
            statusLabel.stringValue = String(
                localized: "prefs.devices.addIPhone.existingOwner.instructions",
                defaultValue: "Open Soyeht on the new iPhone and start looking for this Mac. Then approve it from an iPhone that already belongs to this home.",
                comment: "Instructions shown when adding another iPhone to an existing home."
            )
        }
        configureSecurityCode(for: payload)
        pairLinkField.stringValue = payload.pairingURI
        qrImageView.image = Self.makeQRImage(from: payload.pairingURI)
        hideFallbackPairing()
        fallbackButton.isHidden = false
        waitingLabel.stringValue = String(
            localized: "prefs.devices.addIPhone.waiting",
            defaultValue: "Waiting for iPhone...",
            comment: "Status shown while the Mac is listening for an iPhone."
        )
        waitingIndicator.superview?.isHidden = false
        waitingIndicator.startAnimation(nil)
        startListening(payload)
        startPollingForReady(payload)
    }

    private func startListening(_ payload: PairingPayload) {
        listenerTask?.cancel()
        let existingHouse = SetupInvitationExistingHouse(
            name: payload.houseName,
            hostLabel: payload.hostLabel,
            pairDeviceURI: payload.pairingURI
        )
        listenerTask = Task {
            while !Task.isCancelled {
                let listener = SetupInvitationListener(
                    engineBaseURL: TheyOSEnvironment.bootstrapBaseURL,
                    existingHouse: existingHouse
                )
                let outcome = await listener.listen()
                switch outcome {
                case .invitationClaimed:
                    self.showIPhoneFound(payload)
                    return
                case .notFound:
                    break
                case .failed:
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startPollingForReady(_ payload: PairingPayload) {
        pollTask?.cancel()
        pollTask = Task {
            let client = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)
            var initialDeviceCount = payload.initialDeviceCount
            while !Task.isCancelled {
                if let status = try? await client.fetch() {
                    if initialDeviceCount == nil {
                        initialDeviceCount = status.deviceCount
                    }
                    let pairedNewDevice = initialDeviceCount.map { status.deviceCount > $0 } ?? payload.isFirstOwnerPairing
                    if status.state != .ready || !pairedNewDevice {
                        try? await Task.sleep(for: .milliseconds(700))
                        continue
                    }
                    statusLabel.stringValue = String(
                        localized: "prefs.devices.addIPhone.connected",
                        defaultValue: "iPhone connected. You can close this window.",
                        comment: "Shown after iPhone pairing completes from Preferences."
                    )
                    waitingLabel.stringValue = String(
                        localized: "prefs.devices.addIPhone.connected.status",
                        defaultValue: "Connected",
                        comment: "Compact status shown after iPhone pairing completes."
                    )
                    waitingIndicator.stopAnimation(nil)
                    listenerTask?.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func makeDevicePairingPayload() async throws -> PairingPayload {
        let identity = try await HouseholdIdentityFetcher(baseURL: TheyOSEnvironment.bootstrapBaseURL).fetch()
        let endpoint = await MacPairingReachability.reachableEngineURL(
            localEngineBaseURL: TheyOSEnvironment.bootstrapBaseURL
        )
        let link = HouseholdDevicePairingLink(
            endpoint: endpoint,
            householdId: identity.householdId,
            householdPublicKey: identity.householdPublicKey,
            householdName: identity.name,
            pairingNonce: PairingCrypto.randomBytes(count: HouseholdDevicePairingLink.pairingNonceLength)
        )
        return PairingPayload(
            houseName: identity.name,
            hostLabel: Host.current().localizedName ?? "Mac",
            pairingURI: try link.url().absoluteString,
            isFirstOwnerPairing: false,
            initialDeviceCount: await Self.currentDeviceCount()
        )
    }

    private func showIPhoneFound(_ payload: PairingPayload) {
        if payload.isFirstOwnerPairing {
            statusLabel.stringValue = String(
                localized: "prefs.devices.addIPhone.found",
                defaultValue: "iPhone found. Confirm the security code matches, then finish on your iPhone.",
                comment: "Shown when the Mac discovers the iPhone during first-owner pairing."
            )
        } else {
            statusLabel.stringValue = String(
                localized: "prefs.devices.addIPhone.existingOwner.found",
                defaultValue: "iPhone found. Finish approval on an iPhone that already belongs to this home.",
                comment: "Shown when a new iPhone starts delegated device pairing."
            )
        }
        waitingLabel.stringValue = String(
            localized: "prefs.devices.addIPhone.found.status",
            defaultValue: "iPhone found",
            comment: "Compact status shown after an iPhone is discovered."
        )
        waitingIndicator.stopAnimation(nil)
    }

    private func configureSecurityCode(for payload: PairingPayload) {
        guard let url = URL(string: payload.pairingURI),
              let words = try? Self.securityCodeWords(for: url),
              words.count == OperatorFingerprint.wordCount else {
            securityCodeBox.isHidden = true
            return
        }

        securityCodeField.stringValue = Self.formatSecurityCode(words)
        securityCodeBox.isHidden = false
    }

    private static func securityCodeWords(for url: URL) throws -> [String] {
        let householdPublicKey: Data
        let pairingNonce: Data
        if isHouseholdDevicePairingURL(url) {
            let link = try HouseholdDevicePairingLink(url: url)
            householdPublicKey = link.householdPublicKey
            pairingNonce = link.pairingNonce
        } else {
            let qr = try PairDeviceQR(url: url, now: Date())
            householdPublicKey = qr.householdPublicKey
            pairingNonce = qr.nonce
        }
        let fingerprint = try OperatorFingerprint.derive(
            machinePublicKey: householdPublicKey,
            pairingNonce: pairingNonce,
            wordlist: try BIP39Wordlist()
        )
        return fingerprint.words
    }

    private static func isHouseholdDevicePairingURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/device-pairing"
    }

    private static func formatSecurityCode(_ words: [String]) -> String {
        let cells = words.enumerated().map { index, word in
            "\(index + 1) \(word)"
        }
        guard cells.count == 6 else { return cells.joined(separator: "   ") }
        return [
            "\(cells[0].padding(toLength: 17, withPad: " ", startingAt: 0))\(cells[1])",
            "\(cells[2].padding(toLength: 17, withPad: " ", startingAt: 0))\(cells[3])",
            "\(cells[4].padding(toLength: 17, withPad: " ", startingAt: 0))\(cells[5])",
        ].joined(separator: "\n")
    }

    private static func currentDeviceCount() async -> UInt8? {
        try? await BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL).fetch().deviceCount
    }

    private func hideFallbackPairing() {
        pairLinkField.isHidden = true
        copyButton.isHidden = true
        qrImageView.isHidden = true
        copyButton.title = String(
            localized: "prefs.devices.addIPhone.copy",
            defaultValue: "Copy Pairing Link",
            comment: "Button that copies the iPhone pairing link from Preferences."
        )
    }

    @objc private func showFallbackPairing() {
        qrImageView.isHidden = qrImageView.image == nil
        pairLinkField.isHidden = false
        copyButton.isHidden = false
        fallbackButton.isHidden = true
    }

    @objc private func copyPairingLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairLinkField.stringValue, forType: .string)
        copyButton.title = String(
            localized: "prefs.devices.addIPhone.copied",
            defaultValue: "Pairing Link Copied",
            comment: "Button state after copying the iPhone pairing link."
        )
    }

    @objc private func closeSheet() {
        if let sheetParent = view.window?.sheetParent, let window = view.window {
            sheetParent.endSheet(window)
        } else {
            view.window?.close()
        }
    }

    private static func makeQRImage(from deepLink: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(deepLink.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = qrContext.createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private struct HouseholdIdentitySummary {
    let householdId: String
    let householdPublicKey: Data
    let name: String
}

private struct HouseholdIdentityFetcher {
    let baseURL: URL

    func fetch() async throws -> HouseholdIdentitySummary {
        let url = baseURL.appendingPathComponent("api/v1/household/identity")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(IdentityEnvelope.self, from: data)
        guard let publicKey = Data(base64Encoded: envelope.householdPublicKeyBase64),
              publicKey.count == HouseholdIdentifiers.compressedP256PublicKeyLength else {
            throw URLError(.cannotDecodeContentData)
        }
        return HouseholdIdentitySummary(
            householdId: envelope.householdId,
            householdPublicKey: publicKey,
            name: envelope.name
        )
    }

    private struct IdentityEnvelope: Decodable {
        let householdId: String
        let householdPublicKeyBase64: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case householdId = "hh_id"
            case householdPublicKeyBase64 = "hh_pub_b64"
            case name
        }
    }
}

private enum MacPairingReachability {
    static func reachableEngineURL(localEngineBaseURL: URL) async -> URL {
        guard let status = await tailscaleStatus(),
              let node = status.selfNode else {
            return localEngineBaseURL
        }
        let port = localEngineBaseURL.port ?? 8091
        if let dnsName = normalizedDNSName(node.dnsName),
           let url = URL(string: "http://\(dnsName):\(port)") {
            return url
        }
        if let ip = node.tailscaleIPs.first(where: isTailscaleIPv4),
           let url = URL(string: "http://\(ip):\(port)") {
            return url
        }
        return localEngineBaseURL
    }

    private static func tailscaleStatus() async -> TailscaleStatus? {
        guard let binary = tailscaleBinary() else { return nil }
        guard let data = await run(binary, arguments: ["status", "--json"], timeout: 2.0) else { return nil }
        return try? JSONDecoder().decode(TailscaleStatus.self, from: data)
    }

    private static func tailscaleBinary() -> String? {
        [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()

            let gate = ResumeOnce()
            process.terminationHandler = { _ in
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                if gate.claim() {
                    continuation.resume(returning: data)
                }
            }

            do {
                try process.run()
            } catch {
                if gate.claim() {
                    continuation.resume(returning: nil)
                }
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                if gate.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func normalizedDNSName(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isTailscaleIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}

private struct TailscaleStatus: Decodable {
    let selfNode: TailscaleNode?

    enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
    }
}

private struct TailscaleNode: Decodable {
    let dnsName: String?
    let tailscaleIPs: [String]

    enum CodingKeys: String, CodingKey {
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
    }
}
