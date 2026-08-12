import Foundation
import XCTest
@testable import SoyehtCore

/// A1 EXPERIMENT teeth (no network, no engine boot): the 120 s budget override
/// binds to EXACTLY the `POST /bootstrap/initialize` leg of the recording
/// transport and to nothing else, while the wrapper's record/rethrow/return
/// semantics stay untouched.
final class InitializeTimeoutExperimentTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:9")!

    private func request(_ method: String, _ path: String, timeout: TimeInterval? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.httpMethod = method
        if let timeout { r.timeoutInterval = timeout }
        return r
    }

    /// Runs one request through the recording wrapper against a capturing
    /// underlying and returns the request the underlying actually received.
    private func captured(_ request: URLRequest) async throws -> URLRequest {
        let recorder = EngineHarness.InitializeOutcomeRecorder()
        let box = CapturedRequestBox()
        let transport = EngineHarness.recordingInitializeTransport(
            underlying: { req in
                box.store(req)
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            recorder: recorder
        )
        _ = try await transport(request)
        // Hard failure, never a skip: "underlying was never called" is exactly
        // the wiring loss these teeth exist to catch.
        return try XCTUnwrap(box.take(), "underlying was never called")
    }

    // Tooth 1: the POST initialize leg reaches the underlying with 120 s.
    func test_initializePOST_reachesUnderlyingWith120s() async throws {
        let got = try await captured(request("POST", "/bootstrap/initialize"))
        XCTAssertEqual(got.timeoutInterval, 120)
    }

    // Tooth 2: the status GET keeps its original timeout — both the URLRequest
    // default and an explicit custom value.
    func test_statusGET_keepsOriginalTimeout() async throws {
        let def = try await captured(request("GET", "/bootstrap/status"))
        XCTAssertEqual(def.timeoutInterval, URLRequest(url: base).timeoutInterval)
        XCTAssertNotEqual(def.timeoutInterval, 120)
        let custom = try await captured(request("GET", "/bootstrap/status", timeout: 17))
        XCTAssertEqual(custom.timeoutInterval, 17)
    }

    // Tooth 3: near-identical method/path pairs get NO override.
    func test_nearMisses_noOverride() async throws {
        let nearMisses: [(String, String)] = [
            ("GET", "/bootstrap/initialize"),          // method differs
            ("POST", "/bootstrap/initialized"),        // suffix-extended path
            ("POST", "/bootstrap/initialize/"),        // trailing slash
            ("POST", "/x/bootstrap/initialize"),       // prefixed path
            ("POST", "/api/v1/bootstrap/initialize"),  // prefixed path
        ]
        for (method, path) in nearMisses {
            let got = try await captured(request(method, path, timeout: 17))
            XCTAssertEqual(got.timeoutInterval, 17, "override leaked onto \(method) \(path)")
        }
    }

    // Tooth 4: an underlying error on the overridden leg is classified and
    // rethrown unchanged (the same URLError code reaches the caller).
    func test_underlyingError_rethrownUnchanged() async {
        let recorder = EngineHarness.InitializeOutcomeRecorder()
        let transport = EngineHarness.recordingInitializeTransport(
            underlying: { _ in throw URLError(.timedOut) }, recorder: recorder
        )
        do {
            _ = try await transport(request("POST", "/bootstrap/initialize"))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(recorder.snapshot(), .transportTimedOut)
    }

    // Tooth 5: a returned response comes back byte-identically (same data
    // bytes, same response instance) and records transport_returned.
    func test_response_returnsByteIdentically() async throws {
        let recorder = EngineHarness.InitializeOutcomeRecorder()
        let payload = Data([0x00, 0xFF, 0x10, 0x7F])
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = EngineHarness.recordingInitializeTransport(
            underlying: { _ in (payload, response) }, recorder: recorder
        )
        let (data, got) = try await transport(request("POST", "/bootstrap/initialize"))
        XCTAssertEqual(data, payload)
        XCTAssertTrue(got === response)
        XCTAssertEqual(recorder.snapshot(), .transportReturned)
    }
}

/// Lock-guarded capture box so the `@Sendable` underlying can store the request.
private final class CapturedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    func store(_ r: URLRequest) { lock.lock(); value = r; lock.unlock() }
    func take() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return value }
}
