import Combine
import Foundation
import SoyehtCore
import os

private let homeLogger = Logger(subsystem: "com.soyeht.mobile", category: "home-neo")

/// What the neo home shows: the house, its Mac, and the sessions running on
/// it.
///
/// The home reads three sources and owns none of them:
///
///   - `SoyehtIdentity.shared` for the house name,
///   - `ServerRegistry.shared.operationalMacs` for which Macs exist,
///   - `PairedMacRegistry.shared.client(for:)` for each Mac's live status and
///     pane list.
///
/// It republishes them as one value so the view never reaches across three
/// observable objects mid-body. Everything else the phone can reach — Linux
/// servers, base machines, apps — stays behind "Other machines", which is the
/// old instance list unchanged.
@MainActor
final class HomeViewModel: ObservableObject {

    /// The Mac's connection as the home says it, not as the socket says it.
    /// `.idle` and `.offline` are the same sentence to the user: the Mac is
    /// not there right now.
    enum MacStatus: Equatable {
        case online
        case connecting
        case offline
    }

    struct MacRow: Equatable, Identifiable {
        let id: UUID
        let name: String
        let status: MacStatus
        let panes: [PaneEntry]

        var isOnline: Bool { status == .online }
    }

    // MARK: - Published state

    @Published private(set) var houseName: String = ""
    @Published private(set) var mac: MacRow?
    @Published private(set) var otherMachineCount: Int = 0
    /// True while an `open_pane` request is in flight. The pill is disabled
    /// for its duration so a double tap cannot open two shells.
    @Published private(set) var isOpeningSession = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let identity: SoyehtIdentity
    private let servers: ServerRegistry
    private let macs: PairedMacRegistry
    private var cancellables: Set<AnyCancellable> = []
    private var clientCancellables: [UUID: AnyCancellable] = [:]

    init(
        identity: SoyehtIdentity = .shared,
        servers: ServerRegistry = .shared,
        macs: PairedMacRegistry = .shared
    ) {
        self.identity = identity
        self.servers = servers
        self.macs = macs

        // Three sources, one refresh. `objectWillChange` fires before the
        // value lands, so the refresh is hopped to the next turn of the run
        // loop — otherwise `operationalMacs` would still read the old array.
        for publisher in [
            identity.objectWillChange.eraseToAnyPublisher(),
            servers.objectWillChange.eraseToAnyPublisher(),
            macs.objectWillChange.eraseToAnyPublisher()
        ] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }
        refresh()
    }

    // MARK: - Reading

    func refresh() {
        houseName = identity.active?.displayName ?? ""

        let operational = servers.operationalMacs
        let primary = operational.first
        otherMachineCount = max(0, servers.operationalServers.count - (primary == nil ? 0 : 1))

        guard let primary, let macID = UUID(uuidString: primary.id) else {
            mac = nil
            clientCancellables.removeAll()
            return
        }

        let client = macs.client(for: macID)
        observe(client, id: macID)

        // CANONICAL name: `Server.displayName` (alias first, hostname
        // second). The presence stream's own `displayName` is the current
        // hostname, so it is only a fallback for a row that has not landed
        // its hostname yet.
        var name = primary.displayName
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = client?.displayName ?? ""
        }

        mac = MacRow(
            id: macID,
            name: name,
            status: Self.status(of: client),
            panes: (client?.panes ?? []).filter { $0.isLive }
        )
    }

    private static func status(of client: MacPresenceClient?) -> MacStatus {
        guard let client else { return .offline }
        switch client.status {
        case .authenticated: return .online
        case .connecting:    return .connecting
        case .offline, .idle: return .offline
        }
    }

    private func observe(_ client: MacPresenceClient?, id: UUID) {
        guard let client else {
            clientCancellables[id] = nil
            return
        }
        guard clientCancellables[id] == nil else { return }
        clientCancellables[id] = client.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    // MARK: - New session

    /// Asks the Mac to open a shell pane and hands back a row the caller can
    /// attach to. Returns `nil` when the Mac refused or is not reachable —
    /// the message is already in `errorMessage` by then.
    func openNewSession() async -> PaneEntry? {
        guard let mac, mac.isOnline, let client = macs.client(for: mac.id) else {
            errorMessage = String(
                localized: "home.newSession.offline",
                defaultValue: "Open Soyeht on your Mac first.",
                comment: "Shown when New session is tapped while the paired Mac is not connected."
            )
            return nil
        }
        guard !isOpeningSession else { return nil }

        isOpeningSession = true
        defer { isOpeningSession = false }

        do {
            let paneID = try await client.requestOpenPane()
            homeLogger.info("open_pane accepted by the Mac")
            // The Mac answers with the id before the `panes_delta` arrives.
            // Prefer the pushed row when it is already there so the terminal
            // gets the Mac's own title; otherwise attach on the id alone.
            if let pushed = client.panes.first(where: { $0.id == paneID }) {
                return pushed
            }
            return PaneEntry(
                id: paneID,
                title: String(
                    localized: "home.session.shell",
                    defaultValue: "Shell",
                    comment: "Title of a plain shell session opened from the phone."
                ),
                agent: PaneWireAgent.shell,
                status: PaneWireStatus.active,
                createdAt: nil
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
