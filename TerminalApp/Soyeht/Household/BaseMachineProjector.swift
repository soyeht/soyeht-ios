import CryptoKit
import Foundation
import SoyehtCore
import os

private let baseMachineProjectorLogger = Logger(
    subsystem: "com.soyeht.mobile",
    category: "base-machine-projector"
)

/// Projects the owner-authenticated engine self-machine into the in-process
/// server registry.
///
/// The base Mac never went through the legacy pair-machine HMAC flow, so this
/// is deliberately an identity-only, non-routable, non-persistent projection.
/// It makes the owned Mac visible now; the presence slice later supplies a
/// verified route and availability signal without retrofitting a fake pairing
/// secret or host into this milestone.
@MainActor
final class BaseMachineProjector {
    static let shared = BaseMachineProjector()

    private let authorityBootstrapper: any BaseMachineAuthorityBootstrapping
    private let keyProvider: any OwnerIdentityKeyCreating
    private let registry: ServerRegistry
    private let activeHousehold: @MainActor () -> ActiveHouseholdState?
    private let canReadMachineInventory: @MainActor (ActiveHouseholdState) -> Bool
    private var inFlight = false

    init(
        authorityBootstrapper: any BaseMachineAuthorityBootstrapping = MachineReachabilityAuthorityBootstrapper(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        registry: ServerRegistry? = nil,
        activeHousehold: @escaping @MainActor () -> ActiveHouseholdState? = {
            SoyehtIdentity.shared.active?.underlying
        },
        canReadMachineInventory: @escaping @MainActor (ActiveHouseholdState) -> Bool = {
            $0.personCert.allows("claws.list")
        }
    ) {
        self.authorityBootstrapper = authorityBootstrapper
        self.keyProvider = keyProvider
        self.registry = registry ?? .shared
        self.activeHousehold = activeHousehold
        self.canReadMachineInventory = canReadMachineInventory
    }

    /// Best-effort refresh. A missing identity, unavailable key, rejected PoP,
    /// or incomplete engine inventory leaves the existing projection alone;
    /// there is never a fallback to an unbound household member or a raw host.
    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        guard let household = activeHousehold() else {
            registry.clearBaseMachineProjections()
            return
        }
        // Do this before any capability/key/network check. A new active
        // household must never keep a prior household's display-only Mac
        // while its own inventory is unavailable.
        registry.clearBaseMachineProjections(notMatching: household.householdId)
        guard canReadMachineInventory(household) else { return }

        let ownerIdentity: any OwnerIdentitySigning
        do {
            ownerIdentity = try keyProvider.loadOwnerIdentity(
                keyReference: household.signingKeyReference,
                publicKey: household.signingPublicKey,
                personId: household.ownerPersonId
            )
        } catch {
            baseMachineProjectorLogger.debug("base machine inventory owner identity unavailable")
            return
        }

        let snapshot: HouseholdMachinesSnapshot
        do {
            snapshot = try await authorityBootstrapper.bootstrap(
                popSigner: HouseholdPoPSigner(ownerIdentity: ownerIdentity)
            )
        } catch {
            baseMachineProjectorLogger.debug("base machine inventory refresh unavailable")
            return
        }

        // The bootstrapper validates the response against its seed household.
        // Re-read the active identity *after* awaiting the owner-PoP request:
        // an A → B household switch during that request must have zero
        // projection side effects for A in B's home.
        guard let currentHousehold = activeHousehold(),
              currentHousehold.householdId == household.householdId,
              snapshot.householdID == currentHousehold.householdId,
              snapshot.reachabilityAuthority.householdID == currentHousehold.householdId,
              snapshot.reachabilityAuthority.selfMachineID == snapshot.selfMachine.machineID else {
            if let currentHousehold = activeHousehold() {
                registry.clearBaseMachineProjections(
                    notMatching: currentHousehold.householdId
                )
            } else {
                registry.clearBaseMachineProjections()
            }
            baseMachineProjectorLogger.error("base machine inventory household or self binding mismatch")
            return
        }

        registry.projectBaseMachine(
            householdID: currentHousehold.householdId,
            serverID: Self.stableServerID(for: snapshot.selfMachine.machineID),
            machineID: snapshot.selfMachine.machineID,
            hostLabel: snapshot.selfMachine.hostLabel,
            joinedAt: snapshot.selfMachine.joinedAt
        )
    }

    /// A deterministic UUIDv5-shaped UI identifier derived only from the
    /// authenticated machine key. It is not an endpoint, host, or pairing ID.
    static func stableServerID(for machineID: MachineID) -> UUID {
        let digest = SHA256.hash(
            data: Data("soyeht.base-machine:\(machineID.rawValue)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // UUID version 5 shape
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return NSUUID(uuidBytes: bytes) as UUID
    }
}

/// Narrow app-side seam so projector tests can supply a validated inventory
/// without opening a socket or a Secure Enclave key. The production adapter is
/// the Core bootstrapper, whose only endpoint source is the legacy-seed helper
/// inside `LegacyStoredEndpointStrategy`.
@MainActor
protocol BaseMachineAuthorityBootstrapping {
    func bootstrap(
        popSigner: HouseholdPoPSigner
    ) async throws -> HouseholdMachinesSnapshot
}

extension MachineReachabilityAuthorityBootstrapper: BaseMachineAuthorityBootstrapping {}
