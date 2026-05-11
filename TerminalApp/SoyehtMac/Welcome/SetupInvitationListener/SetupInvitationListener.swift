import Foundation
import SoyehtCore

/// Mac-side setup-invitation listener (T070).
///
/// On first launch, before showing HouseNamingView, browses `_soyeht-setup._tcp.`
/// on Tailnet via SetupInvitationBrowser. If an invitation is found within the
/// timeout window, claims the token via POST /bootstrap/claim-setup-invitation and
/// skips the naming UI (iPhone will provide the name via POST /bootstrap/initialize).
final class SetupInvitationListener: @unchecked Sendable {
    enum Outcome: Sendable {
        case invitationClaimed(ownerDisplayName: String?, iphoneApnsToken: Data?)
        case notFound
        case failed(Error)
    }

    private let engineBaseURL: URL
    private let browser: SetupInvitationBrowser
    private let claimClient: SetupInvitationClaimClient

    private static let discoveryTimeout: TimeInterval = 5.0

    init(engineBaseURL: URL) {
        self.engineBaseURL = engineBaseURL
        self.browser = SetupInvitationBrowser()
        self.claimClient = SetupInvitationClaimClient(baseURL: engineBaseURL)
    }

    /// Browses for a setup-invitation; claims it if found before `timeout`.
    func listen() async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await self.browseAndClaim() }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.discoveryTimeout))
                return .notFound
            }

            // Return whichever finishes first, cancel the other.
            guard let first = await group.next() else { return .notFound }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Private

    private func browseAndClaim() async -> Outcome {
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var _done = false
            var done: Bool {
                get { lock.withLock { _done } }
                set { lock.withLock { _done = newValue } }
            }
        }
        let gate = ResumeOnce()
        let payload = await withCheckedContinuation { continuation in
            browser.onStateChange = { state in
                guard !gate.done else { return }
                if case .discovered(let p) = state {
                    gate.done = true
                    continuation.resume(returning: p)
                }
            }
            browser.start()
        }

        do {
            _ = try await claimClient.claim(
                token: payload.token,
                ownerDisplayName: payload.ownerDisplayName,
                iphoneApnsToken: payload.iphoneApnsToken
            )
            browser.stop()
            return .invitationClaimed(
                ownerDisplayName: payload.ownerDisplayName,
                iphoneApnsToken: payload.iphoneApnsToken
            )
        } catch {
            browser.stop()
            return .failed(error)
        }
    }
}
