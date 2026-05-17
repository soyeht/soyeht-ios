import CoreServices
import Foundation

final class EditorFileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private(set) var children: [EditorFileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    func loadChildren() -> [EditorFileNode] {
        guard isDirectory else { return [] }
        if let children { return children }
        let skipped = Set([".git", ".build", ".swiftpm", "DerivedData", "node_modules"])
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )) ?? []
        let loaded = urls
            .filter { !skipped.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".DS_Store") }
            .map { childURL -> EditorFileNode in
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey])
                return EditorFileNode(url: childURL, isDirectory: values?.isDirectory == true)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        children = loaded
        return loaded
    }

    func invalidateChildren(recursive: Bool = false) {
        if recursive {
            children?.forEach { $0.invalidateChildren(recursive: true) }
        }
        children = nil
    }
}

final class EditorDirectoryWatcher {
    private static let ignoredNames = Set([".git", ".build", ".swiftpm", "DerivedData", "node_modules", ".DS_Store"])

    private let rootURL: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(rootURL: URL, onChange: @escaping () -> Void) {
        self.rootURL = rootURL.standardizedFileURL
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let eventCallback: FSEventStreamCallback = { _, contextInfo, _, eventPaths, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<EditorDirectoryWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.handleEvents(paths: paths)
    }

    private func handleEvents(paths: [String]) {
        guard paths.isEmpty || paths.contains(where: isRelevantPath) else { return }
        onChange()
    }

    private func isRelevantPath(_ path: String) -> Bool {
        let rootPath = rootURL.path
        let eventPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard eventPath == rootPath || eventPath.hasPrefix(rootPath + "/") else { return false }
        guard eventPath != rootPath else { return true }

        let relative = eventPath.dropFirst(rootPath.count + 1)
        let components = relative.split(separator: "/").map(String.init)
        return !components.contains { Self.ignoredNames.contains($0) }
    }
}
