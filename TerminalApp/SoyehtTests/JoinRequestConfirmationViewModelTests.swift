import CryptoKit
import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class JoinRequestConfirmationViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCardPresentationDerivesFingerprintAndSafeDisplayFields() async throws {
        let envelope = try makeEnvelope(
            hostname: "studio\u{202E}.local",
            platform: "macos\u{0007}",
            ttlUnix: UInt64(now.timeIntervalSince1970) + 240
        )
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope)

        let viewModel = try makeViewModel(envelope: envelope, queue: queue)
        let expectedWords = try OperatorFingerprint
            .derive(machinePublicKey: envelope.machinePublicKey, wordlist: BIP39Wordlist())
            .words

        XCTAssertEqual(viewModel.state, .pending)
        XCTAssertEqual(viewModel.fingerprintWords, expectedWords)
        XCTAssertEqual(viewModel.fingerprintWords.count, 6)
        XCTAssertEqual(viewModel.displayHostname, "studio.local")
        XCTAssertEqual(viewModel.displayPlatform, "macos\u{FFFD}")
        XCTAssertEqual(viewModel.secondsRemaining, 240)
        XCTAssertEqual(viewModel.biometricReasonKey, "household.machineJoin.biometricReason")
        XCTAssertTrue(viewModel.isConfirmEnabled)
    }

    func testConfirmSignsSubmitsAndConfirmsQueueEntry() async throws {
        let envelope = try makeEnvelope()
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope)
        let signCalls = CallCounter()
        let submitCalls = CallCounter()
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { claimed, cursor in
                XCTAssertEqual(claimed, envelope)
                XCTAssertEqual(cursor, 41)
                await signCalls.increment()
                return Self.authorization(cursor: cursor)
            },
            submitAction: { claimed, authorization in
                XCTAssertEqual(claimed, envelope)
                XCTAssertEqual(authorization.cursor, 41)
                await submitCalls.increment()
            }
        )

        await viewModel.confirm()

        XCTAssertEqual(viewModel.state, .succeeded)
        let queueContainsEnvelope = await queue.contains(idempotencyKey: envelope.idempotencyKey)
        let signCallCount = await signCalls.currentValue()
        let submitCallCount = await submitCalls.currentValue()
        XCTAssertFalse(queueContainsEnvelope)
        XCTAssertEqual(signCallCount, 1)
        XCTAssertEqual(submitCallCount, 1)
    }

    func testConfirmIsIdempotentAcrossDoubleTap() async throws {
        let envelope = try makeEnvelope()
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope)
        let signCalls = CallCounter()
        let viewModel = try makeViewModel(
            envelope: envelope,
            queue: queue,
            signAction: { _, cursor in
                await signCalls.increment()
                try await Task.sleep(nanoseconds: 25_000_000)
                return Self.authorization(cursor: cursor)
            }
        )

        async let first: Void = viewModel.confirm()
        async let second: Void = viewModel.confirm()
        _ = await (first, second)

        XCTAssertEqual(viewModel.state, .succeeded)
        let signCallCount = await signCalls.currentValue()
        XCTAssertEqual(signCallCount, 1)
    }

    func testCountdownExpiryDismissesQueueEntry() async throws {
        let envelope = try makeEnvelope(ttlUnix: UInt64(now.timeIntervalSince1970) + 5)
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope)
        let viewModel = try makeViewModel(envelope: envelope, queue: queue)

        await viewModel.updateCountdown(now: now.addingTimeInterval(6))

        XCTAssertEqual(viewModel.secondsRemaining, 0)
        XCTAssertEqual(viewModel.state, .dismissed)
        let queueContainsEnvelope = await queue.contains(idempotencyKey: envelope.idempotencyKey)
        XCTAssertFalse(queueContainsEnvelope)
    }

    func testMachineJoinErrorsResolveLocalizedMessages() {
        let errors: [MachineJoinError] = [
            .qrInvalid(reason: .challengeSigInvalid),
            .qrExpired,
            .hhMismatch,
            .biometricCancel,
            .biometricLockout,
            .macUnreachable,
            .networkDrop,
            .certValidationFailed(reason: .signatureInvalid),
            .gossipDisconnect,
            .protocolViolation(detail: .unexpectedResponseShape),
            .derivationDrift,
            .serverError(code: "unknown", message: nil),
            .signingFailed
        ]

        for error in errors {
            let key = JoinRequestConfirmationViewModel.localizationKey(for: error)
            let message = JoinRequestConfirmationViewModel.localizedMessage(for: error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertNotEqual(message, key)
        }
    }

    private func makeViewModel(
        envelope: JoinRequestEnvelope,
        queue: JoinRequestQueue,
        signAction: @escaping JoinRequestConfirmationViewModel.SignAction = { _, cursor in
            authorization(cursor: cursor)
        },
        submitAction: @escaping JoinRequestConfirmationViewModel.SubmitAction = { _, _ in }
    ) throws -> JoinRequestConfirmationViewModel {
        try JoinRequestConfirmationViewModel(
            envelope: envelope,
            cursor: 41,
            queue: queue,
            wordlist: BIP39Wordlist(),
            nowProvider: { self.now },
            signAction: signAction,
            submitAction: submitAction
        )
    }

    private func makeEnvelope(
        hostname: String = "studio.local",
        platform: String = "macos",
        ttlUnix: UInt64? = nil
    ) throws -> JoinRequestEnvelope {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation
        return JoinRequestEnvelope(
            householdId: "hh_test",
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

actor CallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}
