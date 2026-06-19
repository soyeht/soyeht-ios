import Foundation

// MARK: - Server (unified entity)
//
// `Server` is the canonical iPhone-side representation of a paired host
// in the household, whether the host is a Mac (running theyOS via the
// embedded engine in Soyeht.app) or a Linux box (running theyOS via the
// admin-host stack behind Tailscale Serve).
//
// Today the iOS app carries TWO parallel registries describing the same
// logical Mac:
//
//   - `PairedMac` in `TerminalApp/.../Pairing/PairedMacsStore.swift`
//     (UserDefaults `com.soyeht.mobile.pairedMacs` + Keychain
//     `pairing_secret.{macID}`). Created by the household pair flow.
//   - `PairedServer(kind: .engine)` in `Store/SessionStore.swift`
//     (UserDefaults). Created by the legacy QR/auth path in
//     `SoyehtAPIClient.swift:419`.
//
// Linux paired hosts live exclusively as `PairedServer(kind: .adminHost)`.
//
// `Server` is the destination of a planned migration that collapses both
// stores into one. The Codable shape preserves backward compatibility
// with legacy `PairedServer` raw values (`"engine"` / `"adminHost"`) via
// `Server.Kind.init(from:)`, so the migrator can ingest existing user
// data without modifying or deleting the legacy stores.
//
// See `docs/server-model.md` (Phase 6) for the rendering contract:
// every UI surface reads `server.displayName`; every mutation goes
// through `ServerRegistry.setAlias / addServer / removeServer /
// updateTheyOSStatus`; status is consumed via `server.theyOS.status`.
public struct Server: Codable, Identifiable, Equatable, Sendable, Hashable {
    /// Stable identifier. UUID-as-String for Macs (legacy `PairedMac.macID`),
    /// arbitrary String for QR-paired Linux hosts (legacy `PairedServer.id`).
    public let id: String

    public let kind: Kind

    public let pairedAt: Date

    public var lastSeenAt: Date

    /// User-typed display name (validated by `MacAliasValidator`). `nil`
    /// means the user has not chosen one yet — UI shows the hostname
    /// fallback. UI MUST read `displayName`, not `alias`.
    public var alias: String?

    /// Engine-supplied hostname (e.g. `"machine-alpha"` from the Mac engine
    /// at pair time, `host` field from `PairedServer` for Linux). Stable
    /// fallback when the user has not chosen an alias yet.
    public var hostname: String

    /// Routing host used by the active terminal session (`PairedMac.lastHost`
    /// for Macs, `PairedServer.host` for Linux). May change between
    /// sessions when DHCP or Tailscale magic-DNS shifts.
    public var lastHost: String?

    /// Engine-issued stable machine identifier. `nil` for legacy data and
    /// until the engine starts populating it.
    public var engineMachineId: String?

    /// Latest known status of the theyOS engine running on this server.
    /// Updated by `TheyOSStatusPoller` (Phase 5).
    public var theyOS: TheyOSSnapshot

    /// Optional Linux Tailscale Serve HTTPS endpoint or other override
    /// for `/api/v1/*` calls when it differs from `lastHost`.
    public var apiEndpoint: URL?

    /// Override for `/bootstrap/*` calls. Defaults to `lastHost:8091` when
    /// `nil`. Separated from `apiEndpoint` because Linux can route the
    /// admin API through Tailscale Serve while the household listener
    /// stays on the local network at port 8091.
    public var bootstrapEndpoint: URL?

    // ── Mac-only (nil on Linux) ────────────────────────────────────────

    /// Local presence WebSocket port on the Mac (from `PairedMac.presencePort`).
    public var presencePort: Int?

    /// Local attach WebSocket port on the Mac (from `PairedMac.attachPort`).
    public var attachPort: Int?

    // ── Linux-only (nil on Mac) ────────────────────────────────────────

    /// Server-side role (e.g. `"admin"`) carried by legacy `PairedServer.role`.
    public let role: String?

    /// Optional JWT-style expiry hint carried by legacy
    /// `PairedServer.expiresAt`. Format is server-defined.
    public let sessionExpiresAt: String?

    // ── Computed display ───────────────────────────────────────────────

    /// CANONICAL user-facing label. Prefers `alias` (user-typed) over
    /// `hostname` (engine-supplied). Every SwiftUI view that shows a
    /// server MUST read this — never `alias` or `hostname` directly.
    public var displayName: String {
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty {
            return alias
        }
        return hostname
    }

    /// Whether the user still owes us a name for this server. Pairing
    /// flows route to the alias-naming UI whenever this is true. Linux
    /// servers paired via the legacy QR flow inherit a non-empty
    /// `name`/`hostname` so they usually start with `needsAlias == false`
    /// unless the user explicitly clears the alias.
    public var needsAlias: Bool {
        alias?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
    }

    // ── Init ───────────────────────────────────────────────────────────

    public init(
        id: String,
        kind: Kind,
        pairedAt: Date,
        lastSeenAt: Date,
        alias: String? = nil,
        hostname: String,
        lastHost: String? = nil,
        engineMachineId: String? = nil,
        theyOS: TheyOSSnapshot = TheyOSSnapshot(),
        apiEndpoint: URL? = nil,
        bootstrapEndpoint: URL? = nil,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        role: String? = nil,
        sessionExpiresAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.alias = alias
        self.hostname = hostname
        self.lastHost = lastHost
        self.engineMachineId = engineMachineId
        self.theyOS = theyOS
        self.apiEndpoint = apiEndpoint
        self.bootstrapEndpoint = bootstrapEndpoint
        self.presencePort = presencePort
        self.attachPort = attachPort
        self.role = role
        self.sessionExpiresAt = sessionExpiresAt
    }
}

// MARK: - Server.Kind

extension Server {
    /// Server kind. New code uses `.mac` / `.linux`. The decoder also
    /// accepts the legacy `PairedServer.ServerKind` raw values
    /// (`"engine"` ≡ `.mac`, `"adminHost"` ≡ `.linux`) so existing
    /// `PairedServer` data migrates cleanly without rewriting raw
    /// values in legacy storage.
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case mac
        case linux

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "mac", "engine":
                self = .mac
            case "linux", "adminHost":
                self = .linux
            default:
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown Server.Kind raw value: \(raw)"
                )
            }
        }
    }
}

// MARK: - TheyOSSnapshot

/// Last-known state of the theyOS engine on a `Server`. Updated by
/// `TheyOSStatusPoller` whenever it sees a fresh `/bootstrap/status`
/// response.
public struct TheyOSSnapshot: Codable, Equatable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, CaseIterable, Hashable {
        /// No poll has completed yet, or the cache was just cleared.
        case unknown
        /// `/bootstrap/status` returned `200` with a usable response.
        case running
        /// Engine answered but reports `BootstrapState.uninitialized`
        /// (binary present but not yet set up for household use).
        case uninitialized
        /// Last poll failed (network drop, timeout, 5xx, etc.).
        case unreachable
    }

    public var status: Status
    public var version: String?
    public var lastCheckedAt: Date

    public init(
        status: Status = .unknown,
        version: String? = nil,
        lastCheckedAt: Date = .distantPast
    ) {
        self.status = status
        self.version = version
        self.lastCheckedAt = lastCheckedAt
    }
}
