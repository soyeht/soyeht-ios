import CryptoKit
import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class JoinRequestConfirmationFailureViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBiometricCancelRevertsQueueEntryAndKeepsCardPending() async throws {
        let envelope = try makeEnvelope()
        let queue = try await enqueuedQueue(for: envelope)
        let submitCalls = FailureCallCounter()
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { _, _ in
                throw OperatorAuthorizationSignerError.biometryCanceled
            },
            submitAction: { _, _ in
                await submitCalls.increment()
            }
        )

        await viewModel.confirm()

        let queueState = await queue.state(forIdempotencyKey: envelope.idempotencyKey)
        let submitCallCount = await submitCalls.currentValue()
        XCTAssertEqual(viewModel.state, .pending)
        XCTAssertEqual(viewModel.lastNonTerminalError, .biometricCancel)
        XCTAssertEqual(
            viewModel.nonTerminalErrorMessage,
            JoinRequestConfirmationViewModel.localizedMessage(for: .biometricCancel)
        )
        XCTAssertTrue(viewModel.isConfirmEnabled)
        XCTAssertEqual(queueState, .pending)
        XCTAssertEqual(submitCallCount, 0)
    }

    func testBiometricLockoutRevertsQueueEntryAndKeepsCardPending() async throws {
        let envelope = try makeEnvelope()
        let queue = try await enqueuedQueue(for: envelope)
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { _, _ in
                throw OperatorAuthorizationSignerError.biometryLockout
            }
        )

        await viewModel.confirm()

        let queueState = await queue.state(forIdempotencyKey: envelope.idempotencyKey)
        XCTAssertEqual(viewModel.state, .pending)
        XCTAssertEqual(viewModel.lastNonTerminalError, .biometricLockout)
        XCTAssertEqual(
            viewModel.nonTerminalErrorMessage,
            JoinRequestConfirmationViewModel.localizedMessage(for: .biometricLockout)
        )
        XCTAssertTrue(viewModel.isConfirmEnabled)
        XCTAssertEqual(queueState, .pending)
    }

    func testNetworkDropOnSubmitFailsAndClearsQueueEntry() async throws {
        let envelope = try makeEnvelope()
        let queue = try await enqueuedQueue(for: envelope)
        let signCalls = FailureCallCounter()
        let submitCalls = FailureCallCounter()
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { _, cursor in
                await signCalls.increment()
                return Self.authorization(cursor: cursor)
            },
            submitAction: { _, _ in
                await submitCalls.increment()
                throw URLError(.networkConnectionLost)
            }
        )

        await viewModel.confirm()

        let queueContainsEnvelope = await queue.contains(idempotencyKey: envelope.idempotencyKey)
        let signCallCount = await signCalls.currentValue()
        let submitCallCount = await submitCalls.currentValue()
        XCTAssertEqual(viewModel.state, .failed(.networkDrop))
        XCTAssertEqual(
            viewModel.failureMessage,
            JoinRequestConfirmationViewModel.localizedMessage(for: .networkDrop)
        )
        XCTAssertFalse(queueContainsEnvelope)
        XCTAssertEqual(signCallCount, 1)
        XCTAssertEqual(submitCallCount, 1)
    }

    func testHouseholdMismatchFailsAndDoesNotSubmit() async throws {
        let envelope = try makeEnvelope(householdId: "hh_wrong")
        let queue = try await enqueuedQueue(for: envelope)
        let submitCalls = FailureCallCounter()
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { _, _ in
                throw OperatorAuthorizationSignerError.householdMismatch
            },
            submitAction: { _, _ in
                await submitCalls.increment()
            }
        )

        await viewModel.confirm()

        let queueContainsEnvelope = await queue.contains(idempotencyKey: envelope.idempotencyKey)
        let submitCallCount = await submitCalls.currentValue()
        XCTAssertEqual(viewModel.state, .failed(.hhMismatch))
        XCTAssertEqual(
            viewModel.failureMessage,
            JoinRequestConfirmationViewModel.localizedMessage(for: .hhMismatch)
        )
        XCTAssertFalse(queueContainsEnvelope)
        XCTAssertEqual(submitCallCount, 0)
    }

    func testFingerprintRegenerationDriftFailsAndClearsQueueEntry() async throws {
        let originalEnvelope = try makeEnvelope(machineKeySeed: 0x42)
        let refreshedEnvelope = try makeEnvelope(machineKeySeed: 0x43)
        let queue = try await enqueuedQueue(for: originalEnvelope)
        let wordlist = try BIP39Wordlist()
        let viewModel = try makeViewModel(
            envelope: originalEnvelope,
            queue: queue,
            wordlist: wordlist,
            signAction: { claimed, _ in
                let originalWords = try OperatorFingerprint
                    .derive(machinePublicKey: claimed.machinePublicKey, wordlist: wordlist)
                    .words
                let refreshedWords = try OperatorFingerprint
                    .derive(machinePublicKey: refreshedEnvelope.machinePublicKey, wordlist: wordlist)
                    .words
                XCTAssertNotEqual(originalWords, refreshedWords)
                throw MachineJoinError.derivationDrift
            }
        )

        await viewModel.confirm()

        let queueContainsEnvelope = await queue.contains(idempotencyKey: originalEnvelope.idempotencyKey)
        XCTAssertEqual(viewModel.state, .failed(.derivationDrift))
        XCTAssertEqual(
            viewModel.failureMessage,
            JoinRequestConfirmationViewModel.localizedMessage(for: .derivationDrift)
        )
        XCTAssertFalse(queueContainsEnvelope)
    }

    private func makeViewModel(
        envelope: JoinRequestEnvelope,
        queue: JoinRequestQueue,
        wordlist: BIP39Wordlist? = nil,
        signAction: @escaping JoinRequestConfirmationViewModel.SignAction = { _, cursor in
            authorization(cursor: cursor)
        },
        submitAction: @escaping JoinRequestConfirmationViewModel.SubmitAction = { _, _ in }
    ) throws -> JoinRequestConfirmationViewModel {
        try JoinRequestConfirmationViewModel(
            envelope: envelope,
            cursor: 41,
            queue: queue,
            wordlist: try wordlist ?? BIP39Wordlist(),
            nowProvider: { self.now },
            signAction: signAction,
            submitAction: submitAction
        )
    }

    private func enqueuedQueue(for envelope: JoinRequestEnvelope) async throws -> JoinRequestQueue {
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope, cursor: 0)
        return queue
    }

    private func makeEnvelope(
        householdId: String = "hh_test",
        machineKeySeed: UInt8 = 0x42,
        ttlUnix: UInt64? = nil
    ) throws -> JoinRequestEnvelope {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: machineKeySeed, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let hostname = "studio.local"
        let platform = "macos"
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation
        return JoinRequestEnvelope(
            householdId: householdId,
            machinePublicKey: publicKey,
            nonce: nonce,
            rawHostname: hostname,
            rawPlatform: platform,
            candidateAddress: "100.64.1.5:8443",
            ttlUnix: ttlUnix ?? UInt64(now.timeIntervalSince1970) + 240,
            challengeSignature: signature,
            transportOrigin: .bonjourShortcut,
            receivedAt: now
        )
    }

    nonisolated private static func authorization(cursor: UInt64) -> OperatorAuthorizationResult {
        OperatorAuthorizationResult(
            approvalSignature: Data(repeating: 0xAB, count: 64),
            outerBody: HouseholdCBOR.ownerApprovalBody(
                cursor: cursor,
                approvalSignature: Data(repeating: 0xAB, count: 64)
            ),
            signedContext: Data([0xA0]),
            cursor: cursor,
            timestamp: 1_700_000_001
        )
    }
}

actor FailureCallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}
