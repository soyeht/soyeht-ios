import Foundation

/// When a reused terminal view must be told to forget the input modes a dead
/// process latched (kitty keyboard, mouse tracking, bracketed paste).
///
/// The rule is small and it is the whole cure, so it lives apart from the
/// view that applies it and is tested directly.
///
/// Why it is not simply "reset on attach": the engine replays the
/// conversation's history AFTER the attach call returns, and that history
/// carries whatever the dead process left in it — MEASURED 2026-09-04, pane
/// @zain's session log held three `CSI > 7 u` pushes and not one pop, and a
/// plain shell restored over it received Shift+D as `CSI 68 ; 2 u`. So the
/// reset has to be repeated once the replay window closes.
///
/// Why the arm is consumed when the window OPENS rather than when it closes:
/// a session that keeps running gets replayed again on every transient
/// WebSocket reconnect. If the arm survived to a later window, the reset
/// would land on a live TUI that legitimately owns those modes and take its
/// keyboard away mid-session.
struct InputModeResetSchedule: Equatable {
    private(set) var isArmed = false
    private(set) var appliesWhenReplayCloses = false

    /// The attacher spawned a NEW session behind this view. (A reconnected
    /// session is never armed: its TUI is still running and still owns its
    /// modes.)
    mutating func armForNewSession() {
        isArmed = true
    }

    /// `replay_start` reached the parser, in stream order.
    mutating func replayWindowOpened() {
        guard isArmed else { return }
        isArmed = false
        appliesWhenReplayCloses = true
    }

    /// `replay_done` reached the parser, in stream order.
    /// - Returns: `true` when the caller must feed the reset sequences now.
    mutating func replayWindowClosed() -> Bool {
        guard appliesWhenReplayCloses else { return false }
        appliesWhenReplayCloses = false
        return true
    }

    /// The transport was torn down (configure, disconnect). A pending reset
    /// belongs to the session that armed it; the next attach arms its own.
    mutating func transportTornDown() {
        isArmed = false
        appliesWhenReplayCloses = false
    }
}
