import Foundation
import Testing
@testable import SoyehtCore

@Suite("PlainHTTPTransactionDiagnostics")
struct PlainHTTPTransactionDiagnosticsTests {
    /// A path that only ever reports `.waiting` must be ended by the timeout,
    /// not by the first `.waiting` callback, and the error it throws must
    /// carry the `NWError` text.
    ///
    /// Measured on this machine: a TCP connect to a closed loopback port sits
    /// in `.waiting(POSIXErrorCode(rawValue: 61): Connection refused)` and
    /// never reaches `.failed`. That is the same state a Tailscale-over-5G
    /// path flaps through while the interface comes up — treating it as fatal
    /// turned a recoverable flap into a bare "I couldn't connect this time"
    /// with nothing said about why.
    @Test func aWaitingPathRunsToTheTimeoutAndReportsWhyItWaited() async throws {
        // Port 9 (discard) is closed on macOS; 0.4 s keeps the test fast while
        // still being an order of magnitude above the ~1 ms first `.waiting`.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/pair-machine/local/anchor")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.4
        request.httpBody = Data([0xA1])

        let started = Date()
        do {
            _ = try await PlainHTTPTransaction(request: request).perform()
            Issue.record("Expected the transaction to fail")
        } catch let error as PlainHTTPTransportError {
            #expect(error.stage == .waitingTimeout)
            #expect(error.detail?.contains("Connection refused") == true)
            #expect(error.description.contains("stage=waitingTimeout"))
        }
        // Proves the first `.waiting` did not end the transaction.
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    /// `LocalAnchorClient` still collapses the transport's account into
    /// `.networkDrop`, so the retry policy and the operator-facing message are
    /// unchanged by the richer error.
    @Test func theAnchorClientStillReportsAWaitingPathAsARetryableNetworkDrop() async throws {
        let client = LocalAnchorClient(
            transport: { _ in
                throw PlainHTTPTransportError(stage: .waitingTimeout, detail: "POSIXErrorCode(rawValue: 61): Connection refused")
            },
            sleeper: { _ in }
        )

        await #expect(throws: MachineJoinError.networkDrop) {
            try await client.pinAnchor(
                candidateAddress: "127.0.0.1:8099",
                anchorSecret: Data(repeating: 0x11, count: 32),
                householdId: "hh_test",
                householdPublicKey: Data(repeating: 0x02, count: 33)
            )
        }
    }
}
