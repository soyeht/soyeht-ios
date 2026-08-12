import CryptoKit
import Foundation
import XCTest
@testable import SoyehtCore

/// No-network proofs for the pairing-URI consumption boundary: both
/// engine-booting cases build their `PairDeviceQR` EXACTLY from
/// `BootstrapInitializeResponse.pairQrUri` (the production onboarding boundary)
/// and contact no other endpoint for it.
final class PairQRConsumptionTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:9")!

    private struct Fixture {
        let hhPub: Data
        let hhId: String
        let nonce: Data
        let fingerprint: Data
        let uri: String
        let initResponse: Data
        let statusResponse: Data
    }

    private func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A semantically valid pair-device URI plus the CBOR bodies the REAL
    /// `BootstrapInitializeClient.initialize` needs (it pre-flights
    /// `/bootstrap/status` on the same injected transport before the POST).
    private func makeFixture(pairQrUri: String? = nil) throws -> Fixture {
        let hhPub = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let nonce = Data(repeating: 0x11, count: 32)
        let fingerprint = Data(repeating: 0xAB, count: 32)
        // `ttl`/`exp` is an ABSOLUTE epoch timestamp to the parser
        // (PairDeviceQR treats both as `timeIntervalSince1970`).
        let expiry = Int(Date().timeIntervalSince1970) + 600
        let uri = pairQrUri
            ?? "soyeht://household/pair-device?v=1&hh_pub=\(b64url(hhPub))&nonce=\(b64url(nonce))"
            + "&ttl=\(expiry)&house_name=Home&crit=m_cert_fp&m_cert_fp=\(b64url(fingerprint))"
        let initResponse = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "hh_id": .text(hhId),
            "hh_pub": .bytes(hhPub),
            "pair_qr_uri": .text(uri),
        ]))
        let statusResponse = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "state": .text("uninitialized"),
            "engine_version": .text(EngineCompat.minSupportedEngineVersion),
            "platform": .text("mac"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
            "owner_display_name": .null,
            "hh_id": .null,
            "hh_pub": .null,
        ]))
        return Fixture(
            hhPub: hhPub, hhId: hhId, nonce: nonce, fingerprint: fingerprint,
            uri: uri, initResponse: initResponse, statusResponse: statusResponse
        )
    }

    /// FAIL-CLOSED fixture transport: it serves EXACTLY the pre-flight status
    /// GET and the initialize POST and throws on any other (method, path) pair
    /// — so an unexpected request can never be silently absorbed as
    /// "initialize". Records every request so a test can assert the helper's
    /// whole network surface as an exact ORDERED array of (method, path) pairs.
    private func routingTransport(
        _ fixture: Fixture, log: RequestLog? = nil, failInitializePOST: Bool = false
    ) -> BootstrapInitializeClient.TransportPerform {
        let statusBody = fixture.statusResponse
        let initBody = fixture.initResponse
        return { request in
            log?.append(request)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/cbor"]
            )!
            let method = request.httpMethod
            let path = request.url?.path
            if method == "GET", path == BootstrapStatusClient.path {
                return (statusBody, http)
            }
            if method == "POST", path == "/bootstrap/initialize" {
                if failInitializePOST { throw URLError(.timedOut) }
                return (initBody, http)
            }
            throw TransportFixtureError.unexpectedRequest(method: method, path: path)
        }
    }

    /// The exact expected network surface of the helper, in order.
    private var expectedSurface: [[String]] {
        [["GET", BootstrapStatusClient.path], ["POST", "/bootstrap/initialize"]]
    }

    private func requestPairs(_ log: RequestLog) -> [[String]] {
        log.snapshot().map { [$0.httpMethod ?? "", $0.url?.path ?? ""] }
    }

    // ── P1: a valid URI arrives at the consumer as EXACTLY the response's
    //    String, and the parsed QR preserves every semantic field. (No claim
    //    about URL re-normalization beyond what is measured here.) ──
    func test_P1_validURI_deliveredIntactAndFieldsSurvive() async throws {
        let fixture = try makeFixture()
        let consumed = ConsumedURIBox()
        let (stage, qr) = try await PairQRConsumption.initializeAndScanPairQR(
            baseURL: base,
            transport: routingTransport(fixture),
            name: "HARNESS-P1",
            parse: { uri in
                consumed.record(uri)
                return try PairQRConsumption.parsePairQR(from: uri)
            }
        )
        XCTAssertEqual(consumed.take(), fixture.uri, "consumer must receive the response's exact String")
        XCTAssertEqual(stage.pairQrUri, fixture.uri)
        XCTAssertEqual(qr.householdPublicKey, fixture.hhPub)
        XCTAssertEqual(qr.householdId, fixture.hhId)
        XCTAssertEqual(qr.nonce, fixture.nonce)
        XCTAssertEqual(qr.machineCertFingerprint, fixture.fingerprint)
        XCTAssertEqual(qr.householdName, "Home")
        XCTAssertEqual(qr.criticalFields, ["m_cert_fp"])
        XCTAssertGreaterThan(qr.expiresAt, Date())
        // The intra-response consistency the engine cases rely on.
        XCTAssertEqual(qr.householdPublicKey, stage.hhPub)
    }

    // ── P2, boundary 1: the engine's documented empty-string degradation is
    //    not a URL on this platform — the helper fails closed BEFORE the
    //    parser, and nothing downstream (confirm) can run. ──
    func test_P2_emptyURI_failsClosedAtURLBoundary() async throws {
        XCTAssertNil(URL(string: ""), "platform premise: the empty string is not a URL")
        let fixture = try makeFixture(pairQrUri: "")
        do {
            _ = try await PairQRConsumption.initializeAndScanPairQR(
                baseURL: base, transport: routingTransport(fixture), name: "HARNESS-P2A"
            )
            XCTFail("an empty pairQrUri must fail closed")
        } catch let error as PairQRConsumptionError {
            XCTAssertEqual(error, .uriNotParseableAsURL)
        }
    }

    // ── P2, boundary 2: a well-formed but wrong-scheme URI IS a URL — the
    //    rejection must come from the REAL parser, as `.unsupportedScheme`. ──
    func test_P2_httpsURI_failsClosedAtParserBoundary() async throws {
        let https = "https://example.com/pair"
        XCTAssertNotNil(URL(string: https), "platform premise: an https URI is a URL")
        let fixture = try makeFixture(pairQrUri: https)
        do {
            _ = try await PairQRConsumption.initializeAndScanPairQR(
                baseURL: base, transport: routingTransport(fixture), name: "HARNESS-P2B"
            )
            XCTFail("a non-soyeht scheme must fail closed at the parser")
        } catch let error as PairDeviceQRError {
            XCTAssertEqual(error, .unsupportedScheme)
        }
    }

    // ── P3: the helper's whole network surface is EXACTLY one status
    //    pre-flight GET followed by one initialize POST — asserted as an
    //    ordered array of (method, path) pairs, so a duplicate, a reordering,
    //    a wrong method, or any extra route (including initiate) is RED.
    //    (The forbidden path is assembled from fragments so this file cannot
    //    satisfy the structural scan below by containing the literal.) ──
    func test_P3_helperNetworkSurface_isExactlyStatusGETThenInitializePOST() async throws {
        let fixture = try makeFixture()
        let log = RequestLog()
        _ = try await PairQRConsumption.initializeAndScanPairQR(
            baseURL: base, transport: routingTransport(fixture, log: log), name: "HARNESS-P3"
        )
        XCTAssertEqual(requestPairs(log), expectedSurface,
                       "the helper's surface must be exactly [status GET, initialize POST], in order")
        let forbiddenPath = ["/api", "/v1", "/household", "/pair-device", "/initiate"].joined()
        for request in log.snapshot() {
            XCTAssertNotEqual(request.url?.path, forbiddenPath, "the initiate route was contacted")
        }
        // The fixture transport itself fails CLOSED on any unexpected pair —
        // a permissive fixture would hollow out the surface claim above.
        var stray = URLRequest(url: base.appending(path: "/bootstrap/initialize"))
        stray.httpMethod = "PUT"
        do {
            _ = try await routingTransport(fixture)(stray)
            XCTFail("the fixture transport must reject an unexpected (method, path) pair")
        } catch is TransportFixtureError {
            // expected: fail-closed
        }
    }

    private enum TargetScanError: Error {
        case enumeratorUnavailable
        case enumerationFailed(underlying: Error)
        case symlinkInsideTarget(String)
    }

    /// RECURSIVE, FAIL-CLOSED enumeration of every `.swift` file under `root`
    /// — SwiftPM compiles nested subdirectories into the target, so a
    /// non-recursive listing would be blind to a reintroduction in a
    /// subfolder. An enumeration error throws (never "file silently omitted"),
    /// and ANY symlink inside the root — file or directory — throws instead of
    /// being followed or silently skipped, so the scan can never escape the
    /// root nor under-report it. The recursion itself is proven by
    /// `test_P3_enumerationIsRecursive_provenOnSyntheticTree`.
    private func swiftFiles(under root: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw TargetScanError.enumeratorUnavailable
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw TargetScanError.symlinkInsideTarget(url.lastPathComponent)
            }
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        if let enumerationError {
            throw TargetScanError.enumerationFailed(underlying: enumerationError)
        }
        return files
    }

    // ── P3, structural: the initiate path literal exists NOWHERE in the test
    //    target's source, including nested subdirectories. A mutant that
    //    reintroduces the call — at the top level or in a subfolder — flips
    //    this RED. ──
    func test_P3_structural_initiateLiteralAbsentFromTarget() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = ["/api", "/v1", "/household", "/pair-device", "/initiate"].joined()
        let files = try swiftFiles(under: directory)
        XCTAssertGreaterThan(files.count, 3, "target enumeration premise")
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                content.contains(needle),
                "initiate path literal present in \(file.lastPathComponent)"
            )
        }
    }

    // ── P3, recursion tooth (synthetic tree in a TEMP directory — no
    //    permanent fixture): the scanner reaches a nested `.swift` AND the
    //    same detection logic flags an assembled needle planted there — a
    //    positive control of reach + detection in one. A mutant reverting to a
    //    non-recursive listing flips this RED. ──
    func test_P3_enumerationIsRecursive_provenOnSyntheticTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-recursion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("sub/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let needle = ["/api", "/v1", "/household", "/pair-device", "/initiate"].joined()
        try Data("// benign top-level file".utf8)
            .write(to: root.appendingPathComponent("top.swift"))
        try Data("let route = \"\(needle)\"".utf8)
            .write(to: nested.appendingPathComponent("poisoned.swift"))
        try Data("not swift".utf8).write(to: nested.appendingPathComponent("ignored.txt"))

        let found = try swiftFiles(under: root)
        XCTAssertEqual(found.map(\.lastPathComponent).sorted(), ["poisoned.swift", "top.swift"],
                       "the scan must see nested .swift files and only .swift files")
        // Detection positive control: the SAME logic the real scan uses must
        // flag the planted nested occurrence.
        let flagged = try found.filter {
            try String(contentsOf: $0, encoding: .utf8).contains(needle)
        }
        XCTAssertEqual(flagged.map(\.lastPathComponent), ["poisoned.swift"],
                       "the planted nested needle must be detected")
    }

    // ── P3, symlink + missing-root fail-closed teeth: the scanner THROWS on
    //    ANY symlink inside the root — a `.swift` FILE symlink or a DIRECTORY
    //    symlink to an external tree — never returning a (partial) list, and
    //    a missing root fails closed too. Each filesystem premise is asserted
    //    with `attributesOfItem` (which does not follow links — a mechanism
    //    independent of the scanner) BEFORE the scanner is judged. ──
    func test_P3_scannerFailsClosed_onSymlinksAndMissingRoot() throws {
        let fm = FileManager.default

        func assertIsSymlink(_ url: URL, _ label: String) throws {
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeSymbolicLink, "premise: \(label) was not created as a symlink")
        }

        // (a) FILE symlink: a real .swift next to a symlinked .swift that
        //     points at a file OUTSIDE the root.
        let rootA = fm.temporaryDirectory
            .appendingPathComponent("p3-symfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: rootA) }
        try fm.createDirectory(at: rootA, withIntermediateDirectories: true)
        let outsideFile = fm.temporaryDirectory
            .appendingPathComponent("p3-outside-\(UUID().uuidString).swift")
        defer { try? fm.removeItem(at: outsideFile) }
        try Data("// outside the root".utf8).write(to: outsideFile)
        try Data("// real".utf8).write(to: rootA.appendingPathComponent("real.swift"))
        let fileLink = rootA.appendingPathComponent("linked.swift")
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: outsideFile)
        try assertIsSymlink(fileLink, "file symlink")
        do {
            let files = try swiftFiles(under: rootA)
            XCTFail("a file symlink must throw, not return \(files.count) files")
        } catch TargetScanError.symlinkInsideTarget(let component) {
            XCTAssertEqual(component, "linked.swift")
        }

        // (b) DIRECTORY symlink to an external tree that holds a .swift.
        let rootB = fm.temporaryDirectory
            .appendingPathComponent("p3-symdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: rootB) }
        let externalTree = fm.temporaryDirectory
            .appendingPathComponent("p3-external-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: externalTree) }
        try fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalTree, withIntermediateDirectories: true)
        try Data("// external".utf8).write(to: externalTree.appendingPathComponent("external.swift"))
        let dirLink = rootB.appendingPathComponent("linkdir")
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: externalTree)
        try assertIsSymlink(dirLink, "directory symlink")
        do {
            let files = try swiftFiles(under: rootB)
            XCTFail("a directory symlink must throw, not return \(files.count) files")
        } catch TargetScanError.symlinkInsideTarget(let component) {
            XCTAssertEqual(component, "linkdir")
        }

        // (c) missing root: fail-closed with the scanner's own error type —
        //     never an empty list.
        let missing = fm.temporaryDirectory
            .appendingPathComponent("p3-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            let files = try swiftFiles(under: missing)
            XCTFail("a missing root must fail closed, not return \(files.count) files")
        } catch let error as TargetScanError {
            _ = error // enumeratorUnavailable or enumerationFailed — fail-closed either way
        }
    }

    // ── P4: the INITIALIZE POST leg itself failing prevents any URI
    //    consumption — the pre-flight GET succeeds, the POST is genuinely
    //    attempted (proven by the exact ordered surface), the parser seam is
    //    never consulted, and the caller sees the client's real error. ──
    func test_P4_initializePOSTFailure_preventsParserInvocation() async throws {
        let fixture = try makeFixture()
        let log = RequestLog()
        let consumed = ConsumedURIBox()
        do {
            _ = try await PairQRConsumption.initializeAndScanPairQR(
                baseURL: base,
                transport: routingTransport(fixture, log: log, failInitializePOST: true),
                name: "HARNESS-P4",
                parse: { uri in
                    consumed.record(uri)
                    return try PairQRConsumption.parsePairQR(from: uri)
                }
            )
            XCTFail("an initialize POST failure must propagate")
        } catch {
            XCTAssertEqual(error as? BootstrapError, .networkDrop)
        }
        XCTAssertEqual(requestPairs(log), expectedSurface,
                       "the POST leg itself must have been reached and attempted")
        XCTAssertNil(consumed.take(), "the parser must not run when the initialize POST fails")
    }

    // ── P4 supplementary (NOT the initialize-failure receipt): the pre-flight
    //    GET failing also gates consumption. ──
    func test_P4b_preflightFailure_alsoPreventsParserInvocation() async throws {
        let consumed = ConsumedURIBox()
        do {
            _ = try await PairQRConsumption.initializeAndScanPairQR(
                baseURL: base,
                transport: { _ in throw URLError(.timedOut) },
                name: "HARNESS-P4B",
                parse: { uri in
                    consumed.record(uri)
                    return try PairQRConsumption.parsePairQR(from: uri)
                }
            )
            XCTFail("a pre-flight failure must propagate")
        } catch {
            XCTAssertEqual(error as? BootstrapError, .networkDrop)
        }
        XCTAssertNil(consumed.take(), "the parser must not run when the pre-flight fails")
    }

    // ── P5: case semantics preserved — status_only never consumes the pairing
    //    URI, both engine cases consume it via the shared helper, and the
    //    long_poll case keeps its GET/PoP/hold/cancel teeth. EVERY window is
    //    closed by the NEXT class symbol — never end-of-file, because an
    //    EOF-open window is satisfied by declarations outside the class (the
    //    shared helper's own declaration lives below it in this file). ──
    func test_P5_caseShapes_statusOnlyNoHelper_longPollKeepsPollTeeth() throws {
        let casesFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("EngineHarnessTests.swift")
        let source = try String(contentsOf: casesFile, encoding: .utf8)
        // Anchor grammar first: each anchor is present EXACTLY once and they
        // appear in declaration order; only then is it valid to slice windows.
        let anchors = [
            "func testBootstrapStatusPassesProductionCompatibilityHandshake",
            "func testInitializeThenConfirmPairsWithSoftwareP256Owner",
            "func testOwnerEventsLongPollAcceptsPoPAndHoldsUntilClientCancellation",
            "private func bootEngine(",
        ]
        var starts: [String.Index] = []
        for anchor in anchors {
            var count = 0
            var first: String.Index?
            var cursor = source.startIndex
            while let hit = source.range(of: anchor, range: cursor..<source.endIndex) {
                count += 1
                if first == nil { first = hit.lowerBound }
                cursor = hit.upperBound
            }
            XCTAssertEqual(count, 1, "anchor must be unique: \(anchor)")
            guard count == 1, let start = first else {
                return XCTFail("anchor grammar broken for: \(anchor)")
            }
            starts.append(start)
        }
        for i in 1..<starts.count {
            XCTAssertLessThan(starts[i - 1], starts[i], "anchors out of declaration order")
        }
        let statusBody = source[starts[0]..<starts[1]]
        XCTAssertFalse(
            statusBody.contains("initializeAndScanPairQR"),
            "status_only must not consume the pairing URI"
        )
        let pairBody = source[starts[1]..<starts[2]]
        XCTAssertTrue(pairBody.contains("initializeAndScanPairQR"))
        let pollBody = source[starts[2]..<starts[3]]
        XCTAssertTrue(
            pollBody.contains("initializeAndScanPairQR"),
            "long_poll must consume via the shared helper (window closed at bootEngine)"
        )
        for tooth in [
            "/api/v1/household/owner-events",
            "Soyeht-PoP v1:",
            "pollTask.cancel()",
            "XCTAssertFalse(completedBeforeCancellation)",
        ] {
            XCTAssertTrue(pollBody.contains(tooth), "long_poll tooth missing: \(tooth)")
        }
    }
}

/// Thrown by the fail-closed fixture transport on any (method, path) pair
/// outside the helper's declared surface.
private enum TransportFixtureError: Error {
    case unexpectedRequest(method: String?, path: String?)
}

/// Lock-guarded single-value box so a `@Sendable` seam can record the consumed URI.
private final class ConsumedURIBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func record(_ uri: String) { lock.lock(); value = uri; lock.unlock() }
    func take() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Lock-guarded request log so a `@Sendable` transport can record all traffic.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
