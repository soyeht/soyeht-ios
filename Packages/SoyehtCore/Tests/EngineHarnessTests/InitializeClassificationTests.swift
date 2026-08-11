import Foundation
import XCTest
@testable import SoyehtCore

/// Classification of the BootstrapInitializeClient.initialize transport outcome:
/// per-category unit tests, plus the end-to-end wiring tooth that drives the REAL
/// initialize path with an injected transport (no network, no engine boot).
final class InitializeClassificationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9")!

    // ── per-category unit tests ───────────────────────────────────────────────
    func test_classify_perCategory() {
        typealias O = EngineHarness.InitializeOutcome
        XCTAssertEqual(O.classify(transportError: URLError(.timedOut)), .transportTimedOut)
        XCTAssertEqual(O.classify(transportError: URLError(.networkConnectionLost)), .transportConnectionLost)
        XCTAssertEqual(O.classify(transportError: URLError(.cannotConnectToHost)), .transportCannotConnect)
        XCTAssertEqual(O.classify(transportError: URLError(.badServerResponse)), .transportBadServerResponse)
        XCTAssertEqual(O.classify(transportError: URLError(.badURL)), .transportOther)
        struct Weird: Error {}
        XCTAssertEqual(O.classify(transportError: Weird()), .transportOther)
    }

    func test_levels() {
        XCTAssertEqual(EngineHarness.InitializeOutcome.notObserved.level, "INFO")
        XCTAssertEqual(EngineHarness.InitializeOutcome.transportReturned.level, "INFO")
        XCTAssertEqual(EngineHarness.InitializeOutcome.transportBadServerResponse.level, "WARN")
        XCTAssertEqual(EngineHarness.InitializeOutcome.transportTimedOut.level, "WARN")
    }

    func test_wrapper_returnedResponse_recordsTransportReturned() async throws {
        // A returning transport records `transport_returned` — NOT any success
        // claim about status/decode/initialize.
        let recorder = EngineHarness.InitializeOutcomeRecorder()
        let transport = EngineHarness.recordingInitializeTransport(
            underlying: { _ in
                (Data("x".utf8), HTTPURLResponse(url: self.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            recorder: recorder
        )
        _ = try await transport(URLRequest(url: endpoint))
        XCTAssertEqual(recorder.snapshot(), .transportReturned)
    }

    // ── end-to-end wiring tooth: the REAL initialize path, two DIFFERENT concrete
    //    categories. Removing the recorder call, or collapsing classify() to a
    //    constant, makes at least one assertion RED. ──
    private func runRealInitialize(
        throwing error: URLError
    ) async -> (recorded: EngineHarness.InitializeOutcome, caller: Error?) {
        let recorder = EngineHarness.InitializeOutcomeRecorder()
        let transport = EngineHarness.recordingInitializeTransport(
            underlying: { _ in throw error }, recorder: recorder
        )
        let client = BootstrapInitializeClient(baseURL: endpoint, transport: transport)
        var caller: Error?
        do { _ = try await client.initialize(name: "HARNESS", claimToken: nil) }
        catch { caller = error }
        return (recorder.snapshot(), caller)
    }

    func test_realInitialize_badServerResponse_classifiesBeforeCollapse() async {
        let r = await runRealInitialize(throwing: URLError(.badServerResponse))
        XCTAssertEqual(r.caller as? BootstrapError, .networkDrop)      // (a) behavior preserved
        XCTAssertEqual(r.recorded, .transportBadServerResponse)        // (b) concrete raw category, pre-collapse
        XCTAssertEqual(r.recorded.level, "WARN")                       // (c) WARN
        XCTAssertNotEqual(r.recorded, .notObserved)                    // (d) not the default
    }

    func test_realInitialize_timedOut_distinctCategory() async {
        let r = await runRealInitialize(throwing: URLError(.timedOut))
        XCTAssertEqual(r.caller as? BootstrapError, .networkDrop)
        XCTAssertEqual(r.recorded, .transportTimedOut)                 // DIFFERENT category -> no hardcode
        XCTAssertEqual(r.recorded.level, "WARN")
    }
}
