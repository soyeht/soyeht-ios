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

    /// Browses for a setup invitation; every exit path stops the browser.
    func listen() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let gate = ResumeOnce()

                let finish: @Sendable (Outcome) -> Void = { [browser] outcome in
                    guard gate.claim() else { return }
                    browser.stop()
                    continuation.resume(returning: outcome)
                }

                browser.onStateChange = { [claimClient] state in
                    switch state {
                    case .discovered(let payload):
                        Task {
                            do {
                                _ = try await claimClient.claim(
                                    token: payload.token,
                                    ownerDisplayName: payload.ownerDisplayName,
                                    iphoneApnsToken: payload.iphoneApnsToken
                                )
                                finish(.invitationClaimed(
                                    ownerDisplayName: payload.ownerDisplayName,
                                    iphoneApnsToken: payload.iphoneApnsToken
                                ))
                            } catch {
                                finish(.failed(error))
                            }
                        }
                    case .failed(let message):
                        finish(.failed(ListenerError.browserFailed(message)))
                    case .idle, .browsing, .stopped:
                        break
                    }
                }

                browser.start()

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.discoveryTimeout
                ) {
                    finish(.notFound)
                }
            }
        } onCancel: { [browser] in
            browser.stop()
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Atomically claims the gate. Returns true only on the first call.
    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}

private enum ListenerError: Error, LocalizedError {
    case browserFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserFailed(let message):
            return message
        }
    }
}
