import UIKit
import SwiftTerm
import SoyehtCore
import os

/// A SwiftTerm `TerminalView` bound to a real `ClawShareTerminalSession`.
///
/// Round 19: this is the last mile — the friend taps "open" and drives a real
/// PTY shell on the claw through this view. The binding is symmetric:
///
/// - keyboard → `send(source:data:)` → `session.send` (terminal stdin)
/// - PTY output → `Output.feed` → `feed(byteArray:)` (screen)
/// - the view resizes → `sizeChanged` → `session.resize` (Resize frame → PTY)
/// - the view is dismissed → `close()` → `session.stop` (clean teardown)
/// - the target exits / the stream drops → `Output.sessionEnded` →
///   `onSessionEnded` so the host removes the open state (no zombie).
///
/// The view never fabricates "connected": it only renders bytes the real
/// session delivered, and the open gate is enforced upstream
/// (`ClawShareSessionStatus.isOpenable == .interactiveReady`).
public final class ClawShareTerminalView: TerminalView, TerminalViewDelegate {
    private static let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "terminal-view")

    private var session: ClawShareTerminalSession?
    private var startTask: Task<Void, Never>?

    /// Fired on the main actor once the interactive session is live (the only
    /// point the host may reveal the terminal as usable).
    public var onInteractiveReady: (() -> Void)?
    /// Fired on the main actor when the session ends (clean exit, target
    /// close, transport drop, or a failed open). The host must drop any
    /// "open" affordance and present a recoverable state. `reason` is a
    /// stable, non-secret code — the host maps it to human copy.
    public var onSessionEnded: ((String) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        getTerminal().changeScrollback(5000)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { startTask?.cancel() }

    /// Bind a data-plane client (already credential-loaded + session-started)
    /// and bring the interactive terminal up. On `.interactiveReady` the
    /// terminal is live; anything else fires `onSessionEnded`.
    public func attach(client: any ClawShareDataPlaneClient) {
        guard session == nil else { return }
        let terminal = getTerminal()
        let output = Output(view: self)
        let session = ClawShareTerminalSession(
            client: client,
            output: output,
            initialCols: UInt16(clamping: terminal.cols),
            initialRows: UInt16(clamping: terminal.rows)
        )
        self.session = session

        startTask = Task { [weak self] in
            let state = await session.start()
            await MainActor.run {
                guard let self else { return }
                switch state {
                case .open:
                    _ = self.becomeFirstResponder()
                    self.onInteractiveReady?()
                case .failed(let reason), .ended(let reason):
                    self.onSessionEnded?(reason)
                default:
                    self.onSessionEnded?("not-interactive")
                }
            }
        }
    }

    /// Tear the session down cleanly. Idempotent.
    public func close(reason: String = "user-closed") {
        startTask?.cancel()
        startTask = nil
        if let session {
            Task { await session.stop(reason: reason) }
        }
        session = nil
    }

    // MARK: - Output sink (session → screen)

    /// Forwards remote output + lifecycle to the view on the main actor.
    /// `@unchecked Sendable`: the only stored reference is a weak `UIView`,
    /// touched exclusively inside `MainActor.run`.
    private final class Output: ClawShareTerminalOutput, @unchecked Sendable {
        weak var view: ClawShareTerminalView?
        init(view: ClawShareTerminalView) { self.view = view }

        func feed(_ bytes: Data) async {
            let slice = ArraySlice<UInt8>(bytes)
            await MainActor.run { [weak view] in
                view?.feed(byteArray: slice)
            }
        }

        func sessionEnded(reason: String) async {
            await MainActor.run { [weak view] in
                view?.onSessionEnded?(reason)
            }
        }
    }

    // MARK: - TerminalViewDelegate (screen → session)

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let session else { return }
        let bytes = Data(data)
        Task { try? await session.send(bytes) }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let session else { return }
        let cols = UInt16(clamping: newCols)
        let rows = UInt16(clamping: newRows)
        Task { try? await session.resize(cols: cols, rows: rows) }
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
