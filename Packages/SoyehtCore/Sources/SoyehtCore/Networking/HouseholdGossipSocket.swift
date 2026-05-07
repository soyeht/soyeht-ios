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
        /// Wall-clock duration a connection must survive (from handshake-
        /// success to disconnect) to count as "stable" — only stable
        /// disconnects reset `consecutiveFailures` to zero. A flaky
        /// connection that delivers a frame then drops every few seconds
        /// will accumulate failures and eventually exhaust retries,
        /// instead of resetting on each one-frame "success" and looping
        /// forever. Default 30s, tuned for the household-gossip use case.
        public var minStableDurationToResetFailures: TimeInterval

        public init(
            pingInterval: TimeInterval = 30,
            initialBackoff: TimeInterval = 1,
            maxBackoff: TimeInterval = 60,
            backoffMultiplier: Double = 2,
            maxReconnectAttempts: Int? = nil,
            maxFrameBytes: Int = 1 << 20,
            minStableDurationToResetFailures: TimeInterval = 30
        ) {
            self.pingInterval = pingInterval
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.backoffMultiplier = backoffMultiplier
            self.maxReconnectAttempts = maxReconnectAttempts
            self.maxFrameBytes = maxFrameBytes
            self.minStableDurationToResetFailures = minStableDurationToResetFailures
        }
    }

    public typealias TransportFactory = @Sendable (UInt64?) async throws -> any HouseholdGossipTransport
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias NowProvider = @Sendable () -> Date
    public typealias CursorHandshakeBuilder = @Sendable (UInt64?) -> HouseholdGossipFrame

    private let configuration: Configuration
    private let transportFactory: TransportFactory
    private let sleeper: Sleeper
    private let nowProvider: NowProvider
    private let cursorHandshakeBuilder: CursorHandshakeBuilder
    private var cursor: UInt64?
    private var transport: (any HouseholdGossipTransport)?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var framesContinuation: AsyncThrowingStream<HouseholdGossipFrame, Error>.Continuation?
    private var eventsContinuation: AsyncStream<HouseholdGossipSocketEvent>.Continuation?
    private var framesStream: AsyncThrowingStream<HouseholdGossipFrame, Error>?
    private var eventsStream: AsyncStream<HouseholdGossipSocketEvent>?
    private var isCancelled = false
    private var attempt = 0
    private var consecutiveFailures = 0
    private var connectionEstablishedAt: Date?

    /// `cursorHandshakeBuilder` is REQUIRED — there is no default. Phase 3
    /// pins the gossip wire to canonical CBOR (RFC 8949 §4.2.1) per
    /// `theyos/contracts/household-gossip-consumer.md`, so the only
    /// correct choice is the contract's CBOR frame. Forcing the caller to
    /// inject it makes wire-format drift a compile error rather than a
    /// silent JSON regression.
    public init(
        configuration: Configuration = Configuration(),
        initialCursor: UInt64? = nil,
        cursorHandshakeBuilder: @escaping CursorHandshakeBuilder,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        nowProvider: @escaping NowProvider = { Date() },
        transportFactory: @escaping TransportFactory
    ) {
        self.configuration = configuration
        self.cursor = initialCursor
        self.cursorHandshakeBuilder = cursorHandshakeBuilder
        self.sleeper = sleeper
        self.nowProvider = nowProvider
        self.transportFactory = transportFactory
    }

    /// Single-subscriber API. Calling more than once is a programmer
    /// error — the socket only manages one continuation per stream and a
    /// second call would orphan the first stream silently. The cached
    /// stream is returned on subsequent calls so callers that legitimately
    /// share the handle (e.g. dependency-injected adapters) still get a
    /// usable reference.
    ///
    /// Post-cancel safety: if the socket has already been cancelled, the
    /// returned stream is finished immediately. Without this guard a
    /// fresh continuation would be created but never wired into
    /// `cancel()` (which already ran), and the consumer's `for await`
    /// would hang forever.
    public func frames() -> AsyncThrowingStream<HouseholdGossipFrame, Error> {
        if let cached = framesStream { return cached }
        let stream = AsyncThrowingStream<HouseholdGossipFrame, Error> { continuation in
            if self.isCancelled {
                continuation.finish()
                return
            }
            self.framesContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.cancel() }
            }
        }
        framesStream = stream
        return stream
    }

    /// Single-subscriber API; same caching + post-cancel contract as
    /// `frames()`.
    public func events() -> AsyncStream<HouseholdGossipSocketEvent> {
        if let cached = eventsStream { return cached }
        let stream = AsyncStream<HouseholdGossipSocketEvent> { continuation in
            if self.isCancelled {
                continuation.finish()
                return
            }
            self.eventsContinuation = continuation
        }
        eventsStream = stream
        return stream
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
            // M1: cap is the max number of consecutive failures BEFORE
            // exhaustion — i.e. with cap=2 we exhaust after the second
            // failure, not the third. `>=` matches the field name.
            if let cap = configuration.maxReconnectAttempts, consecutiveFailures >= cap {
                emitEvent(.retriesExhausted)
                framesContinuation?.finish(
                    throwing: HouseholdGossipSocketError.retriesExhausted(
                        lastUnderlyingDescription: lastUnderlying
                    )
                )
                // M3: events stream MUST also finish here, otherwise any
                // subscriber iterating events hangs forever once the
                // socket has terminated.
                eventsContinuation?.finish()
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
                connectionEstablishedAt = nowProvider()
                startPingLoop(transport: transport)
                try await receiveLoop(transport: transport)
                stopPingLoop()
                if isCancelled { return }
                emitEvent(.disconnected(reason: "stream-end"))
                accumulateOrResetFailuresOnDisconnect()
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
                accumulateOrResetFailuresOnDisconnect()
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

    /// M5: time-based failure accounting. A connection that lasted at
    /// least `minStableDurationToResetFailures` is considered "real
    /// progress" — reset the consecutive-failure counter. Anything
    /// shorter (factory throw, immediate handshake error, one-frame-then-
    /// drop) increments toward the retry cap so a flaky link eventually
    /// exhausts instead of looping forever.
    private func accumulateOrResetFailuresOnDisconnect() {
        defer { connectionEstablishedAt = nil }
        if let establishedAt = connectionEstablishedAt,
           nowProvider().timeIntervalSince(establishedAt) >= configuration.minStableDurationToResetFailures {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
    }

    private func receiveLoop(transport: any HouseholdGossipTransport) async throws {
        var batch = 0
        while !isCancelled {
            let frame = try await transport.receive()
            try checkFrameSize(frame)
            // M5: per-frame reset removed. The flaky-1-frame-then-drop
            // pattern would otherwise keep `consecutiveFailures` at 0
            // forever and prevent retry-cap exhaustion. Reset is now
            // duration-based in `accumulateOrResetFailuresOnDisconnect`.
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
