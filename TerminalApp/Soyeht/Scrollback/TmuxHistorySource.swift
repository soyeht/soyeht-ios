import UIKit

// Fetches tmux pane history via `SoyehtAPIClient.capturePaneContent` and
// exposes it as a sequence of attributed lines for the scrollback panel's
// collection view. Mirrors the shape of `ScrollbackStore` (count / line(at:))
// so the panel's data source can switch to it without other changes.
//
// Main-thread-only. Async API calls are dispatched on a detached Task and
// results are published back on the main actor before updating `lines`.
@MainActor
final class TmuxHistorySource {
    enum State {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var lines: [NSAttributedString] = []
    private(set) var state: State = .idle

    var container: String?
    var session: String?

    var onUpdate: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    // Monotonically increasing id assigned to each load(). Responses whose
    // id is older than the latest one ever issued are discarded, so a slow
    // response never overwrites a newer one.
    private var latestRequestID: UInt64 = 0

    var canLoad: Bool {
        guard let c = container, let s = session else { return false }
        return !c.isEmpty && !s.isEmpty
    }

    var count: Int { lines.count }

    func line(at index: Int) -> NSAttributedString {
        guard index >= 0 && index < lines.count else { return NSAttributedString() }
        return lines[index]
    }

    /// Kicks off a fresh fetch. A previous in-flight load is cancelled and
    /// any response that arrives after a newer request was issued is dropped.
    func load() {
        guard canLoad, let c = container, let s = session else { return }
        currentTask?.cancel()
        latestRequestID &+= 1
        let myID = latestRequestID
        state = .loading

        currentTask = Task { @MainActor [weak self] in
            do {
                let content = try await SoyehtAPIClient.shared.capturePaneContent(
                    container: c,
                    session: s
                )
                if Task.isCancelled { return }
                guard let self, self.latestRequestID == myID else { return }
                let parsed = AnsiTextParser.parseLines(
                    content,
                    fontSize: TerminalPreferences.shared.fontSize,
                    theme: .active
                )
                // Natural order — oldest at index 0, newest at the end. The
                // panel scrolls to the bottom on open and auto-follows the
                // tail while the user stays at the bottom.
                self.lines = parsed
                self.state = .loaded
                self.onUpdate?()
            } catch {
                if Task.isCancelled { return }
                guard let self, self.latestRequestID == myID else { return }
                self.state = .failed(error.localizedDescription)
                self.onUpdate?()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func clear() {
        cancel()
        lines = []
        state = .idle
        onUpdate?()
    }
}
