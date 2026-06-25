import Foundation

/// The owner's group-management action API — the intention-revealing seam the
/// person-first UI (slice 3b) binds to, over the canonical-CBOR `/group-op`
/// client. Each method is one owner action (one signed `MeshEvent`); the
/// `shareClaw` composite is the headline owner intent ("share this app with my
/// fiancée"). Errors propagate from `GroupOpClient` (`BootstrapError` on non-2xx,
/// PoP signer errors verbatim).
///
/// Read-only group state (for display) is intentionally NOT here — it needs a
/// `GET groups` endpoint (a server slice), tracked separately. This layer is
/// write-only and exercisable with no live engine.
public struct GroupOwnerActions: Sendable {
    private let client: GroupOpClient

    public init(client: GroupOpClient) {
        self.client = client
    }

    // MARK: - Group lifecycle

    public func createGroup(id groupID: String, name: String) async throws {
        try await client.apply(.create(groupID: groupID, name: name))
    }

    public func renameGroup(id groupID: String, name: String) async throws {
        try await client.apply(.rename(groupID: groupID, name: name))
    }

    // MARK: - Membership

    public func addMember(groupID: String, memberID: String, label: String) async throws {
        try await client.apply(.addMember(groupID: groupID, memberID: memberID, label: label))
    }

    public func removeMember(groupID: String, memberID: String) async throws {
        try await client.apply(.removeMember(groupID: groupID, memberID: memberID))
    }

    /// Approve a member's self-signed device binding (received over the join
    /// leg). The engine re-verifies `binding.verify()` and fails closed.
    public func enrollMemberDevice(_ binding: MemberDeviceBinding) async throws {
        try await client.apply(.enrollMemberDevice(binding: binding))
    }

    public func retireMemberDevice(memberID: String, devicePub: Data) async throws {
        try await client.apply(.retireMemberDevice(memberID: memberID, devicePub: devicePub))
    }

    // MARK: - Claw access

    public func grantClaw(groupID: String, clawID: String) async throws {
        try await client.apply(.grantClaw(groupID: groupID, clawID: clawID))
    }

    public func revokeClaw(groupID: String, clawID: String) async throws {
        try await client.apply(.revokeClaw(groupID: groupID, clawID: clawID))
    }

    // MARK: - Public publish

    public func publishClaw(_ clawID: String) async throws {
        try await client.apply(.publishClaw(clawID: clawID))
    }

    public func unpublishClaw(_ clawID: String) async throws {
        try await client.apply(.unpublishClaw(clawID: clawID))
    }

    // MARK: - Composite

    /// Share a claw with a brand-new group + one member — the core owner intent
    /// ("share this app with my fiancée; only the two of us"). Three signed
    /// events in order: create the group, add the member, grant the claw. Each
    /// op is idempotent on the engine, so a retry after a mid-sequence failure
    /// is safe.
    public func shareClaw(
        clawID: String,
        withNewGroupID groupID: String,
        named groupName: String,
        memberID: String,
        memberLabel: String
    ) async throws {
        try await createGroup(id: groupID, name: groupName)
        try await addMember(groupID: groupID, memberID: memberID, label: memberLabel)
        try await grantClaw(groupID: groupID, clawID: clawID)
    }
}
