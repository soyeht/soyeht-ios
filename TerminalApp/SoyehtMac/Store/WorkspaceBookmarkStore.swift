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
    private let defaults = UserDefaults.standard

    // MARK: - Save

    /// Record a bookmark for a newly-picked URL. Caller has already confirmed
    /// the NSOpenPanel selection. Starts accessing the resource immediately.
    @discardableResult
    func save(url: URL, for workspaceID: Workspace.ID) -> URL? {
        if !Self.requiresSecurityScopedBookmarks {
            defaults.set(url.path, forKey: Self.pathKey(workspaceID))
            defaults.removeObject(forKey: Self.bookmarkKey(workspaceID))
            activeURLs[workspaceID] = url
            return url
        }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey(workspaceID))
            defaults.set(url.path, forKey: Self.pathKey(workspaceID))
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
        if !Self.requiresSecurityScopedBookmarks {
            if let path = defaults.string(forKey: Self.pathKey(workspaceID)) {
                let url = URL(fileURLWithPath: path)
                activeURLs[workspaceID] = url
                return url
            }
            guard let data = defaults.data(forKey: Self.bookmarkKey(workspaceID)) else { return nil }
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                defaults.set(url.path, forKey: Self.pathKey(workspaceID))
                defaults.removeObject(forKey: Self.bookmarkKey(workspaceID))
                activeURLs[workspaceID] = url
                return url
            } catch {
                NSLog("[WorkspaceBookmarkStore] unsandboxed resolve failed for \(workspaceID): \(error)")
                return nil
            }
        }
        guard let data = defaults.data(forKey: Self.bookmarkKey(workspaceID)) else { return nil }
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
                    defaults.set(refreshed, forKey: Self.bookmarkKey(workspaceID))
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
        defaults.removeObject(forKey: Self.bookmarkKey(workspaceID))
        defaults.removeObject(forKey: Self.pathKey(workspaceID))
    }

    func releaseAll() {
        for (_, url) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }

    // MARK: - Helpers

    private static var requiresSecurityScopedBookmarks: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AppSandboxContainerID") != nil
            || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static func bookmarkKey(_ id: Workspace.ID) -> String {
        "workspace.\(id.uuidString).pathBookmark"
    }

    private static func pathKey(_ id: Workspace.ID) -> String {
        "workspace.\(id.uuidString).path"
    }
}
