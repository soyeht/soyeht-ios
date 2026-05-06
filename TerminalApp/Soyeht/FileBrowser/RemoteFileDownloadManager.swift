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
        cancel(remotePath: remotePath)
        let task = urlSession.downloadTask(with: request)
        let context = Context(
            remotePath: remotePath,
            container: container,
            lastWrittenBytes: 0,
            lastSampleAt: Date().timeIntervalSinceReferenceDate,
            temporaryURL: nil
        )
        withLock {
            contextsByTaskIdentifier[task.taskIdentifier] = context
            tasksByRemotePath[remotePath] = task
        }
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
        let snapshot: Context? = withLock { contextsByTaskIdentifier[downloadTask.taskIdentifier] }
        guard var context = snapshot else { return }
        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = try DownloadsManager.shared.temporaryPreviewURL(
                container: context.container,
                remotePath: context.remotePath
            )
            // Atomic swap into place — see DownloadsManager.atomicallyMove.
            // The previous `fileExists → removeItem → moveItem` had a TOCTOU
            // window where a concurrent process or a symlink replacement
            // could redirect the move to an attacker-chosen path.
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch CocoaError.fileWriteFileExists {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            }
            context.temporaryURL = destination
            withLock {
                contextsByTaskIdentifier[downloadTask.taskIdentifier] = context
            }
        } catch {
            withLock {
                contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier)
                tasksByRemotePath.removeValue(forKey: context.remotePath)
            }
            onFailure?(context.remotePath, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let context: Context? = withLock {
            guard let ctx = contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else { return nil }
            tasksByRemotePath.removeValue(forKey: ctx.remotePath)
            return ctx
        }
        guard let context else { return }

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
