import Foundation

/// Pre-runtime-activation boundary for the owner mesh data plane.
///
/// This is intentionally not a tunnel controller, presence client, or
/// reachability strategy. It gives future mesh code one machine-scoped input
/// shape while the security contract confines the permitted positive state,
/// peer attestation, revocation, and effect boundary. Until a reviewed runtime
/// implementation exists, this boundary can only fail closed.
///
/// In particular, it must not accept a URL, host name, display label, tunnel
/// IP, or a legacy pairing identifier as a machine identity. The sole inputs
/// are the `/machines` authority binding and the requested authenticated
/// `MachineID`.
enum MeshTransportReadiness: Equatable, Sendable {
    /// No transport conclusion can be formed before a runtime presents a
    /// verified peer/runtime attestation.
    case unresolved(MeshTransportReadinessUnresolvedReason)

    /// A future runtime may be configured but temporarily unavailable. This
    /// branch exists to keep the tri-state distinction explicit; the inert
    /// implementation below deliberately never claims it has a runtime.
    case unavailable(MeshTransportReadinessUnavailableReason)
}

enum MeshTransportReadinessUnresolvedReason: Equatable, Sendable {
    case missingVerifiedRuntimeAttestation
}

enum MeshTransportReadinessUnavailableReason: Equatable, Sendable {
    case runtimeNotIntegrated
}

/// Atomic security prerequisites for the first runtime/adapter merge.
///
/// These are deliberately named together because satisfying only one is not a
/// partial activation path: the runtime remains unavailable until both have a
/// reviewed, executable proof in the same change.
enum MeshRuntimeActivationPrecondition: String, CaseIterable, Sendable {
    /// `baseMeshPublicKeyHex`, when it is eventually used as a tunnel peer,
    /// comes from a signed source or an explicit validated pin. Merely
    /// syntactically well-formed public configuration is insufficient.
    case authenticatedOrPinnedBaseMeshPublicKeyHex

    /// Dev and Release resolve distinct App Group containers from their build
    /// configuration, with a test proving Dev cannot open Release state.
    case buildConfigurationScopedAppGroupIsolation
}

/// Future mesh readiness implementations consume the same authenticated
/// machine identity used by `MachineReachability`; they do not resolve an
/// endpoint themselves. `purpose` is retained so the later reachability
/// strategy can make the approved, purpose-specific policy decision without
/// creating a parallel resolver.
protocol MeshTransportReadinessProviding: Sendable {
    func readiness(
        authority: MachineReachabilityAuthority,
        machineID: MachineID,
        purpose: MachineReachabilityPurpose
    ) async -> MeshTransportReadiness
}

/// The only implementation allowed before the data-plane runtime slice.
///
/// It has no tunnel configuration, persistence, NEX, network, packet, route,
/// candidate, or presence side effect. A functional implementation must be a
/// separately reviewed replacement that establishes a verified peer capability
/// and revocation behavior. That replacement must atomically prove
/// both a signed-or-pinned base mesh peer key and build-configuration-scoped
/// Dev≠Release App Group selection before it reads the App Group, starts a
/// provider, dials, or carries traffic.
actor InertMeshTransportReadiness: MeshTransportReadinessProviding {
    func readiness(
        authority _: MachineReachabilityAuthority,
        machineID _: MachineID,
        purpose _: MachineReachabilityPurpose
    ) async -> MeshTransportReadiness {
        .unavailable(.runtimeNotIntegrated)
    }
}
