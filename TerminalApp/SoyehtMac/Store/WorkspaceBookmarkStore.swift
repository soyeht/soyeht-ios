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
        guard let path = defaults.string(forKey: Self.pathKey(workspaceID)) else {
            defaults.removeObject(forKey: Self.bookmarkKey(workspaceID))
            return nil
        }
        let storedURL = URL(fileURLWithPath: path)
        guard !Self.isInUserDocuments(storedURL) else {
            forget(workspaceID)
            return nil
        }
        if !Self.requiresSecurityScopedBookmarks {
            activeURLs[workspaceID] = storedURL
            return storedURL
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
            guard !Self.isInUserDocuments(url) else {
                forget(workspaceID)
                return nil
            }
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

    func forgetPersistedDocumentWorkspacePaths() {
        let pathSuffix = ".path"
        let bookmarkSuffix = ".pathBookmark"
        let snapshot = defaults.dictionaryRepresentation()

        for (key, value) in snapshot where key.hasPrefix("workspace.") {
            if key.hasSuffix(pathSuffix), let path = value as? String {
                let url = URL(fileURLWithPath: path)
                guard Self.isInUserDocuments(url) else { continue }
                defaults.removeObject(forKey: key)
                let prefix = String(key.dropLast(pathSuffix.count))
                defaults.removeObject(forKey: "\(prefix)\(bookmarkSuffix)")
                continue
            }

            if key.hasSuffix(bookmarkSuffix) {
                let prefix = String(key.dropLast(bookmarkSuffix.count))
                if snapshot["\(prefix)\(pathSuffix)"] == nil {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        // NSOpenPanel persists its last folder as a bookmark. If that folder was
        // inside ~/Documents, AppKit can revive the prompt before our UI asks
        // the user to choose a project, so reset the remembered panel root.
        defaults.removeObject(forKey: "NSOSPLastRootDirectory")
        defaults.synchronize()
    }

    // MARK: - Helpers

    private static var requiresSecurityScopedBookmarks: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AppSandboxContainerID") != nil
            || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static func isInUserDocuments(_ url: URL) -> Bool {
        let documentsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate == documentsURL || candidate.path.hasPrefix(documentsURL.path + "/")
    }

    private static func bookmarkKey(_ id: Workspace.ID) -> String {
        "workspace.\(id.uuidString).pathBookmark"
    }

    private static func pathKey(_ id: Workspace.ID) -> String {
        "workspace.\(id.uuidString).path"
    }
}
