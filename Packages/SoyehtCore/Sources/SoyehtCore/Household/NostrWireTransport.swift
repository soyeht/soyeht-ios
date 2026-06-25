import Foundation

public protocol NostrWireTransport: Sendable {
    func send(_ frame: String) async throws
    func recv() async throws -> String?
    func close() async
}

public enum NostrWireTransportError: Error, Sendable {
    case notConnected
    case closed
}

public actor URLSessionWebSocketTransport: NostrWireTransport {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect() async {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    public func send(_ frame: String) async throws {
        guard let task else { throw NostrWireTransportError.notConnected }
        try await task.send(.string(frame))
    }

    public func recv() async throws -> String? {
        guard let task else { return nil }
        do {
            let message = try await task.receive()
            switch message {
            case .string(let string):
                return string
            case .data(let data):
                return String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                return nil
            }
        } catch {
            return nil
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

public actor InProcessWSSTransport: NostrWireTransport {
    private var buffer: [String] = []
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var closed = false
    private weak var peer: InProcessWSSTransport?

    public init() {}

    fileprivate func bind(peer: InProcessWSSTransport) {
        self.peer = peer
    }

    public func send(_ frame: String) async throws {
        guard !closed, let peer else { throw NostrWireTransportError.closed }
        await peer.deposit(frame)
    }

    private func deposit(_ frame: String) {
        if waiters.isEmpty {
            buffer.append(frame)
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: frame)
        }
    }

    public func recv() async throws -> String? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func close() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    public static func makePair() async -> (client: InProcessWSSTransport, server: InProcessWSSTransport) {
        let first = InProcessWSSTransport()
        let second = InProcessWSSTransport()
        await first.bind(peer: second)
        await second.bind(peer: first)
        return (first, second)
    }
}
