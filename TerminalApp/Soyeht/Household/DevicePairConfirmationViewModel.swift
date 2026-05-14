import Foundation
import SoyehtCore

@MainActor
final class DevicePairConfirmationViewModel: ObservableObject {
    enum State: Equatable {
        case pending
        case authorizing
        case succeeded
        case failed(String)
        case dismissed
    }

    typealias ApproveAction = @Sendable (DevicePairRequestEnvelope) async throws -> Void
    typealias NowProvider = @Sendable () -> Date

    let envelope: DevicePairRequestEnvelope
    let displayDeviceName: String
    let displayPlatform: String

    @Published private(set) var state: State = .pending
    @Published private(set) var secondsRemaining: Int
    @Published private(set) var confirmInFlight = false

    var isConfirmEnabled: Bool {
        state == .pending && secondsRemaining > 0 && !confirmInFlight
    }

    private let queue: DevicePairRequestQueue
    private let approveAction: ApproveAction
    private let nowProvider: NowProvider

    init(
        envelope: DevicePairRequestEnvelope,
        queue: DevicePairRequestQueue,
        nowProvider: @escaping NowProvider = { Date() },
        approveAction: @escaping ApproveAction
    ) {
        self.envelope = envelope
        self.queue = queue
        self.nowProvider = nowProvider
        self.approveAction = approveAction
        self.displayDeviceName = envelope.deviceName
        self.displayPlatform = envelope.platform == "ipados" ? "iPadOS" : "iOS"
        self.secondsRemaining = Self.remainingSeconds(until: envelope.ttlUnix, now: nowProvider())
    }

    func updateCountdown(now: Date? = nil) async {
        let current = now ?? nowProvider()
        secondsRemaining = Self.remainingSeconds(until: envelope.ttlUnix, now: current)
        guard secondsRemaining == 0, (state == .pending || state == .authorizing) else { return }
        _ = await queue.pendingRequests(now: current)
        state = .dismissed
    }

    func dismiss() async {
        guard state != .dismissed else { return }
        _ = await queue.dismiss(idempotencyKey: envelope.idempotencyKey)
        state = .dismissed
    }

    func confirm() async {
        guard state == .pending, !confirmInFlight else { return }
        confirmInFlight = true
        defer { confirmInFlight = false }

        let now = nowProvider()
        await updateCountdown(now: now)
        guard state == .pending else { return }
        guard let claimed = await queue.claim(idempotencyKey: envelope.idempotencyKey, now: now) else {
            state = .dismissed
            return
        }

        state = .authorizing
        do {
            try await approveAction(claimed)
            guard !Task.isCancelled else { return }
            _ = await queue.confirmClaim(idempotencyKey: claimed.idempotencyKey, now: nowProvider())
            state = .succeeded
        } catch HouseholdPoPError.biometryCanceled {
            _ = await queue.revertClaim(idempotencyKey: claimed.idempotencyKey, now: nowProvider())
            state = .pending
        } catch OwnerIdentityKeyError.biometryCanceled {
            _ = await queue.revertClaim(idempotencyKey: claimed.idempotencyKey, now: nowProvider())
            state = .pending
        } catch {
            _ = await queue.failClaim(idempotencyKey: claimed.idempotencyKey)
            state = .failed(Self.localizedFailureMessage(for: error))
        }
    }

    private static func remainingSeconds(until ttlUnix: UInt64, now: Date) -> Int {
        let expiry = Date(timeIntervalSince1970: TimeInterval(ttlUnix))
        return max(0, Int(ceil(expiry.timeIntervalSince(now))))
    }

    private static func localizedFailureMessage(for error: Error) -> String {
        switch error {
        case HouseholdDevicePairingError.identityKeyUnavailable:
            return String(localized: "This iPhone cannot approve another iPhone. Use the first owner iPhone.")
        case HouseholdDevicePairingError.approvalRejected:
            return String(localized: "The Mac rejected this approval. Try Add iPhone again.")
        case HouseholdDevicePairingError.networkUnavailable:
            return String(localized: "The Mac is unreachable. Keep both devices on the same LAN or Tailscale.")
        default:
            return String(localized: "I couldn't approve this iPhone. Try again.")
        }
    }
}
