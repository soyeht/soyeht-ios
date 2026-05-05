import Foundation

struct NavigationHistoryEntry: Codable, Hashable {
    let path: String
    let lastAccessedAt: Date
    let pinned: Bool
}

final class NavigationHistoryStore {
    static let shared = NavigationHistoryStore()

    private let defaults = UserDefaults.standard

    func entries(container: String, session: String) -> [NavigationHistoryEntry] {
        let key = storageKey(container: container, session: session)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NavigationHistoryEntry].self, from: data) else {
            return []
        }
        return decoded.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }
    }

    func record(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        let pinned = current.first(where: { $0.path == path })?.pinned ?? false
        current.removeAll { $0.path == path }
        current.insert(
            NavigationHistoryEntry(path: path, lastAccessedAt: Date(), pinned: pinned),
            at: 0
        )
        persist(current.prefix(24), container: container, session: session)
    }

    func togglePinned(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        guard let index = current.firstIndex(where: { $0.path == path }) else { return }
        let entry = current[index]
        current[index] = NavigationHistoryEntry(
            path: entry.path,
            lastAccessedAt: entry.lastAccessedAt,
            pinned: !entry.pinned
        )
        persist(current, container: container, session: session)
    }

    func remove(path: String, container: String, session: String) {
        var current = entries(container: container, session: session)
        current.removeAll { $0.path == path }
        persist(current, container: container, session: session)
    }

    private func persist<S: Sequence>(_ entries: S, container: String, session: String) where S.Element == NavigationHistoryEntry {
        let key = storageKey(container: container, session: session)
        let array = Array(entries)
        if let data = try? JSONEncoder().encode(array) {
            defaults.set(data, forKey: key)
        }
    }

    private func storageKey(container: String, session: String) -> String {
        "soyeht.fileBrowser.history.\(container).\(session)"
    }
}
