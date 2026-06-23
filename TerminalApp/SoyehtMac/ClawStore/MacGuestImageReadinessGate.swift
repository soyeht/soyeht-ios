import Combine
import Foundation
import SoyehtCore

/// macOS-native guest-image readiness gate for the Mac Claw Store (P6 / part A).
///
/// Consumes the SHARED SoyehtCore readiness model (`GuestImageReadiness`,
/// `BootstrapStatusClient`, `BootstrapStatusEndpoint`) — it does NOT reuse or
/// move the iOS `GuestImageReadinessObserver`. It mirrors the iOS install-gating
/// semantics: install is allowed only when the engine reports `.ready` or has no
/// guest-VM concept (`.notApplicable`); every other state gates install.
///
/// P6B adds a reason-coded recovery banner + a read-only "Check Again" re-fetch
/// (`recheck()`); the mutating prepare retry remains a follow-up. The state is
/// local to the Claw Store UI and is not persisted into `ServerRegistry`.
enum MacGuestImageGateState: Equatable, Sendable {
    /// Fetching `/bootstrap/status` for the first time. Install gated.
    case checking
    /// Engine reports a state that allows install (`.ready` or `.notApplicable`).
    case allowed(GuestImageReadiness)
    /// Engine reports a not-ready state (`.notStarted` / `.inProgress` / `.failed`).
    case blocked(GuestImageReadiness)
    /// No reachable bootstrap endpoint, or the status fetch failed. Install gated.
    case unavailable

    /// Single-shot predicate the Claw Store install CTA consults — true ONLY for
    /// `.allowed`.
    var allowsInstall: Bool {
        if case .allowed = self { return true }
        return false
    }

    var readiness: GuestImageReadiness? {
        switch self {
        case .allowed(let readiness), .blocked(let readiness):
            return readiness
        case .checking, .unavailable:
            return nil
        }
    }

    /// Map a shared `GuestImageReadiness` onto the gate's allow/block buckets.
    static func from(_ readiness: GuestImageReadiness) -> MacGuestImageGateState {
        readiness.allowsInstall ? .allowed(readiness) : .blocked(readiness)
    }

    var needsFetch: Bool {
        switch self {
        case .checking, .blocked:
            return true
        case .allowed, .unavailable:
            return false
        }
    }
}

/// Observable readiness model the macOS Claw Store view binds to.
@MainActor
final class MacGuestImageReadinessModel: ObservableObject {
    typealias FetchStatus = @Sendable (URL) async throws -> BootstrapStatusResponse

    @Published private(set) var state: MacGuestImageGateState
    /// True while a `recheck()` ("Check Again") re-fetch is in flight, so the CTA
    /// can be disabled.
    @Published private(set) var isRechecking = false

    private let server: PairedServer
    private let fetchStatus: FetchStatus

    init(
        server: PairedServer,
        fetchStatus: @escaping FetchStatus = { url in
            try await BootstrapStatusClient(baseURL: url).fetch()
        }
    ) {
        self.server = server
        self.fetchStatus = fetchStatus
        self.state = Self.initialState(for: server)
    }

    /// Initial gate before any fetch:
    ///  - admin hosts have no engine / guest VM → `.allowed(.notApplicable)`;
    ///  - Linux engines have no guest VM → `.allowed(.notApplicable)`;
    ///  - a Mac / unknown-platform engine with a resolvable endpoint → `.checking`;
    ///  - no resolvable endpoint → `.unavailable`.
    static func initialState(for server: PairedServer) -> MacGuestImageGateState {
        if server.kind == .adminHost {
            return .allowed(.notApplicable)
        }
        if server.normalizedPlatform == "linux" {
            return .allowed(.notApplicable)
        }
        return bootstrapBaseURL(for: server) == nil ? .unavailable : .checking
    }

    /// The RAW engine `/bootstrap` base URL via the shared resolver — never the
    /// authenticated household API / 443 proxy. `nil` when the host is empty or
    /// unresolvable.
    static func bootstrapBaseURL(for server: PairedServer) -> URL? {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return BootstrapStatusEndpoint.baseURL(forHost: host)
    }

    /// Fetch `/bootstrap/status` once and update `state` via the shared
    /// `guestImageReadiness` mapping (which itself disambiguates Linux vs Mac).
    /// A missing endpoint or a failed fetch is FAIL-CLOSED → `.unavailable`
    /// (install gated). No-op when the current state doesn't need a fetch.
    func refresh() async {
        guard state.needsFetch else { return }
        guard let url = Self.bootstrapBaseURL(for: server) else {
            state = .unavailable
            return
        }
        do {
            let status = try await fetchStatus(url)
            state = .from(status.guestImageReadiness)
        } catch {
            state = .unavailable
        }
    }

    /// Force a one-shot readiness re-fetch — the P6B "Check Again" CTA. Unlike
    /// `refresh()` (the poll step), it re-fetches from ANY state, including
    /// `.unavailable` and a terminal `.blocked(.failed)`, so the user can re-check
    /// after acting on the Mac. Read-only (never triggers a prepare). Still
    /// fail-closed: a missing endpoint or failed fetch yields `.unavailable`.
    func recheck() async {
        isRechecking = true
        defer { isRechecking = false }
        guard let url = Self.bootstrapBaseURL(for: server) else {
            state = .unavailable
            return
        }
        do {
            let status = try await fetchStatus(url)
            state = .from(status.guestImageReadiness)
        } catch {
            state = .unavailable
        }
    }
}
