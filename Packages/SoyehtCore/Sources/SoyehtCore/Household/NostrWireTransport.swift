import Foundation

/// Byte-level transport the Nostr client speaks. Production uses
/// `URLSessionWebSocketTransport`; tests inject an
/// `InProcessWSSTransport` paired with a `MockNostrRelay`.
public protocol NostrWireTransport: Sendable {
    func send(_ frame: String) async throws
    func recv() async throws -> String?
    func close() async
}

public enum NostrWireTransportError: Error, Sendable {
    case notConnected
    case closed
}

// MARK: - Production: URLSession-backed transport

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
            let msg = try await task.receive()
            switch msg {
            case .string(let s): return s
            case .data(let d):   return String(data: d, encoding: .utf8) ?? ""
            @unknown default:    return nil
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

// MARK: - In-process paired transports (for tests)

/// In-process transport: behaves like the client end of a TCP-WS
/// connection but actually pipes JSON frames into a paired peer
/// (the mock relay). Internal buffer + waiter queue means the
/// same actor-isolated `recv` semantics hold.
public actor InProcessWSSTransport: NostrWireTransport {
    private var buffer: [String] = []
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var closed: Bool = false
    /// Weak so the pair can be deallocated symmetrically. The
    /// public factory `makePair()` keeps strong refs alive for the
    /// caller.
    private weak var peer: InProcessWSSTransport?

    public init() {}

    fileprivate func bind(peer: InProcessWSSTransport) {
        self.peer = peer
    }

    public func send(_ frame: String) async throws {
        guard !closed, let peer else { throw NostrWireTransportError.closed }
        await peer.deposit(frame)
    }

    fileprivate func deposit(_ frame: String) {
        if !waiters.isEmpty {
            let cc = waiters.removeFirst()
            cc.resume(returning: frame)
        } else {
            buffer.append(frame)
        }
    }

    public func recv() async throws -> String? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if closed { return nil }
        return await withCheckedContinuation { (cc: CheckedContinuation<String?, Never>) in
            waiters.append(cc)
        }
    }

    public func close() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        for cc in pending {
            cc.resume(returning: nil)
        }
    }

    /// Build a connected pair. Use the `.client` half for the
    /// `NostrWSSClient`; the `.server` half goes to the mock relay.
    public static func makePair() async -> (client: InProcessWSSTransport, server: InProcessWSSTransport) {
        let a = InProcessWSSTransport()
        let b = InProcessWSSTransport()
        await a.bind(peer: b)
        await b.bind(peer: a)
        return (a, b)
    }
}
