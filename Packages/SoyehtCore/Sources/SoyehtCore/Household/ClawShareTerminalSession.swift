import Foundation
import os

/// Sink for a claw-share terminal's output + lifecycle. The on-screen
/// terminal view (a SwiftTerm `TerminalView` in the app) implements this:
/// `feed` writes remote stdout to the screen; `sessionEnded` removes the
/// live session UI and shows a recoverable, non-technical message.
public protocol ClawShareTerminalOutput: Sendable {
    /// Remote terminal output (stdout/stderr) → screen.
    func feed(_ bytes: Data) async
    /// The interactive session ended (clean exit, target close, or
    /// transport drop). `reason` is a stable, non-secret string; the UI
    /// must drop any "open" affordance and present a recoverable state.
    func sessionEnded(reason: String) async
}

/// Drives a real interactive terminal over a `ClawShareDataPlaneClient`.
///
/// Round 18: the data plane is a persistent stream to a real PTY shell on
/// the claw. This actor is the terminal's controller — it owns the
/// open gate, the keyboard → stdin path, terminal resize, the stdout read
/// loop, and clean teardown:
///
/// - `start()` adopts an already-interactive client (the gate opened the
///   stream) or, for a fresh client, runs `healthPing` then `openStream`. It
///   only reports the session **open** once the client reaches
///   `.interactiveReady` (a real shell produced output). An open-but-silent
///   stream never presents as a usable terminal, and an already-open stream is
///   never re-handshaked (that would tear it down).
/// - `send` forwards keyboard input as terminal stdin.
/// - `resize` propagates the on-screen terminal's columns × rows to the
///   remote PTY.
/// - the read loop forwards remote output to the `ClawShareTerminalOutput`
///   sink until a clean close / typed exit / transport error, then
///   transitions to `.ended` and notifies the sink — no zombie session.
public actor ClawShareTerminalSession {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// Live interactive terminal (the only state the UI may "open").
        case open(sinceUnix: UInt64)
        /// Ended cleanly / recoverably — the UI shows a retry affordance.
        case ended(reason: String)
        /// Failed to bring up.
        case failed(reason: String)
    }

    private let client: any ClawShareDataPlaneClient
    private let output: any ClawShareTerminalOutput
    private var state: State = .idle
    private var readTask: Task<Void, Never>?
    private var cols: UInt16
    private var rows: UInt16
    private let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "terminal-session")

    public init(
        client: any ClawShareDataPlaneClient,
        output: any ClawShareTerminalOutput,
        initialCols: UInt16 = 80,
        initialRows: UInt16 = 24
    ) {
        self.client = client
        self.output = output
        self.cols = initialCols
        self.rows = initialRows
    }

    public func currentState() -> State { state }

    /// Whether the UI may present a live, usable terminal.
    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    /// Bring the interactive session up: health → open (gated on the
    /// client reaching `.interactiveReady`) → push the initial terminal
    /// size → start the output read loop. Idempotent: a second call while
    /// already open is a no-op.
    @discardableResult
    public func start() async -> State {
        if case .open = state { return state }
        state = .connecting
        do {
            // The open gate (`ClawShareOpenCoordinator`) dials, authenticates,
            // and opens the stream to PROVE the session reached
            // `.interactiveReady` before the host reveals "Open", then hands
            // that SAME live client here. Re-running the handshake on an
            // already-open stream makes the engine reject the post-stream
            // `Health`/`Open` frames and tears the session down — so when the
            // client is already interactive we ADOPT the live stream instead
            // of re-handshaking. The shell's first output (buffered by the
            // bridge) is still delivered by the first `receiveData()`.
            let opened: ClawShareSessionStatus
            let existing = await client.currentStatus()
            if case .interactiveReady = existing {
                opened = existing
            } else {
                _ = try await client.healthPing()
                opened = try await client.openStream()
            }
            guard case .interactiveReady(let since) = opened else {
                // Refuse to present a terminal for anything short of a live
                // interactive session — even a `.streamReady` socket.
                state = .failed(reason: "no-interactive-session")
                logger.error("terminal_open_gate_failed status=\(String(describing: opened), privacy: .public)")
                return state
            }
            state = .open(sinceUnix: since)
            // Sync the remote PTY to the current on-screen size.
            try? await client.resize(cols: cols, rows: rows)
            startReadLoop()
        } catch {
            state = .failed(reason: "\(error)")
            logger.error("terminal_start_failed err=\(String(describing: error), privacy: .public)")
        }
        return state
    }

    /// Keyboard input → terminal stdin.
    public func send(_ data: Data) async throws {
        try await client.sendData(data)
    }

    /// The on-screen terminal resized — propagate to the remote PTY and
    /// remember it so a reconnect re-applies the same size.
    public func resize(cols: UInt16, rows: UInt16) async throws {
        self.cols = cols
        self.rows = rows
        try await client.resize(cols: cols, rows: rows)
    }

    /// Tear the session down. Idempotent. Cancels the read loop and stops
    /// the client so nothing keeps running after the screen closes.
    public func stop(reason: String) async {
        readTask?.cancel()
        readTask = nil
        _ = await client.stopSession(reason: reason)
        state = .ended(reason: reason)
    }

    private func startReadLoop() {
        readTask = Task { [client, output, weak self] in
            while !Task.isCancelled {
                do {
                    let bytes = try await client.receiveData()
                    await output.feed(bytes)
                } catch {
                    // NoSession (clean close / typed target exit) or a
                    // transport failure — end recoverably, no zombie.
                    let reason = Self.endReason(from: error)
                    await self?.markEnded(reason: reason)
                    await output.sessionEnded(reason: reason)
                    return
                }
            }
        }
    }

    private func markEnded(reason: String) {
        // Don't clobber an explicit stop() that already set .ended.
        if case .open = state {
            state = .ended(reason: reason)
        }
    }

    private static func endReason(from error: Error) -> String {
        switch error {
        case ClawShareDataPlaneError.noSession:
            return "session-ended"
        case ClawShareDataPlaneError.handshakeFailed(let m):
            return "transport:\(m)"
        default:
            return "transport-error"
        }
    }
}
