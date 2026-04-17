import Foundation

/// Persists security-scoped bookmarks for workspace project paths in
/// UserDefaults under `workspace.<id>.pathBookmark`. Also tracks which URLs
/// are currently accessing their scoped resource so we can stop on close /
/// app termination.
///
/// `Workspace.projectPath` is a transient URL — never serialized on the model.
/// This store is the resolution layer.
@MainActor
final class WorkspaceBookmarkStore {

    static let shared = WorkspaceBookmarkStore()

    private var activeURLs: [Workspace.ID: URL] = [:]

    // MARK: - Save

    /// Record a bookmark for a newly-picked URL. Caller has already confirmed
    /// the NSOpenPanel selection. Starts accessing the resource immediately.
    @discardableResult
    func save(url: URL, for workspaceID: Workspace.ID) -> URL? {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.key(workspaceID))
            _ = url.startAccessingSecurityScopedResource()
            activeURLs[workspaceID] = url
            return url
        } catch {
            NSLog("[WorkspaceBookmarkStore] save failed for \(workspaceID): \(error)")
            return nil
        }
    }

    // MARK: - Resolve

    /// Resolve the URL for a workspace. Refreshes the stored bookmark if the
    /// system reports it as stale. Returns nil if there's no bookmark or it
    /// cannot be resolved.
    func resolveURL(for workspaceID: Workspace.ID) -> URL? {
        if let url = activeURLs[workspaceID] { return url }
        guard let data = UserDefaults.standard.data(forKey: Self.key(workspaceID)) else { return nil }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else { return nil }
            activeURLs[workspaceID] = url
            if stale {
                if let refreshed = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: Self.key(workspaceID))
                }
            }
            return url
        } catch {
            NSLog("[WorkspaceBookmarkStore] resolve failed for \(workspaceID): \(error)")
            return nil
        }
    }

    // MARK: - Teardown

    func release(_ workspaceID: Workspace.ID) {
        if let url = activeURLs.removeValue(forKey: workspaceID) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func forget(_ workspaceID: Workspace.ID) {
        release(workspaceID)
        UserDefaults.standard.removeObject(forKey: Self.key(workspaceID))
    }

    func releaseAll() {
        for (_, url) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }

    // MARK: - Helpers

    private static func key(_ id: Workspace.ID) -> String {
        "workspace.\(id.uuidString).pathBookmark"
    }
}
