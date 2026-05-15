import Foundation

final class RemoteFileDownloadManager: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((String, Double, String?) -> Void)?
    var onCompletion: ((String, URL) -> Void)?
    var onFailure: ((String, Error) -> Void)?

    private struct Context {
        let remotePath: String
        let container: String
        var lastWrittenBytes: Int64
        var lastSampleAt: TimeInterval
        var temporaryURL: URL?
    }

    private lazy var urlSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: .main
    )

    // URLSession callbacks land on `delegateQueue: .main`, but the delegate
    // protocol is `nonisolated` and the callbacks can interleave with
    // `start…` / `cancel…` calls invoked from arbitrary threads (e.g. a
    // SwiftUI view that fires a download from `.task { … }`). The lock
    // serializes every read or mutation of the two task-tracking
    // dictionaries below so a concurrent callback cannot observe a
    // partially-updated map (orphaned context, missing task, lost
    // completion handler).
    private let lock = NSLock()
    private var contextsByTaskIdentifier: [Int: Context] = [:]
    private var tasksByRemotePath: [String: URLSessionDownloadTask] = [:]

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func startPreviewDownload(
        request: URLRequest,
        container: String,
        remotePath: String
    ) {
        let task = urlSession.downloadTask(with: request)
        let context = Context(
            remotePath: remotePath,
            container: container,
            lastWrittenBytes: 0,
            lastSampleAt: Date().timeIntervalSinceReferenceDate,
            temporaryURL: nil
        )
        // Capture the displaced task and install the new one in a single
        // critical section. The previous shape was cancel-then-register in
        // two phases, which opened a window where two concurrent
        // `startPreviewDownload` calls for the same remotePath could both
        // pass through the cancel branch before either registered: result
        // was two live tasks for one path, with the first
        // `didCompleteWithError` evicting the second's entry from
        // `tasksByRemotePath` and corrupting subsequent cancel/completion
        // routing. The replacement is now atomic — caller cancels whatever
        // was displaced (may be nil) outside the lock.
        let displaced: URLSessionDownloadTask? = withLock {
            let previous = tasksByRemotePath[remotePath]
            if let previous {
                contextsByTaskIdentifier.removeValue(forKey: previous.taskIdentifier)
            }
            tasksByRemotePath[remotePath] = task
            contextsByTaskIdentifier[task.taskIdentifier] = context
            return previous
        }
        displaced?.cancel()
        task.resume()
    }

    func cancel(remotePath: String) {
        let task: URLSessionDownloadTask? = withLock {
            guard let task = tasksByRemotePath.removeValue(forKey: remotePath) else { return nil }
            contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
            return task
        }
        task?.cancel()
    }

    func cancelAll() {
        let tasks: [URLSessionDownloadTask] = withLock {
            let snapshot = Array(tasksByRemotePath.values)
            tasksByRemotePath.removeAll()
            contextsByTaskIdentifier.removeAll()
            return snapshot
        }
        tasks.forEach { $0.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let payload: (remotePath: String, deltaBytes: Int64, deltaTime: TimeInterval)? = withLock {
            guard var context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else { return nil }
            let now = Date().timeIntervalSinceReferenceDate
            let delta = totalBytesWritten - context.lastWrittenBytes
            let elapsed = max(now - context.lastSampleAt, 0.001)
            context.lastWrittenBytes = totalBytesWritten
            context.lastSampleAt = now
            contextsByTaskIdentifier[downloadTask.taskIdentifier] = context
            return (context.remotePath, delta, elapsed)
        }
        guard let payload else { return }

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }

        let bytesPerSecond = Double(payload.deltaBytes) / payload.deltaTime
        let speedText: String?
        if bytesPerSecond > 0 {
            speedText = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        } else {
            speedText = nil
        }

        onProgress?(payload.remotePath, progress, speedText)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Snapshot under lock; the move/IO runs outside it. After the move
        // we re-enter the lock to verify our task is still the registered
        // one for this remotePath. A concurrent `cancel(...)` /
        // `cancelAll()` / superseding `startPreviewDownload` can run while
        // we hold the source URL on disk, and the previous shape blindly
        // reinserted the snapshot — resurrecting a context the user had
        // already cancelled and firing `onCompletion` for it.
        let snapshot: Context? = withLock { contextsByTaskIdentifier[downloadTask.taskIdentifier] }
        guard let context = snapshot else {
            // Already cancelled before we ran. URLSession owns `location`
            // (a temp file in its caches dir) and reaps it when this
            // delegate returns, so no cleanup is needed here.
            return
        }
        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = try DownloadsManager.shared.temporaryPreviewURL(
                container: context.container,
                remotePath: context.remotePath
            )
            // Shared atomic-move primitive — closes the TOCTOU window the
            // old `fileExists -> removeItem -> moveItem` dance left open.
            try DownloadsManager.atomicallyMove(from: location, to: destination)

            let stillCurrent: Bool = withLock {
                // Identity check against `tasksByRemotePath` (not just the
                // identifier-keyed context map) so a swap-then-replay
                // sequence — cancel removes ctx, a new start re-registers
                // a different task for the same path — does not "see"
                // itself as current.
                guard tasksByRemotePath[context.remotePath]?.taskIdentifier == downloadTask.taskIdentifier else {
                    contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier)
                    return false
                }
                var updated = context
                updated.temporaryURL = destination
                contextsByTaskIdentifier[downloadTask.taskIdentifier] = updated
                return true
            }
            if !stillCurrent {
                // Destination is in DownloadsManager's preview cache; the
                // user already cancelled or replaced this download, so
                // unlink the file we just swapped in.
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            let shouldNotify: Bool = withLock {
                let wasCurrent = tasksByRemotePath[context.remotePath]?.taskIdentifier == downloadTask.taskIdentifier
                contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier)
                if wasCurrent {
                    tasksByRemotePath.removeValue(forKey: context.remotePath)
                }
                return wasCurrent
            }
            if shouldNotify {
                onFailure?(context.remotePath, error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Pull the context out and decide whether this task is still the
        // one registered for its remotePath. If a concurrent
        // `startPreviewDownload` replaced us, we must NOT remove the
        // current entry from `tasksByRemotePath` and we must NOT fire
        // callbacks the user no longer expects for this old path.
        let outcome: (context: Context, isCurrent: Bool)? = withLock {
            guard let ctx = contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else { return nil }
            let isCurrent = tasksByRemotePath[ctx.remotePath]?.taskIdentifier == task.taskIdentifier
            if isCurrent {
                tasksByRemotePath.removeValue(forKey: ctx.remotePath)
            }
            return (ctx, isCurrent)
        }
        guard let outcome else { return }
        guard outcome.isCurrent else { return }

        let context = outcome.context

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue {
                return
            }
            onFailure?(context.remotePath, error)
            return
        }

        guard let temporaryURL = context.temporaryURL else {
            onFailure?(context.remotePath, URLError(.unknown))
            return
        }
        onCompletion?(context.remotePath, temporaryURL)
    }
}
