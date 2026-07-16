import Foundation

/// The one-time bridge from the legacy household control-plane seed to an
/// authenticated machine authority.
///
/// It is intentionally separate from `MachineReachability.candidates`: before
/// this operation succeeds there is no authenticated machine identity to ask
/// that actor about. It reuses `LegacyStoredEndpointStrategy`'s single stored
/// endpoint read, signs only `GET /api/v1/household/machines` with owner PoP,
/// and returns the validated authority supplied by that response. All later
/// machine operations must use `MachineReachabilityProviding.candidates`.
public struct MachineReachabilityAuthorityBootstrapper {
    private let sessionStore: HouseholdSessionStore
    private let transport: HouseholdMachinesClient.TransportPerform

    public init(
        sessionStore: HouseholdSessionStore = HouseholdSessionStore(),
        transport: @escaping HouseholdMachinesClient.TransportPerform = { request in
            try await BootstrapInitializeClient.defaultSession.data(for: request)
        }
    ) {
        self.sessionStore = sessionStore
        self.transport = transport
    }

    /// Fetches and validates the owner-authenticated inventory using the one
    /// bootstrap-only legacy seed. The returned snapshot contains the strict
    /// `MachineReachabilityAuthority` for the engine response's self machine.
    public func bootstrap(
        popSigner: HouseholdPoPSigner
    ) async throws -> HouseholdMachinesSnapshot {
        let context: LegacySeedBootstrapContext
        do {
            context = try LegacyStoredEndpointStrategy(
                sessionStore: sessionStore
            ).authorityBootstrapContext()
        } catch LegacySeedBootstrapError.noActiveHouseholdState {
            throw MachineReachabilityAuthorityBootstrapError.noActiveHouseholdState
        } catch LegacySeedBootstrapError.legacyStateReadFailed {
            throw MachineReachabilityAuthorityBootstrapError.legacyStateReadFailed
        }

        let client = HouseholdMachinesClient(
            baseURL: context.baseURL,
            expectedHouseholdID: context.householdID,
            popSigner: popSigner,
            transport: transport
        )
        return try await client.fetch()
    }
}

public enum MachineReachabilityAuthorityBootstrapError: Error, Equatable, Sendable {
    case noActiveHouseholdState
    case legacyStateReadFailed
}
