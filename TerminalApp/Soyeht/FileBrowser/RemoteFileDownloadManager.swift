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

    private var contextsByTaskIdentifier: [Int: Context] = [:]
    private var tasksByRemotePath: [String: URLSessionDownloadTask] = [:]

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
        contextsByTaskIdentifier[task.taskIdentifier] = context
        tasksByRemotePath[remotePath] = task
        task.resume()
    }

    func cancel(remotePath: String) {
        guard let task = tasksByRemotePath.removeValue(forKey: remotePath) else { return }
        contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    func cancelAll() {
        tasksByRemotePath.keys.forEach(cancel(remotePath:))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard var context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let deltaBytes = totalBytesWritten - context.lastWrittenBytes
        let deltaTime = max(now - context.lastSampleAt, 0.001)
        context.lastWrittenBytes = totalBytesWritten
        context.lastSampleAt = now
        contextsByTaskIdentifier[downloadTask.taskIdentifier] = context

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }

        let bytesPerSecond = Double(deltaBytes) / deltaTime
        let speedText: String?
        if bytesPerSecond > 0 {
            speedText = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        } else {
            speedText = nil
        }

        onProgress?(context.remotePath, progress, speedText)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard var context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else { return }
        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = try DownloadsManager.shared.temporaryPreviewURL(
                container: context.container,
                remotePath: context.remotePath
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            context.temporaryURL = destination
            contextsByTaskIdentifier[downloadTask.taskIdentifier] = context
        } catch {
            contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier)
            tasksByRemotePath.removeValue(forKey: context.remotePath)
            onFailure?(context.remotePath, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else { return }
        tasksByRemotePath.removeValue(forKey: context.remotePath)

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
