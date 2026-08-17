import CoreServices
import Foundation

/// Watches only the three known provider roots. The monitor never inspects or
/// logs event paths; it merely coalesces change signals into an incremental
/// rescan. A low-frequency poll covers dropped/coalesced FSEvents.
final class ConversationHistoryMonitor: @unchecked Sendable {
    private let roots: ConversationHistoryRoots
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(
        label: "com.soyeht.conversation-intelligence.monitor",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var fallbackTask: Task<Void, Never>?
    private var lastCallbackAt = Date.distantPast

    init(
        roots: ConversationHistoryRoots,
        callback: @escaping @Sendable () -> Void
    ) {
        self.roots = roots
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        stateLock.lock()
        guard stream == nil, fallbackTask == nil else {
            stateLock.unlock()
            return
        }

        let existingRoots = monitoredRootURLs().filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if !existingRoots.isEmpty {
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let created = FSEventStreamCreate(
                nil,
                { _, clientInfo, _, _, _, _ in
                    guard let clientInfo else { return }
                    let monitor = Unmanaged<ConversationHistoryMonitor>
                        .fromOpaque(clientInfo)
                        .takeUnretainedValue()
                    monitor.receiveChangeSignal()
                },
                &context,
                existingRoots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                2.0,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagIgnoreSelf
                )
            )
            if let created {
                FSEventStreamSetDispatchQueue(created, queue)
                if FSEventStreamStart(created) {
                    stream = created
                } else {
                    FSEventStreamInvalidate(created)
                    FSEventStreamRelease(created)
                }
            }
        }

        fallbackTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.receiveChangeSignal()
            }
        }
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        let stream = self.stream
        self.stream = nil
        let fallbackTask = self.fallbackTask
        self.fallbackTask = nil
        stateLock.unlock()

        fallbackTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func monitoredRootURLs() -> [URL] {
        [
            roots.codexSessions,
            roots.claudeProjects,
            roots.openCodeDatabase.deletingLastPathComponent(),
        ]
    }

    private func receiveChangeSignal() {
        stateLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastCallbackAt) >= 1.5 else {
            stateLock.unlock()
            return
        }
        lastCallbackAt = now
        stateLock.unlock()
        callback()
    }
}
