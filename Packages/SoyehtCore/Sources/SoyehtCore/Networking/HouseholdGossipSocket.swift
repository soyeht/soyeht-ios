import Foundation

public enum HouseholdGossipFrame: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public enum HouseholdGossipSocketError: Error, Equatable, Sendable {
    case oversizeFrame(byteCount: Int, max: Int)
    case unsupportedFrameKind
    case retriesExhausted(lastUnderlyingDescription: String)
}

/// Lifecycle event emitted by `HouseholdGossipSocket` for observability.
/// Tests rely on this to assert reconnect cadence and ping/pong cycles
/// without depending on wall-clock timing.
public enum HouseholdGossipSocketEvent: Sendable, Equatable {
    case connecting(attempt: Int, cursor: UInt64?)
    case connected(cursor: UInt64?)
    case pingSent
    case pongReceived
    case framesReceived(count: Int)
    case disconnected(reason: String)
    case reconnectScheduled(after: TimeInterval, attempt: Int)
    case cancelled
    case retriesExhausted
}

/// Minimal transport surface so the production `URLSessionWebSocketTask`
/// wrapper and the in-test stub can both satisfy `HouseholdGossipSocket`.
public protocol HouseholdGossipTransport: Sendable {
    func send(_ frame: HouseholdGossipFrame) async throws
    func receive() async throws -> HouseholdGossipFrame
    func sendPing() async throws
    func cancel()
}

/// Wraps a WebSocket transport with cursor-resume, exponential reconnect,
/// and a ping/pong heartbeat. Frame-level CBOR semantics are NOT this
/// layer's concern — it surfaces raw frames to the gossip consumer (T024).
///
/// Lifecycle:
/// 1. Caller obtains `frames` (AsyncThrowingStream of validated frames) and
///    optionally `events` (AsyncStream of lifecycle events) BEFORE calling
///    `start()`.
/// 2. `start()` opens the transport, sends the cursor handshake, and begins
///    the receive/ping loops.
/// 3. On transport error, the socket sleeps with exponential backoff and
///    reconnects, sending the latest cursor.
/// 4. The caller updates cursor as it processes frames via
///    `updateCursor(_:)` so the next reconnect resumes correctly.
/// 5. `cancel()` finishes both streams and is idempotent.
public actor HouseholdGossipSocket {
    public struct Configuration: Sendable {
        public var pingInterval: TimeInterval
        public var initialBackoff: TimeInterval
        public var maxBackoff: TimeInterval
        public var backoffMultiplier: Double
        public var maxReconnectAttempts: Int?
        public var maxFrameBytes: Int

        public init(
            pingInterval: TimeInterval = 30,
            initialBackoff: TimeInterval = 1,
            maxBackoff: TimeInterval = 60,
            backoffMultiplier: Double = 2,
            maxReconnectAttempts: Int? = nil,
            maxFrameBytes: Int = 1 << 20
        ) {
            self.pingInterval = pingInterval
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.backoffMultiplier = backoffMultiplier
            self.maxReconnectAttempts = maxReconnectAttempts
            self.maxFrameBytes = maxFrameBytes
        }
    }

    public typealias TransportFactory = @Sendable (UInt64?) async throws -> any HouseholdGossipTransport
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let configuration: Configuration
    private let transportFactory: TransportFactory
    private let sleeper: Sleeper
    private let cursorHandshakeBuilder: @Sendable (UInt64?) -> HouseholdGossipFrame
    private var cursor: UInt64?
    private var transport: (any HouseholdGossipTransport)?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var framesContinuation: AsyncThrowingStream<HouseholdGossipFrame, Error>.Continuation?
    private var eventsContinuation: AsyncStream<HouseholdGossipSocketEvent>.Continuation?
    private var isCancelled = false
    private var attempt = 0
    private var consecutiveFailures = 0

    public init(
        configuration: Configuration = Configuration(),
        initialCursor: UInt64? = nil,
        cursorHandshakeBuilder: @escaping @Sendable (UInt64?) -> HouseholdGossipFrame = HouseholdGossipSocket.defaultCursorHandshake,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        transportFactory: @escaping TransportFactory
    ) {
        self.configuration = configuration
        self.cursor = initialCursor
        self.cursorHandshakeBuilder = cursorHandshakeBuilder
        self.sleeper = sleeper
        self.transportFactory = transportFactory
    }

    /// Default handshake encodes the cursor as a JSON `{"since": N}` text
    /// frame. Callers that need a different handshake (e.g. CBOR with a
    /// signed PoP token) inject `cursorHandshakeBuilder`.
    public static let defaultCursorHandshake: @Sendable (UInt64?) -> HouseholdGossipFrame = { cursor in
        if let cursor {
            .text("{\"since\":\(cursor)}")
        } else {
            .text("{}")
        }
    }

    public func frames() -> AsyncThrowingStream<HouseholdGossipFrame, Error> {
        AsyncThrowingStream { continuation in
            self.framesContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.cancel() }
            }
        }
    }

    public func events() -> AsyncStream<HouseholdGossipSocketEvent> {
        AsyncStream { continuation in
            self.eventsContinuation = continuation
        }
    }

    public func updateCursor(_ newCursor: UInt64) {
        cursor = newCursor
    }

    public func currentCursor() -> UInt64? { cursor }

    public func start() {
        guard receiveTask == nil, !isCancelled else { return }
        receiveTask = Task { await self.runConnectionLoop() }
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        receiveTask?.cancel()
        pingTask?.cancel()
        transport?.cancel()
        transport = nil
        emitEvent(.cancelled)
        framesContinuation?.finish()
        eventsContinuation?.finish()
    }

    private func runConnectionLoop() async {
        var lastUnderlying = ""
        while !isCancelled {
            attempt += 1
            if let cap = configuration.maxReconnectAttempts, consecutiveFailures > cap {
                emitEvent(.retriesExhausted)
                framesContinuation?.finish(
                    throwing: HouseholdGossipSocketError.retriesExhausted(
                        lastUnderlyingDescription: lastUnderlying
                    )
                )
                return
            }
            let attemptCursor = cursor
            emitEvent(.connecting(attempt: attempt, cursor: attemptCursor))
            do {
                let transport = try await transportFactory(attemptCursor)
                self.transport = transport
                try await transport.send(cursorHandshakeBuilder(attemptCursor))
                emitEvent(.connected(cursor: attemptCursor))
                attempt = 0
                startPingLoop(transport: transport)
                try await receiveLoop(transport: transport)
                stopPingLoop()
                if isCancelled { return }
                emitEvent(.disconnected(reason: "stream-end"))
                consecutiveFailures += 1
            } catch is CancellationError {
                stopPingLoop()
                return
            } catch {
                stopPingLoop()
                self.transport?.cancel()
                self.transport = nil
                lastUnderlying = "\(error)"
                if isCancelled { return }
                emitEvent(.disconnected(reason: lastUnderlying))
                consecutiveFailures += 1
                // Transient transport-layer errors (including .oversizeFrame
                // and .unsupportedFrameKind) trigger reconnect; only an
                // explicit .cancelled bubbles up via the cancel path.
            }
            let backoff = computeBackoff(forAttempt: max(1, consecutiveFailures))
            emitEvent(.reconnectScheduled(after: backoff, attempt: attempt))
            do {
                try await sleeper(backoff)
            } catch {
                return
            }
        }
    }

    private func receiveLoop(transport: any HouseholdGossipTransport) async throws {
        var batch = 0
        while !isCancelled {
            let frame = try await transport.receive()
            try checkFrameSize(frame)
            consecutiveFailures = 0
            framesContinuation?.yield(frame)
            batch += 1
            if batch.isMultiple(of: 16) {
                emitEvent(.framesReceived(count: batch))
                batch = 0
            }
        }
    }

    private func checkFrameSize(_ frame: HouseholdGossipFrame) throws {
        let size: Int
        switch frame {
        case .text(let value): size = value.utf8.count
        case .data(let value): size = value.count
        }
        if size > configuration.maxFrameBytes {
            throw HouseholdGossipSocketError.oversizeFrame(
                byteCount: size,
                max: configuration.maxFrameBytes
            )
        }
    }

    private func startPingLoop(transport: any HouseholdGossipTransport) {
        pingTask?.cancel()
        guard configuration.pingInterval > 0 else { return }
        let interval = configuration.pingInterval
        let sleeper = self.sleeper
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper(interval)
                    try await transport.sendPing()
                    await self?.emitPingPong()
                } catch {
                    return
                }
            }
        }
    }

    private func emitPingPong() {
        emitEvent(.pingSent)
        emitEvent(.pongReceived)
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func computeBackoff(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = configuration.initialBackoff * pow(configuration.backoffMultiplier, Double(exponent))
        return min(raw, configuration.maxBackoff)
    }

    private func emitEvent(_ event: HouseholdGossipSocketEvent) {
        eventsContinuation?.yield(event)
    }
}

// MARK: - URLSessionWebSocketTask transport adapter

/// Production transport that bridges to `URLSessionWebSocketTask`. The
/// transport is opened via the factory passed to `HouseholdGossipSocket`,
/// which lets the caller decide URLSession configuration, request headers
/// (including PoP), and cursor placement (query string vs. handshake frame).
public actor URLSessionGossipTransport: HouseholdGossipTransport {
    private let task: URLSessionWebSocketTask
    private var didStart = false

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        task.resume()
    }

    public func send(_ frame: HouseholdGossipFrame) async throws {
        startIfNeeded()
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .text(let value): message = .string(value)
        case .data(let value): message = .data(value)
        }
        try await task.send(message)
    }

    public func receive() async throws -> HouseholdGossipFrame {
        startIfNeeded()
        let message = try await task.receive()
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default:
            throw HouseholdGossipSocketError.unsupportedFrameKind
        }
    }

    public func sendPing() async throws {
        startIfNeeded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    nonisolated public func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
