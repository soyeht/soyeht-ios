import Foundation
import os

/// One-shot pre-flight check that a WebSocket URL can complete the
/// TLS+WS handshake. Used before navigating into a terminal view so
/// connection failures surface as a clean error UI instead of a
/// half-loaded screen.
///
/// Closes the test connection immediately after the verdict either way —
/// the verifier never streams data.
public enum TerminalWebSocketHandshake {
    /// Verifies the WebSocket handshake against `url`. Returns `.success`
    /// when the server completes `didOpenWithProtocol` within `timeout`.
    /// Returns `.failure` on timeout, close, or transport error.
    public static func verify(url: URL, timeout: TimeInterval = 10) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            let verifier = HandshakeVerifier(url: url, timeout: timeout) { result in
                continuation.resume(returning: result)
            }
            verifier.start()
        }
    }
}

private final class HandshakeVerifier: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let timeout: TimeInterval
    private let completion: (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timeoutWork: DispatchWorkItem?
    private var completed = false
    private let lock = NSLock()

    init(url: URL, timeout: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        self.url = url
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: url)
        task?.resume()

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let alreadyCompleted = completed
        completed = true
        lock.unlock()
        guard !alreadyCompleted else { return }

        timeoutWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        completion(result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Self.logger.info("[WS] Handshake verify OK")
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.failure(URLError(.networkConnectionLost)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        }
    }

    private static let logger = Logger(subsystem: "com.soyeht.core", category: "ws-handshake")
}
