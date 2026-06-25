import Foundation

/// The data source for the person-first SHARED APPS display. The owner-UX view
/// model reads through this seam, so the live `GET /api/v1/claw-share/groups`
/// reader (a later @vivian server slice) plugs in behind it with no UI change —
/// a localized swap of `StubOwnerGroupsReader` for the GET-backed reader.
public protocol OwnerGroupsReading: Sendable {
    func fetchOwnerGroups() async throws -> OwnerGroupsSnapshot
}

/// In-memory reader for SwiftUI previews + UI-structure work before the GET
/// endpoint exists. Carries a fixed snapshot.
public struct StubOwnerGroupsReader: OwnerGroupsReading {
    public var snapshot: OwnerGroupsSnapshot

    public init(snapshot: OwnerGroupsSnapshot = .preview) {
        self.snapshot = snapshot
    }

    public func fetchOwnerGroups() async throws -> OwnerGroupsSnapshot {
        snapshot
    }
}

public extension OwnerGroupsSnapshot {
    /// Sample shaped after the `fz6bO` mockup — the owner sharing apps with a
    /// small group ("você + Dani"). `grantedClaws` carries human-readable claw
    /// labels here for the preview; the live GET returns claw ids that the UI
    /// resolves to names via the claw inventory.
    static let preview = OwnerGroupsSnapshot(
        groups: [
            OwnerGroup(
                groupID: "g_family",
                name: "Family",
                members: [OwnerGroupMember(memberID: "g_dani", label: "Dani", deviceCount: 1)],
                grantedClaws: ["House finances", "Photo album"]
            ),
            OwnerGroup(
                groupID: "g_school",
                name: "School",
                members: [OwnerGroupMember(memberID: "g_alex", label: "Alex", deviceCount: 2)],
                grantedClaws: ["School site"]
            ),
        ],
        publishedClaws: []
    )
}
