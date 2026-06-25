import Combine
import Foundation

/// Presentation model for the person-first SHARED APPS screen. Reads the owner's
/// groups through `OwnerGroupsReading` (stub now, GET-backed later — a localized
/// swap) and runs the owner actions via `GroupOwnerActions`. Pure presentation
/// state; the SwiftUI view (app target) observes it. Lab-testable with the stub
/// reader (no live engine).
///
/// `ObservableObject` (not the `@Observable` macro) so it stays available on the
/// package's deployment target.
@MainActor
public final class SharedAppsViewModel: ObservableObject {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var snapshot: OwnerGroupsSnapshot =
        OwnerGroupsSnapshot(groups: [], publishedClaws: [])

    private let reader: any OwnerGroupsReading
    private let actions: GroupOwnerActions?

    public init(reader: any OwnerGroupsReading, actions: GroupOwnerActions? = nil) {
        self.reader = reader
        self.actions = actions
    }

    /// (Re)load the owner's groups from the reader.
    public func load() async {
        phase = .loading
        do {
            snapshot = try await reader.fetchOwnerGroups()
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Share a claw with a brand-new group + member ("share with my fiancée"),
    /// then reload so the new SHARED APP appears. No-op without an actions client
    /// (preview). On failure the screen surfaces `.failed`.
    public func shareClaw(
        clawID: String,
        withNewGroupID groupID: String,
        named name: String,
        memberID: String,
        memberLabel: String
    ) async {
        guard let actions else { return }
        do {
            try await actions.shareClaw(
                clawID: clawID,
                withNewGroupID: groupID,
                named: name,
                memberID: memberID,
                memberLabel: memberLabel
            )
            await load()
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
