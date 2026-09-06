import Cocoa
import SwiftUI
import SoyehtCore
import os

final class PreferencesTabViewController: NSTabViewController {
    private enum TabIndex {
        static let devices = 1
}

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

    func selectDevicesTab() {
        guard tabViewItems.indices.contains(TabIndex.devices) else { return }
        selectedTabViewItemIndex = TabIndex.devices
    }
}

/// Local-only, non-authoritative connection badge for the Devices
/// preferences pane, fed exclusively by `PairingPresenceServer`'s local
/// WebSocket/HMAC pairing sessions (`hasConnectedDevices`). Deliberately
/// structured so it cannot accept a `DeviceCert`, `d_id`, household roster
/// entry, membership record, route, or `VerifiedMesh` fact: its only input
/// is the plain `Bool` the presence server already exposes. Never treat
/// this as a household-identity, remote-presence, membership, authority, or
/// routing signal — it answers only "is a locally-paired iPhone's WebSocket
/// open right now," nothing about the household. See `OwnerDevice.swift`'s
/// `localPairingDeviceId`, already documented there as distinct from
/// `DeviceCert.d_id`.
enum LocalPairingConnectionBadge: Equatable {
    case connected
    case notConnected

    init(hasConnectedDevices: Bool) {
        self = hasConnectedDevices ? .connected : .notConnected
    }

    var text: String {
        switch self {
        case .connected:
            String(
                localized: "prefs.devices.iphone.localPresence.connected",
                defaultValue: "Paired iPhone connected to this Mac",
                comment: "Local Devices pane badge: at least one paired iPhone's local WebSocket is currently open."
            )
        case .notConnected:
            String(
                localized: "prefs.devices.iphone.localPresence.notConnected",
                defaultValue: "No paired iPhone currently connected",
                comment: "Local Devices pane badge: no paired iPhone's local WebSocket is currently open."
            )
        }
    }
}

@MainActor
final class DevicesPreferencesViewController: NSViewController {
    private let localConnectionsLabel = NSTextField(labelWithString: "")
    private let localPresenceBadgeLabel = NSTextField(labelWithString: "")
    private let forgetHomeLabel = NSTextField(wrappingLabelWithString: "")
    private var pairingWindowController: MacIPhonePairingWindowController?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 700, height: 560))
        preferredContentSize = NSSize(width: 700, height: 560)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        refreshLocalConnectionCount()
        refreshLocalPresenceBadge()
        // PairingPresenceServer is not @Observable, so this observer stays
        // on NotificationCenter (same pattern as WorkspaceSidebarListView).
        NotificationCenter.default.addObserver(
            self, selector: #selector(presenceMembershipChanged),
            name: PairingPresenceServer.membershipDidChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLocalConnectionCount()
        refreshLocalPresenceBadge()
    }

    @objc private func presenceMembershipChanged() {
        refreshLocalPresenceBadge()
    }

    private func refreshLocalPresenceBadge() {
        let badge = LocalPairingConnectionBadge(
            hasConnectedDevices: PairingPresenceServer.shared.hasConnectedDevices
        )
        localPresenceBadgeLabel.stringValue = badge.text
        localPresenceBadgeLabel.textColor = badge == .connected ? .systemGreen : .secondaryLabelColor
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

        localPresenceBadgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(localPresenceBadgeLabel)

        // Two ways to bring another machine into this home, from the one
        // place a person looks for them. They used to live only inside the
        // Welcome flow, which a set-up Mac never sees again.
        let joinButton = NSButton(
            title: String(
                localized: "prefs.devices.joinExisting.button",
                defaultValue: "Join an existing Soyeht…",
                comment: "Button in Preferences › Devices that shows a QR for another Mac to join this home."
            ),
            target: self,
            action: #selector(joinExistingSoyeht)
        )
        joinButton.bezelStyle = .rounded
        joinButton.setAccessibilityIdentifier("prefs.devices.joinExisting")

        let addLinuxButton = NSButton(
            title: String(
                localized: "prefs.devices.addLinux.button",
                defaultValue: "Add a Linux server…",
                comment: "Button in Preferences › Devices that opens the Linux server sheet."
            ),
            target: self,
            action: #selector(addLinuxServer)
        )
        addLinuxButton.bezelStyle = .rounded
        addLinuxButton.setAccessibilityIdentifier("prefs.devices.addLinux")

        let machinesRow = NSStackView(views: [joinButton, addLinuxButton])
        machinesRow.orientation = .horizontal
        machinesRow.spacing = 8
        stack.addArrangedSubview(machinesRow)

        // Leaving a home is a separate, explicitly destructive action.
        forgetHomeLabel.font = .systemFont(ofSize: 12)
        forgetHomeLabel.textColor = .secondaryLabelColor
        forgetHomeLabel.maximumNumberOfLines = 4
        forgetHomeLabel.stringValue = String(
            localized: "prefs.devices.forgetHome.separateAction",
            defaultValue: "To connect a new iPhone, use Add iPhone. Forgetting this home removes its connection from this Mac.",
            comment: "Explains when to use Forget this home in Preferences › Devices."
        )
        stack.addArrangedSubview(forgetHomeLabel)

        let forgetHomeButton = NSButton(
            title: String(
                localized: "prefs.devices.forgetHome.button",
                defaultValue: "Forget this home…",
                comment: "Button in Preferences › Devices that forgets the household on this Mac."
            ),
            target: self,
            action: #selector(forgetThisHome)
        )
        forgetHomeButton.bezelStyle = .rounded
        forgetHomeButton.setAccessibilityIdentifier("prefs.devices.forgetHome")
        stack.addArrangedSubview(forgetHomeButton)

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
        container.layer?.borderWidth = MacSurface.Border.hairline
        container.layer?.cornerRadius = MacSurface.Radius.card

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
                // The home stays visible on the Wi-Fi for exactly as long as
                // this sheet does. `releaseLocalNetworkVisibility()` is
                // single-shot, so this and the sheet's own `viewDidDisappear`
                // close the engine window once between them, whichever fires
                // first.
                controller.releaseLocalNetworkVisibility()
                self?.pairingWindowController = nil
                self?.refreshLocalConnectionCount()
            }
        } else {
            controller.showWindow(self)
        }
    }

    /// Two buttons, and the destructive one is not the default: the alert is
    /// the last place someone can change their mind about a household this
    /// Mac cannot get back.
    @objc private func forgetThisHome() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "prefs.devices.forgetHome.alert.title",
            defaultValue: "Forget this home on this Mac?",
            comment: "Title of the confirmation alert for Forget this home."
        )
        alert.informativeText = String(
            localized: "prefs.devices.forgetHome.alert.body",
            defaultValue: "This Mac will stop belonging to the home and reopen setup, so you can name a new one and pair an iPhone as the first. Your files and terminals are untouched. Any iPhone that still has this home keeps it until it leaves from there.",
            comment: "Body of the confirmation alert for Forget this home — says exactly what it does and does not do."
        )
        alert.addButton(withTitle: String(
            localized: "prefs.devices.forgetHome.alert.confirm",
            defaultValue: "Forget This Home",
            comment: "Destructive button of the Forget this home alert."
        ))
        alert.addButton(withTitle: String(
            localized: "prefs.devices.forgetHome.alert.cancel",
            defaultValue: "Cancel",
            comment: "Cancel button of the Forget this home alert."
        ))
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            _ = await ForgetHomeService().run()
        }
    }

    @objc private func joinExistingSoyeht() {
        MacJoinExistingWindowController.shared.showWindow(nil)
    }

    @objc private func addLinuxServer() {
        MacAddLinuxServerWindowController.shared.showWindow(nil)
    }

    @objc private func manageLocalConnections() {
        PairedDevicesWindowController.shared.showWindow(nil)
    }
}

@MainActor
final class MacIPhonePairingWindowController: NSWindowController {
    private static let windowSize = NSSize(width: 440, height: 620)

    private let content: MacIPhonePairingHostingController

    init() {
        let content = MacIPhonePairingHostingController()
        self.content = content
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

    /// Tell this Mac's engine to stop being visible on the local network.
    /// Single-shot, so the sheet's completion handler and the content's own
    /// `viewDidDisappear` can both call it.
    func releaseLocalNetworkVisibility() {
        content.releaseLocalNetworkVisibility()
    }
}

@MainActor
private final class MacIPhonePairingHostingController: NSHostingController<MacIPhonePairingPreferencesView> {
    private let pairingModel: MacIPhonePairingPreferencesModel
    /// One `begin()` per appearance and at most one `end()` per `begin()`, so
    /// the engine's window is not closed out from under a second Add iPhone
    /// surface that is still open.
    private var holdsLocalNetworkVisibility = false

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

    /// "Add iPhone" is on screen, so this is one of the two situations in which
    /// the owner wants the home discoverable on the local network. Asking is
    /// non-blocking and failure is quiet: a phone on the tailnet still pairs
    /// with an engine that never answered.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !holdsLocalNetworkVisibility else { return }
        holdsLocalNetworkVisibility = true
        LocalNetworkPairingVisibility.shared.begin()
    }

    /// Covers the window being closed as well as the sheet being dismissed —
    /// both routes tear this view down.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        pairingModel.stop()
        releaseLocalNetworkVisibility()
    }

    func releaseLocalNetworkVisibility() {
        guard holdsLocalNetworkVisibility else { return }
        holdsLocalNetworkVisibility = false
        LocalNetworkPairingVisibility.shared.end()
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
    @Published var instructions: [LocalizedStringResource] = ["Preparing this Mac for iPhone pairing…"]
    @Published var homeCodeWords: [String]?
    @Published var status: IPhonePairingSheetStatus?
    @Published var pairingURI = ""
    @Published var showFallbackPairing = false
    @Published var copiedPairLink = false
    @Published var capability: OwnerApprovalCapability?
    @Published var requests: [DevicePairingReview] = []
    @Published var approvalInFlight = false

    private var didStart = false
    private var loadTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var deadline = Date.distantPast
    private var authority: PairingAuthority?
    private let baseURL = TheyOSEnvironment.bootstrapBaseURL
    private let logger = Logger(subsystem: "com.soyeht.mac", category: "pairing-approval")

    func start() {
        guard !didStart else { return }
        didStart = true
        MacPairingAdvertisement.shared.start()
        loadTask = Task { await loadPairingLink() }
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        [loadTask, listenerTask, pollTask, approvalTask, copyResetTask].forEach { $0?.cancel() }
        MacPairingAdvertisement.shared.stop()
    }

    func copyPairingLink() {
        guard !pairingURI.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingURI, forType: .string)
        copiedPairLink = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedPairLink = false
        }
    }

    private func setStatus(_ message: String, progress: Bool = false) {
        status = IPhonePairingSheetStatus(message: LocalizedStringResource(stringLiteral: message),
                                         showsProgress: progress)
    }

    private func observeCapability(_ value: OwnerApprovalCapability) {
        capability = value
        logger.info("\(value.diagnostic, privacy: .public)")
    }

    private func loadPairingLink() async {
        do {
            // The visibility request and listener bind are asynchronous. Wait for
            // an actual offer for a bounded time, never fabricate a LAN address.
            var offered: MacPairingAdvertisement.Offer?
            for _ in 0..<10 {
                try Task.checkCancellation()
                offered = await MacPairingAdvertisement.shared.currentOffer()
                if offered != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let offer = offered else { throw PairingAddressError.operationUnavailable }
            let snapshot = try await BootstrapPairingAddressesClient(baseURL: baseURL).fetch()
            let house = SetupInvitationExistingHouse(name: offer.houseName, hostLabel: offer.hostLabel,
                                                    pairDeviceURI: offer.uri)
            try SetupInvitationCeremony.requireMatchingHouse(house, authority: snapshot.authority)
            let firstOwner = try SetupInvitationCeremony.operation(for: house) == .firstOwner
            authority = snapshot.authority
            observeCapability(OwnerApprovalCapabilityChecker.local().check(authority: snapshot.authority))
            pairingURI = offer.uri
            homeCodeWords = offer.words
            deadline = min(offer.expiresAt ?? Date().addingTimeInterval(300), Date().addingTimeInterval(300))
            instructions = ["Open Soyeht on your iPhone and start looking for this Mac.",
                            "Use the same LAN or Wi-Fi, or connect both devices through Tailscale."]
            if !firstOwner {
                instructions.append(capability?.canAttemptApproval == true
                    ? "This Mac can review approval. Compare the iPhone request code before approving."
                    : "Approval requires a device holding this home's owner key. Open Soyeht on that device to review the new iPhone. Your home stays intact.")
            }
            setStatus("Waiting for iPhone…", progress: true)
            startListening(house: house, firstOwner: firstOwner)
            startPolling(firstOwner: firstOwner)
        } catch is CancellationError { return }
        catch { showFailure(error) }
    }

    private func startListening(house: SetupInvitationExistingHouse, firstOwner: Bool) {
        listenerTask?.cancel()
        listenerTask = Task {
            while !Task.isCancelled, Date() < deadline {
                let outcome = await SetupInvitationListener(engineBaseURL: baseURL, existingHouse: house).listen()
                guard !Task.isCancelled else { return }
                if case .invitationClaimed = outcome {
                    setStatus(firstOwner ? "iPhone found. Compare the home code and finish on your iPhone."
                        : "iPhone found. Start connecting on the iPhone, then review its approval request.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func startPolling(firstOwner: Bool) {
        pollTask?.cancel()
        pollTask = Task {
            do {
                while !Task.isCancelled, Date() < deadline {
                    let snapshot = try await BootstrapPairingAddressesClient(baseURL: baseURL).fetch()
                    guard snapshot.authority.householdID == authority?.householdID else {
                        throw PairingAttemptFailure(stage: .approval, endpoint: baseURL, cause: .certificate)
                    }
                    if firstOwner, snapshot.authority.ownerPersonID != nil {
                        setStatus("Owner registered. Finish setup on your iPhone.")
                        listenerTask?.cancel()
                        return
                    }
                    if !firstOwner, capability?.state == .proven, !approvalInFlight {
                        try await refreshRequests(allowInteraction: false)
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                guard !Task.isCancelled else { return }
                requests = []
                listenerTask?.cancel()
                setStatus("Pairing expired. Close this sheet and choose Add iPhone to try again.")
            } catch is CancellationError { return }
            catch { showFailure(error) }
        }
    }

    /// Called only by a visible user action. Automatic polling never prompts.
    func reviewRequests() {
        guard !approvalInFlight else { return }
        approvalInFlight = true
        approvalTask = Task {
            defer { approvalInFlight = false }
            do { try await refreshRequests(allowInteraction: true) }
            catch is CancellationError { return }
            catch { showFailure(error) }
        }
    }

    private func signingSession(allowInteraction: Bool) async throws -> (ActiveHouseholdState, any OwnerIdentitySigning) {
        let snapshot = try await BootstrapPairingAddressesClient(baseURL: baseURL).fetch()
        guard snapshot.authority == authority else {
            throw OwnerIdentityKeyError.publicKeyMismatch
        }
        guard let data = try HouseholdSessionStore.defaultStorage().loadDiagnosed(
            account: HouseholdSessionStore.activeSessionAccount, allowInteraction: allowInteraction) else {
            throw HouseholdSessionError.missingSession
        }
        let session = try JSONDecoder().decode(ActiveHouseholdState.self, from: data)
        guard session.householdId == snapshot.authority.householdID,
              session.ownerPersonId == snapshot.authority.ownerPersonID,
              session.ownerPublicKey == snapshot.authority.ownerPublicKey else {
            throw OwnerIdentityKeyError.publicKeyMismatch
        }
        let provider = SecureEnclaveOwnerIdentityKeyProvider()
        let signer = try allowInteraction
            ? provider.loadOwnerIdentity(keyReference: session.ownerKeyReference,
                publicKey: session.ownerPublicKey, personId: session.ownerPersonId)
            : provider.loadOwnerIdentityWithoutInteraction(keyReference: session.ownerKeyReference,
                publicKey: session.ownerPublicKey, personId: session.ownerPersonId)
        return (session, signer)
    }

    private func refreshRequests(allowInteraction: Bool) async throws {
        let (session, signer) = try await signingSession(allowInteraction: allowInteraction)
        let listed = try await URLSessionHouseholdDevicePairingHTTPClient()
            .listPairingRequests(endpoint: baseURL, ownerIdentity: signer)
        try Task.checkCancellation()
        if allowInteraction {
            observeCapability(.init(state: .proven, cause: "owner_request_verified"))
        }
        let previousRequests = Set(requests.map(\.id))
        requests = try listed.filter { $0.status == "pending" && TimeInterval($0.expiresAt) > Date().timeIntervalSince1970 }
            .map { try $0.review(householdPublicKey: session.householdPublicKey) }
        for review in requests where !previousRequests.contains(review.id) {
            logger.info("\(review.diagnostic, privacy: .public)")
        }
        if requests.isEmpty { setStatus("No pending request yet. Start connecting on your iPhone, then review again.") }
    }

    func approve(_ request: DevicePairingReview) {
        guard !approvalInFlight, request.expiresAt > Date(), Date() < deadline,
              requests.contains(request) else { return }
        approvalInFlight = true
        approvalTask = Task {
            defer { approvalInFlight = false }
            do {
                let (session, signer) = try await signingSession(allowInteraction: true)
                try Task.checkCancellation()
                guard request.expiresAt > Date() else { throw HouseholdDevicePairingError.approvalTimedOut }
                try await HouseholdDevicePairingService().approve(requestId: request.id,
                    devicePublicKey: request.devicePublicKey, deviceName: request.deviceName,
                    platform: request.platform, household: session, ownerIdentity: signer,
                    endpointOverride: baseURL)
                try Task.checkCancellation()
                requests.removeAll { $0.id == request.id }
                setStatus("Approval sent. Finish setup on your iPhone.")
                logger.info("pairing_approval=sent")
            } catch is CancellationError { return }
            catch { showFailure(error) }
        }
    }

    private func showFailure(_ error: Error) {
        let observed = OwnerApprovalCapability.failure(error)
        if error is OwnerIdentityKeyError || observed.state == .needsAuthentication {
            observeCapability(observed)
        }
        let failure = PairingAttemptFailure.capture(error, stage: .approval, endpoint: baseURL)
        logger.error("\(failure.diagnostic, privacy: .public)")
        setStatus(observed.state == .needsAuthentication
            ? "Review on this Mac requires unlocking the owner key. Choose Review requests to continue."
            : failure.userMessage)
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
            approvalContent: AnyView(approvalContent),
            closeAction: closeAction
        )
        .task { model.start() }
    }

    @ViewBuilder private var approvalContent: some View {
        if model.capability?.canAttemptApproval == true {
            Button(model.capability?.state == .needsAuthentication
                   ? "Review requests on this Mac — unlock required" : "Review requests on this Mac") {
                model.reviewRequests()
            }
            .disabled(model.approvalInFlight)
            .accessibilityIdentifier("prefs.devices.pairing.reviewRequests")
        }
        ForEach(model.requests) { request in
            VStack(spacing: 8) {
                Text(request.deviceName).font(.headline)
                Text(request.words.joined(separator: " · ")).font(.system(.body, design: .monospaced))
                Text("Approve only if these request words match the words on your iPhone.")
                Button("The words match — approve this iPhone") { model.approve(request) }
                    .disabled(model.approvalInFlight || request.expiresAt <= Date())
                    .accessibilityIdentifier("prefs.devices.pairing.approveRequest")
            }
        }
    }
}

// MARK: - Sheets reached from Preferences › Devices

/// "Join an existing Soyeht…" — this Mac asking to be let into a home that
/// already exists somewhere else.
///
/// It used to live only inside the Welcome flow, on a fork a Mac sees exactly
/// once and never again. A second Mac bought a month later had no way in at
/// all. The screen itself is unchanged; only where it is reached from.
@MainActor
final class MacJoinExistingWindowController: NSWindowController {
    static let shared = MacJoinExistingWindowController()

    private static let windowSize = NSSize(width: 460, height: 620)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "prefs.devices.joinExisting.window.title",
            defaultValue: "Join an existing Soyeht",
            comment: "Title of the window that shows this Mac's join QR."
        )
        // The root is pinned to the window size. A SwiftUI root free to pick
        // its own size makes AppKit resize the window from constraints while
        // it is already laying out — measured as an NSGenericException from
        // `_postWindowNeedsUpdateConstraints`, which aborts the app.
        let content = NSHostingController(
            rootView: MacJoinExistingGate()
                .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
        )
        window.contentViewController = content
        content.preferredContentSize = Self.windowSize
        content.view.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.setContentSize(Self.windowSize)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use shared") }
}

/// The gate, as a screen rather than a hidden button.
///
/// Two things can stop this Mac from joining, and they need different
/// sentences. Both need the engine's state, which means a request — so gating
/// the *button* would make it appear a beat after the pane. A person who
/// cannot use this deserves the reason and the way out of it, not a control
/// that was never there.
private struct MacJoinExistingGate: View {
    enum Readiness: Equatable {
        case ready
        case engineTooOld
        /// This Mac is already in a home, so it has nothing to join with.
        /// The pane behind this window is where that is undone.
        case alreadyInAHome
        case engineUnreachable
    }

    @State private var readiness: Readiness?

    var body: some View {
        // `SwiftUI.Group` spelled out: this file imports SoyehtCore, which has
        // a `Group` of its own, and the bare name resolves to that one.
        SwiftUI.Group {
            switch readiness {
            case .none:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                JoinExistingSoyehtView(onPaired: dismiss, onBack: dismiss)
            case .alreadyInAHome:
                message(
                    title: LocalizedStringResource(
                        "prefs.devices.joinExisting.alreadyInAHome.title",
                        defaultValue: "This Mac already belongs to a home",
                        comment: "Shown when a Mac that is already set up opens Join an existing Soyeht."
                    ),
                    body: LocalizedStringResource(
                        "prefs.devices.joinExisting.alreadyInAHome.body",
                        defaultValue: "A Mac can only be in one home at a time. Close this and choose Forget this home first.",
                        comment: "Names the one action that makes joining possible."
                    )
                )
            case .engineTooOld:
                message(
                    title: LocalizedStringResource(
                        "prefs.devices.joinExisting.tooOld.title",
                        defaultValue: "This Mac's engine is too old to join a home",
                        comment: "Shown when the local engine predates machine joining."
                    ),
                    body: LocalizedStringResource(
                        "prefs.devices.joinExisting.tooOld.body",
                        defaultValue: "Update Soyeht on this Mac and open this again.",
                        comment: "What fixes an engine too old to join a home."
                    )
                )
            case .engineUnreachable:
                message(
                    title: LocalizedStringResource(
                        "prefs.devices.joinExisting.unreachable.title",
                        defaultValue: "This Mac's engine isn't answering",
                        comment: "Shown when the local engine cannot be reached at all."
                    ),
                    body: LocalizedStringResource(
                        "prefs.devices.joinExisting.unreachable.body",
                        defaultValue: "Give it a moment and open this again.",
                        comment: "What to do when the local engine is not answering yet."
                    )
                )
            }
        }
        .task {
            guard readiness == nil else { return }
            readiness = await Self.resolve()
        }
    }

    private func message(title: LocalizedStringResource, body: LocalizedStringResource) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(
                localized: "prefs.devices.joinExisting.close",
                defaultValue: "Close",
                comment: "Closes the Join an existing Soyeht window from one of its dead ends."
            )) { dismiss() }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func resolve(
        fetch: () async throws -> BootstrapStatusResponse = {
            try await BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL).fetch()
        }
    ) async -> Readiness {
        guard let status = try? await fetch() else { return .engineUnreachable }
        guard JoinExistingCapability.isAvailable(status: status) else { return .engineTooOld }
        switch status.state {
        case .uninitialized, .readyForNaming:
            return .ready
        default:
            return .alreadyInAHome
        }
    }

    private func dismiss() {
        MacJoinExistingWindowController.shared.close()
    }
}

/// "Add a Linux server…" — the same sheet the house card offers during setup,
/// reachable after setup is over.
@MainActor
final class MacAddLinuxServerWindowController: NSWindowController {
    static let shared = MacAddLinuxServerWindowController()

    /// Matches the sheet's own `.frame(width: 520)`. Anything narrower
    /// centre-crops it and the title runs off both edges.
    private static let windowSize = NSSize(width: 520, height: 340)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "prefs.devices.addLinux.window.title",
            defaultValue: "Add a Linux server",
            comment: "Title of the Add Linux server window opened from Preferences."
        )
        // Same pinning as the join window: this view was written as a sheet,
        // sized by whatever presented it, and left to size a window itself it
        // crashes AppKit's layout pass.
        let content = NSHostingController(
            rootView: AddLinuxServerSheet(
                onConnected: { MacAddLinuxServerWindowController.shared.close() },
                onCancel: { MacAddLinuxServerWindowController.shared.close() }
            )
            .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
        )
        window.contentViewController = content
        content.preferredContentSize = Self.windowSize
        content.view.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.setContentSize(Self.windowSize)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use shared") }
}
