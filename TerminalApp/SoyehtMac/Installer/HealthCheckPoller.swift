import Foundation
import SoyehtCore

/// Polls `GET /bootstrap/status` at 500ms intervals during MA3 (install progress).
///
/// Normal cadence: 500ms between fetches. On consecutive errors, applies
/// exponential backoff [1, 2, 4, 8s] capped at 30s per delay. Stops and
/// returns when the bootstrap listener is responsive.
/// Gives up after `maxConsecutiveErrors` without a successful response.
final class HealthCheckPoller: Sendable {

    private static let normalInterval: Duration = .milliseconds(500)
    private static let backoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    private static let maxBackoff: Duration = .seconds(30)
    private static let maxConsecutiveErrors = 12

    private let client: BootstrapStatusClient

    init(baseURL: URL) {
        self.client = BootstrapStatusClient(baseURL: baseURL)
    }

    init(client: BootstrapStatusClient) {
        self.client = client
    }

    /// Polls until a terminal state is reached and returns the final status.
    /// Respects Task cancellation — cancelled tasks throw `CancellationError`.
    func pollUntilReady() async throws -> BootstrapStatusResponse {
        var consecutiveErrors = 0

        while true {
            do {
                let response = try await client.fetch()
                consecutiveErrors = 0

                if response.state == .uninitialized ||
                    BootstrapStatusClient.terminalPollStates.contains(response.state) {
                    return response
                }

                try await Task.sleep(for: Self.normalInterval)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1

                if consecutiveErrors > Self.maxConsecutiveErrors {
                    throw PollerError.engineUnreachable
                }

                let idx = min(consecutiveErrors - 1, Self.backoffSchedule.count - 1)
                let delay = min(Self.backoffSchedule[idx], Self.maxBackoff)
                try await Task.sleep(for: delay)
            }
        }
    }
}

enum PollerError: Error, LocalizedError {
    /// Engine did not become reachable within the retry budget.
    case engineUnreachable

    var errorDescription: String? {
        switch self {
        case .engineUnreachable:
            return "O Soyeht não ficou disponível a tempo. Tente reiniciar o Mac."
        }
    }
}
