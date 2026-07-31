import Foundation
import SoyehtCore

/// Builds the roster activator for a single activation.
///
/// **Endpoint discipline.** This type never reads `ActiveHouseholdState.endpoint`.
/// The base URL comes only from `MachineReachability`, which performs the one
/// sanctioned stored-endpoint read inside `SoyehtCore`. That is what keeps the
/// iOS app free of new raw endpoint readers without an allowlist entry.
///
/// **Honest scope note.** `MachineReachability` today installs only
/// `LegacyStoredEndpointStrategy`, so the resolved candidate's `baseURL` is
/// still the serialized household endpoint — routed through the sanctioned seam
/// rather than duplicated here. This slice removes the app-side read; it does
/// NOT make the roster independent of the legacy seed. Retiring that seed needs
/// a verified route strategy in Core and is deliberately out of scope.
///
/// Every failure resolves to `nil`. A missing activator means the roster step is
/// skipped and `rosterState` stays `.unknown` — never a synthesized URL, never a
/// thrown error that could reach the activation's failure path.
struct RosterActivationProvider: Sendable {
    /// Owner-PoP `GET /api/v1/household/machines`. The response is the only
    /// producer of an authenticated machine authority.
    typealias AuthorityBootstrap = @Sendable (HouseholdPoPSigner) async throws -> HouseholdMachinesSnapshot
    /// Route resolution for one authenticated machine and one purpose.
    typealias ResolveCandidates = @Sendable (
        MachineReachabilityAuthority, MachineID
    ) async -> MachineReachabilityResolution

    private let bootstrapAuthority: AuthorityBootstrap
    private let resolveCandidates: ResolveCandidates

    init(
        bootstrapAuthority: @escaping AuthorityBootstrap = { popSigner in
            try await MachineReachabilityAuthorityBootstrapper().bootstrap(popSigner: popSigner)
        },
        resolveCandidates: @escaping ResolveCandidates = { authority, machineID in
            await MachineReachability(authority: authority)
                .candidates(machineID: machineID, purpose: .roster)
        }
    ) {
        self.bootstrapAuthority = bootstrapAuthority
        self.resolveCandidates = resolveCandidates
    }

    /// One authority bootstrap and one resolution per activation. Nothing is
    /// cached across activations: a household switch must never reuse a foreign
    /// authority or a stale route.
    ///
    /// `popSigner` is threaded unchanged into the bootstrap AND into both roster
    /// clients, so the identity that authenticated the route is the same one
    /// that signs every roster call.
    func makeActivator(
        household: ActiveHouseholdState,
        popSigner: HouseholdPoPSigner,
        session: URLSession,
        now: @escaping @Sendable () -> Date
    ) async -> (any RosterEvidenceActivating)? {
        let snapshot: HouseholdMachinesSnapshot
        do {
            snapshot = try await bootstrapAuthority(popSigner)
        } catch {
            return nil
        }

        let authority = snapshot.reachabilityAuthority
        // The inventory and the authority it produced must both belong to the
        // household we are activating.
        guard snapshot.householdID == household.householdId,
              authority.householdID == household.householdId else {
            return nil
        }

        let resolution = await resolveCandidates(authority, authority.selfMachineID)
        guard case .candidates(let primary, _) = resolution else {
            // `.unavailable` and `.unresolved` both mean "no trusted route".
            return nil
        }
        // Defence in depth: the actor already refuses non-self machines, so a
        // candidate scoped elsewhere would mean the seam changed underneath us.
        guard primary.machineID == authority.selfMachineID else {
            return nil
        }

        let transport: RosterEvidenceClient.TransportPerform = { request in
            try await session.data(for: request)
        }
        let evidenceClient = RosterEvidenceClient(
            baseURL: primary.baseURL, popSigner: popSigner, perform: transport
        )
        let currencyClient = RosterCurrencyClient(
            baseURL: primary.baseURL, popSigner: popSigner, perform: transport
        )
        return RosterEvidenceCoordinator(
            store: RosterProjectionStore(
                expectedHouseholdId: household.householdId,
                householdPublicKey: household.householdPublicKey
            ),
            expectedHouseholdId: household.householdId,
            householdPublicKey: household.householdPublicKey,
            fetchEvidence: { nonce in
                try await evidenceClient.evidence(clientNonce: nonce)
            },
            probeCurrency: { machineId in
                try await currencyClient.currency(machineId: machineId)
            },
            nonceProvider: { PairingCrypto.randomBytes(count: 32) },
            now: now
        )
    }
}
