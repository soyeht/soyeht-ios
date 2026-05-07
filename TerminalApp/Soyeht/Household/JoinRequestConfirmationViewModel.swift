import Foundation
import SoyehtCore

@MainActor
final class JoinRequestConfirmationViewModel: ObservableObject {
    enum State: Equatable {
        case pending
        case authorizing
        case succeeded
        case failed(MachineJoinError)
        case dismissed
    }

    typealias SignAction = @Sendable (JoinRequestEnvelope, UInt64) async throws -> OperatorAuthorizationResult
    typealias SubmitAction = @Sendable (JoinRequestEnvelope, OperatorAuthorizationResult) async throws -> Void
    typealias NowProvider = @Sendable () -> Date

    nonisolated static let biometricReasonLocalizationKey = "household.machineJoin.biometricReason"

    let envelope: JoinRequestEnvelope
    let cursor: UInt64
    let fingerprintWords: [String]
    let biometricReasonKey: String
    let displayHostname: String
    let displayPlatform: String

    @Published private(set) var state: State = .pending
    @Published private(set) var secondsRemaining: Int
    @Published private(set) var lastNonTerminalError: MachineJoinError?

    var isConfirmEnabled: Bool {
        state == .pending && secondsRemaining > 0
    }

    var failureMessage: String? {
        guard case .failed(let error) = state else { return nil }
        return Self.localizedMessage(for: error)
    }

    var nonTerminalErrorMessage: String? {
        lastNonTerminalError.map(Self.localizedMessage(for:))
    }

    private let queue: JoinRequestQueue
    private let signAction: SignAction
    private let submitAction: SubmitAction
    private let nowProvider: NowProvider

    init(
        envelope: JoinRequestEnvelope,
        cursor: UInt64,
        queue: JoinRequestQueue,
        wordlist: BIP39Wordlist,
        nowProvider: @escaping NowProvider = { Date() },
        biometricReasonKey: String = JoinRequestConfirmationViewModel.biometricReasonLocalizationKey,
        signAction: @escaping SignAction,
        submitAction: @escaping SubmitAction
    ) throws {
        self.envelope = envelope
        self.cursor = cursor
        self.queue = queue
        self.nowProvider = nowProvider
        self.biometricReasonKey = biometricReasonKey
        self.signAction = signAction
        self.submitAction = submitAction
        self.fingerprintWords = try OperatorFingerprint
            .derive(machinePublicKey: envelope.machinePublicKey, wordlist: wordlist)
            .words
        self.displayHostname = envelope.displayHostname()
        self.displayPlatform = envelope.displayPlatform()
        self.secondsRemaining = Self.remainingSeconds(until: envelope.ttlUnix, now: nowProvider())
    }

    func updateCountdown(now: Date? = nil) async {
        let current = now ?? nowProvider()
        secondsRemaining = Self.remainingSeconds(until: envelope.ttlUnix, now: current)
        guard secondsRemaining == 0, (state == .pending || state == .authorizing) else { return }
        _ = await queue.pendingEntries(now: current)
        state = .dismissed
    }

    func dismiss() async {
        guard state != .dismissed else { return }
        _ = await queue.dismiss(idempotencyKey: envelope.idempotencyKey)
        state = .dismissed
    }

    func confirm() async {
        guard state == .pending else { return }
        let now = nowProvider()
        await updateCountdown(now: now)
        guard state == .pending else { return }

        guard let claimed = await queue.claim(idempotencyKey: envelope.idempotencyKey, now: now) else {
            state = .dismissed
            return
        }

        state = .authorizing
        lastNonTerminalError = nil
        do {
            let authorization = try await signAction(claimed, cursor)
            try await submitAction(claimed, authorization)
            guard !Task.isCancelled else { return }
            _ = await queue.confirmClaim(idempotencyKey: claimed.idempotencyKey, now: nowProvider())
            state = .succeeded
        } catch let error as MachineJoinError {
            await handleFailure(error, idempotencyKey: claimed.idempotencyKey)
        } catch let error as OperatorAuthorizationSignerError {
            await handleFailure(MachineJoinError(error), idempotencyKey: claimed.idempotencyKey)
        } catch {
            await handleFailure(.networkDrop, idempotencyKey: claimed.idempotencyKey)
        }
    }

    private func handleFailure(
        _ error: MachineJoinError,
        idempotencyKey: String
    ) async {
        switch error {
        case .biometricCancel:
            _ = await queue.revertClaim(
                idempotencyKey: idempotencyKey,
                reason: .biometricCancel,
                now: nowProvider()
            )
            lastNonTerminalError = error
            state = .pending
        case .biometricLockout:
            _ = await queue.revertClaim(
                idempotencyKey: idempotencyKey,
                reason: .biometricLockout,
                now: nowProvider()
            )
            lastNonTerminalError = error
            state = .pending
        default:
            _ = await queue.failClaim(idempotencyKey: idempotencyKey, error: error)
            state = .failed(error)
        }
    }

    private static func remainingSeconds(until ttlUnix: UInt64, now: Date) -> Int {
        let expiry = Date(timeIntervalSince1970: TimeInterval(ttlUnix))
        return max(0, Int(ceil(expiry.timeIntervalSince(now))))
    }

    nonisolated static func localizedMessage(for error: MachineJoinError) -> String {
        String(
            localized: String.LocalizationValue(localizationKey(for: error)),
            bundle: SoyehtCoreResources.bundle
        )
    }

    nonisolated static func localizationKey(for error: MachineJoinError) -> String {
        switch error {
        case .qrInvalid:
            return "household.machineJoin.error.qrInvalid"
        case .qrExpired:
            return "household.machineJoin.error.qrExpired"
        case .hhMismatch:
            return "household.machineJoin.error.hhMismatch"
        case .biometricCancel:
            return "household.machineJoin.error.biometricCancel"
        case .biometricLockout:
            return "household.machineJoin.error.biometricLockout"
        case .macUnreachable:
            return "household.machineJoin.error.macUnreachable"
        case .networkDrop:
            return "household.machineJoin.error.networkDrop"
        case .certValidationFailed:
            return "household.machineJoin.error.certValidationFailed"
        case .gossipDisconnect:
            return "household.machineJoin.error.gossipDisconnect"
        case .protocolViolation:
            return "household.machineJoin.error.protocolViolation"
        case .derivationDrift:
            return "household.machineJoin.error.derivationDrift"
        case .serverError:
            return "household.machineJoin.error.serverError"
        case .signingFailed:
            return "household.machineJoin.error.signingFailed"
        }
    }
}
