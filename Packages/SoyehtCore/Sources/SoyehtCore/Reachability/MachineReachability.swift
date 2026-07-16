import Foundation

/// The only public entry point for resolving a route to a known machine.
///
/// `machineID` is always derived from a validated machine public key; callers
/// must never use a host name, URL, server identifier, or display label as a
/// machine identity.
public protocol MachineReachabilityProviding: Sendable {
    func candidates(
        machineID: MachineID,
        purpose: MachineReachabilityPurpose
    ) async -> MachineReachabilityResolution
}

/// Canonical identity of a machine certificate subject.
///
/// Production inputs must come from the owner-authenticated
/// `GET /api/v1/household/machines` contract. This type deliberately has no
/// raw-string initializer: its `m_` identifier is always derived from the
/// validated compressed P-256 public key it retains.
public struct MachineID: Hashable, Sendable {
    public let rawValue: String
    public let machinePublicKey: Data

    public init(authenticatedMachinePublicKey: Data) throws {
        try HouseholdIdentifiers.validateCompressedP256PublicKey(authenticatedMachinePublicKey)
        self.machinePublicKey = authenticatedMachinePublicKey
        self.rawValue = try HouseholdIdentifiers.identifier(
            for: authenticatedMachinePublicKey,
            kind: .machine
        )
    }
}

/// A self-machine authority binding decoded from the owner-authenticated R101
/// `/machines` response.
///
/// Slice 1 models and validates this binding but intentionally does not add a
/// network client or persistence. A later R101 reader is the only permitted
/// producer of production bindings: it must select the machine record whose
/// `machine_id` matches the response's `self_m_id`, then pass that record's
/// public key here. A household member record alone is never authority.
public struct MachineReachabilityAuthority: Equatable, Sendable {
    public let householdID: String
    public let selfMachineID: MachineID

    public init(
        householdID: String,
        reportedSelfMachineID: String,
        authenticatedSelfMachinePublicKey: Data
    ) throws {
        guard !householdID.isEmpty else {
            throw MachineReachabilityAuthorityError.emptyHouseholdID
        }

        let selfMachineID = try MachineID(
            authenticatedMachinePublicKey: authenticatedSelfMachinePublicKey
        )
        guard selfMachineID.rawValue == reportedSelfMachineID else {
            throw MachineReachabilityAuthorityError.selfMachineIdentifierMismatch
        }

        self.householdID = householdID
        self.selfMachineID = selfMachineID
    }
}

public enum MachineReachabilityAuthorityError: Error, Equatable, Sendable {
    case emptyHouseholdID
    case selfMachineIdentifierMismatch
}

/// The operation that needs a route. New purposes are deliberate contract
/// additions; the enum is intentionally not `@frozen`.
public enum MachineReachabilityPurpose: String, CaseIterable, Codable, Sendable, Hashable {
    case presence
    case attach
    case apnsDispatch
    case devicePairing
    case joinStaging
    case clawInstall
    case identitySnapshot
}

/// A route already scoped to one authenticated machine and one purpose.
public struct MachineReachabilityCandidate: Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        /// Temporary compatibility seed. It proves neither a route nor an
        /// authority binding; the actor requires the latter separately.
        case legacyStoredEndpoint
    }

    public let machineID: MachineID
    public let baseURL: URL
    public let source: Source

    public init(
        machineID: MachineID,
        baseURL: URL,
        source: Source
    ) {
        self.machineID = machineID
        self.baseURL = baseURL
        self.source = source
    }
}

/// A resolution never uses an optional URL or an empty candidate list.
public enum MachineReachabilityResolution: Equatable, Sendable {
    case candidates(
        primary: MachineReachabilityCandidate,
        fallbacks: [MachineReachabilityCandidate]
    )
    case unavailable(MachineReachabilityUnavailableReason)
    case unresolved(MachineReachabilityUnresolvedReason)
}

/// A trusted route source could not be read or used at this time.
public enum MachineReachabilityUnavailableReason: String, Equatable, Sendable {
    case legacyStateReadFailed
}

/// The seam lacks the trusted identity or state required to form a route.
public enum MachineReachabilityUnresolvedReason: String, Equatable, Sendable {
    case missingAuthenticatedAuthorityBinding
    case requestedMachineIsNotAuthenticatedAuthority
    case noActiveHouseholdState
    case authorityHouseholdMismatch
}

/// Serializes reachability resolution while future verified strategies are
/// added behind this one boundary.
///
/// Slice 1 deliberately installs only `LegacyStoredEndpointStrategy`. It
/// leaves every existing consumer untouched and does not rank, normalize,
/// probe, or synthesize endpoints.
public actor MachineReachability: MachineReachabilityProviding {
    private let authority: MachineReachabilityAuthority?
    private let legacyStoredEndpointStrategy: LegacyStoredEndpointStrategy

    public init(
        authority: MachineReachabilityAuthority?,
        sessionStore: HouseholdSessionStore = HouseholdSessionStore()
    ) {
        self.authority = authority
        self.legacyStoredEndpointStrategy = LegacyStoredEndpointStrategy(
            sessionStore: sessionStore
        )
    }

    public func candidates(
        machineID: MachineID,
        purpose: MachineReachabilityPurpose
    ) async -> MachineReachabilityResolution {
        guard let authority else {
            return .unresolved(.missingAuthenticatedAuthorityBinding)
        }

        guard machineID == authority.selfMachineID else {
            return .unresolved(.requestedMachineIsNotAuthenticatedAuthority)
        }

        return legacyStoredEndpointStrategy.candidates(
            authority: authority,
            requestedMachineID: machineID,
            purpose: purpose
        )
    }
}

/// The one sanctioned compatibility reader of `ActiveHouseholdState.endpoint`.
///
/// It exists so every current raw reader can migrate toward a single seam. It
/// returns the serialized URL exactly as stored, and must disappear with the
/// legacy seed once all consumers have migrated. Slice 1 deliberately does
/// not assign purpose-specific policy to this compatibility seed; that policy
/// is introduced only alongside a consumer migration and its behavior matrix.
struct LegacyStoredEndpointStrategy {
    private let sessionStore: HouseholdSessionStore

    init(sessionStore: HouseholdSessionStore) {
        self.sessionStore = sessionStore
    }

    func candidates(
        authority: MachineReachabilityAuthority,
        requestedMachineID: MachineID,
        purpose _: MachineReachabilityPurpose
    ) -> MachineReachabilityResolution {
        guard requestedMachineID == authority.selfMachineID else {
            return .unresolved(.requestedMachineIsNotAuthenticatedAuthority)
        }

        let seed: LegacyStoredEndpointSeed
        do {
            seed = try legacySeed()
        } catch LegacySeedBootstrapError.noActiveHouseholdState {
            return .unresolved(.noActiveHouseholdState)
        } catch LegacySeedBootstrapError.legacyStateReadFailed {
            return .unavailable(.legacyStateReadFailed)
        } catch {
            return .unavailable(.legacyStateReadFailed)
        }

        guard seed.householdID == authority.householdID else {
            return .unresolved(.authorityHouseholdMismatch)
        }

        return .candidates(
            primary: MachineReachabilityCandidate(
                machineID: requestedMachineID,
                baseURL: seed.baseURL,
                source: .legacyStoredEndpoint
            ),
            fallbacks: []
        )
    }

    /// Bootstrap-only access to the serialized compatibility seed.
    ///
    /// `GET /api/v1/household/machines` is the one request that must happen
    /// before a machine-scoped authority exists: its owner-PoP response
    /// provides the `self_m_id + machine_pub` binding that creates that
    /// authority. This method is deliberately not a candidate or a reachability
    /// result. It is consumed only by `MachineReachabilityAuthorityBootstrapper`
    /// and must disappear alongside the seed after the authority binding has a
    /// durable verified source.
    func authorityBootstrapContext() throws -> LegacySeedBootstrapContext {
        let seed = try legacySeed()
        return LegacySeedBootstrapContext(
            householdID: seed.householdID,
            baseURL: seed.baseURL
        )
    }

    /// Keeps the serialized endpoint read physically unique. Both ordinary
    /// post-authority resolution and the one-time R101 authority bootstrap
    /// consume this result, so the Phase 2 source-slice ratchet remains at its
    /// single sanctioned legacy reader.
    private func legacySeed() throws -> LegacyStoredEndpointSeed {
        let state: ActiveHouseholdState
        do {
            guard let loadedState = try sessionStore.load() else {
                throw LegacySeedBootstrapError.noActiveHouseholdState
            }
            state = loadedState
        } catch let error as LegacySeedBootstrapError {
            throw error
        } catch {
            throw LegacySeedBootstrapError.legacyStateReadFailed
        }
        return LegacyStoredEndpointSeed(
            householdID: state.householdId,
            baseURL: state.endpoint
        )
    }
}

/// A legacy household control-plane seed used only before `/machines` has
/// produced a machine authority binding. It is not a route candidate.
struct LegacySeedBootstrapContext: Equatable, Sendable {
    let householdID: String
    let baseURL: URL
}

private struct LegacyStoredEndpointSeed {
    let householdID: String
    let baseURL: URL
}

enum LegacySeedBootstrapError: Error, Equatable, Sendable {
    case noActiveHouseholdState
    case legacyStateReadFailed
}
