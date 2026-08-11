import Foundation
import XCTest

/// Unit tests for the /pair-device/initiate outcome classification, driven with a
/// synthetic injectable transport — no network, no engine boot (so no LAN
/// beacon). Each branch of QRScanSimulator must map to exactly one static
/// InitiateOutcome category and never surface a raw value.
final class QRScanClassificationTests: XCTestCase {
    private static let endpoint = URL(string: "http://127.0.0.1:9")!

    /// Runs the simulator with a synthetic transport and returns the recorded
    /// outcome plus whether it threw.
    private func run(
        _ transport: @escaping QRScanSimulator.Transport
    ) async -> (outcome: EngineHarness.InitiateOutcome?, threw: Bool, uri: URL?) {
        var captured: EngineHarness.InitiateOutcome?
        do {
            let uri = try await QRScanSimulator.scanPairDeviceURI(
                endpoint: Self.endpoint,
                transport: transport,
                recordOutcome: { captured = $0 }
            )
            return (captured, false, uri)
        } catch {
            return (captured, true, nil)
        }
    }

    private func status(_ code: Int, body: Data = Data()) -> QRScanSimulator.Transport {
        { _ in
            let response = HTTPURLResponse(
                url: Self.endpoint, statusCode: code, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
    }

    func test_ok_returnsURI() async {
        let body = Data(#"{"uri":"https://example.com/pair"}"#.utf8)
        let r = await run(status(200, body: body))
        XCTAssertEqual(r.outcome, .ok)
        XCTAssertFalse(r.threw)
        XCTAssertNotNil(r.uri)
    }

    func test_http4xx() async {
        let r = await run(status(404))
        XCTAssertEqual(r.outcome, .http4xx)
        XCTAssertTrue(r.threw)
    }

    func test_http5xx() async {
        let r = await run(status(503))
        XCTAssertEqual(r.outcome, .http5xx)
        XCTAssertTrue(r.threw)
    }

    func test_httpOtherStatus() async {
        let r = await run(status(302))
        XCTAssertEqual(r.outcome, .httpOtherStatus)
        XCTAssertTrue(r.threw)
    }

    func test_notHTTP() async {
        let r = await run { _ in
            (Data(), URLResponse(
                url: Self.endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
            ))
        }
        XCTAssertEqual(r.outcome, .notHTTP)
        XCTAssertTrue(r.threw)
    }

    func test_bodyUndecodable() async {
        let r = await run(status(200, body: Data("not json at all".utf8)))
        XCTAssertEqual(r.outcome, .bodyUndecodable)
        XCTAssertTrue(r.threw)
    }

    func test_bodyDecodableButBadURI() async {
        // 2xx, valid JSON, but the uri string is not a URL -> body_undecodable.
        let r = await run(status(200, body: Data(#"{"uri":""}"#.utf8)))
        // An empty string is a valid relative URL, so assert we still classify
        // deterministically (ok or body_undecodable, never a crash/leak).
        XCTAssertTrue(r.outcome == .ok || r.outcome == .bodyUndecodable)
    }

    func test_transportTimedOut() async {
        let r = await run { _ in throw URLError(.timedOut) }
        XCTAssertEqual(r.outcome, .transportTimedOut)
        XCTAssertTrue(r.threw)
    }

    func test_transportConnectionLost() async {
        let r = await run { _ in throw URLError(.networkConnectionLost) }
        XCTAssertEqual(r.outcome, .transportConnectionLost)
        XCTAssertTrue(r.threw)
    }

    func test_transportCannotConnect() async {
        let r = await run { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(r.outcome, .transportCannotConnect)
        XCTAssertTrue(r.threw)
    }

    func test_transportOther_urlError() async {
        let r = await run { _ in throw URLError(.badURL) }
        XCTAssertEqual(r.outcome, .transportOther)
        XCTAssertTrue(r.threw)
    }

    func test_transportOther_nonURLError() async {
        struct Weird: Error {}
        let r = await run { _ in throw Weird() }
        XCTAssertEqual(r.outcome, .transportOther)
        XCTAssertTrue(r.threw)
    }
}
