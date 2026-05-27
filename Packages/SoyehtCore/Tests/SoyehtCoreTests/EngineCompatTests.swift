import XCTest
@testable import SoyehtCore

// MARK: - Engine compatibility gate tests
//
// Locks the contract for `EngineCompat`: parse semver, compare, refuse
// engines older than `minSupportedEngineVersion`, surface the typed
// `BootstrapError.engineTooOld` to the UI layer.
//
// The bug that motivated this gate: theyos engine 0.1.12 served JSON
// where the iOS client expected CBOR, and didn't expose
// `/api/v1/household/claws`. The user saw an opaque "unexpected
// response type" message in the middle of pairing. The gate replaces
// that with a clear "update Soyeht on this Mac" message before the
// mutating POST is even attempted.

final class EngineCompatTests: XCTestCase {
    // MARK: - parseSemver

    func test_parseSemver_acceptsCanonicalForm() {
        XCTAssertEqual(EngineCompat.parseSemver("0.1.17"), [0, 1, 17])
        XCTAssertEqual(EngineCompat.parseSemver("1.2.3"), [1, 2, 3])
        XCTAssertEqual(EngineCompat.parseSemver("10.20.30"), [10, 20, 30])
    }

    func test_parseSemver_stripsPreReleaseAndBuildMetadata() {
        XCTAssertEqual(EngineCompat.parseSemver("0.1.17-rc.1"), [0, 1, 17])
        XCTAssertEqual(EngineCompat.parseSemver("0.1.17+meta"), [0, 1, 17])
        XCTAssertEqual(EngineCompat.parseSemver("1.2.3-alpha+build.42"), [1, 2, 3])
    }

    func test_parseSemver_rejectsMalformedShapes() {
        XCTAssertNil(EngineCompat.parseSemver(""))
        XCTAssertNil(EngineCompat.parseSemver("1.2"))           // missing PATCH
        XCTAssertNil(EngineCompat.parseSemver("1.2.3.4"))       // too many components
        XCTAssertNil(EngineCompat.parseSemver("unknown"))
        XCTAssertNil(EngineCompat.parseSemver("0.1.abc"))       // non-numeric
        XCTAssertNil(EngineCompat.parseSemver("v0.1.17"))       // `v` prefix not allowed
    }

    // MARK: - compareSemver

    func test_compareSemver_orderingsPerComponent() {
        // Equal.
        XCTAssertEqual(EngineCompat.compareSemver("0.1.17", "0.1.17"), .orderedSame)
        // PATCH ordering.
        XCTAssertEqual(EngineCompat.compareSemver("0.1.16", "0.1.17"), .orderedAscending)
        XCTAssertEqual(EngineCompat.compareSemver("0.1.18", "0.1.17"), .orderedDescending)
        // MINOR ordering takes precedence over PATCH.
        XCTAssertEqual(EngineCompat.compareSemver("0.1.99", "0.2.0"), .orderedAscending)
        // MAJOR ordering takes precedence over MINOR.
        XCTAssertEqual(EngineCompat.compareSemver("0.99.99", "1.0.0"), .orderedAscending)
    }

    func test_compareSemver_unparseableSidesTreatedAsBelow() {
        // Unparseable lhs → ascending (caller refuses).
        XCTAssertEqual(EngineCompat.compareSemver("unknown", "0.1.17"), .orderedAscending)
        XCTAssertEqual(EngineCompat.compareSemver("", "0.1.17"), .orderedAscending)
        // Unparseable rhs → descending (caller wouldn't normally hit this,
        // since rhs is always our pinned minSupportedEngineVersion).
        XCTAssertEqual(EngineCompat.compareSemver("0.1.17", "unknown"), .orderedDescending)
    }

    // MARK: - isCompatible (uses minSupportedEngineVersion)

    func test_isCompatible_acceptsEqualVersion() {
        XCTAssertTrue(EngineCompat.isCompatible(EngineCompat.minSupportedEngineVersion))
    }

    func test_isCompatible_acceptsNewerVersion() {
        // Increment last component of the pin so we are unambiguously newer.
        let pin = EngineCompat.parseSemver(EngineCompat.minSupportedEngineVersion)!
        let newer = "\(pin[0]).\(pin[1]).\(pin[2] + 1)"
        XCTAssertTrue(EngineCompat.isCompatible(newer))
    }

    func test_isCompatible_rejectsOlderVersion() {
        XCTAssertFalse(EngineCompat.isCompatible("0.0.1"))
        XCTAssertFalse(EngineCompat.isCompatible("0.0.99"))
    }

    func test_isCompatible_rejectsUnparseableVersion() {
        // Unknown engines are refused on purpose — we cannot prove they
        // implement the routes we depend on.
        XCTAssertFalse(EngineCompat.isCompatible("unknown"))
        XCTAssertFalse(EngineCompat.isCompatible(""))
        XCTAssertFalse(EngineCompat.isCompatible("v0.1.17"))
    }

    // MARK: - assertCompatible (uses a fake-transport BootstrapStatusClient)

    func test_assertCompatible_passesOnSupportedEngine() async throws {
        let status = makeStatusCBOR(engineVersion: EngineCompat.minSupportedEngineVersion)
        let client = makeStatusClient(returning: status)
        try await EngineCompat.assertCompatible(via: client)
    }

    func test_assertCompatible_throwsEngineTooOldOnAncientEngine() async {
        let status = makeStatusCBOR(engineVersion: "0.0.1")
        let client = makeStatusClient(returning: status)
        do {
            try await EngineCompat.assertCompatible(via: client)
            XCTFail("expected engineTooOld")
        } catch BootstrapError.engineTooOld(let found, let required) {
            XCTAssertEqual(found, "0.0.1")
            XCTAssertEqual(required, EngineCompat.minSupportedEngineVersion)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_assertCompatible_throwsEngineTooOldOnUnparseableVersion() async {
        let status = makeStatusCBOR(engineVersion: "unknown")
        let client = makeStatusClient(returning: status)
        do {
            try await EngineCompat.assertCompatible(via: client)
            XCTFail("expected engineTooOld")
        } catch BootstrapError.engineTooOld(let found, _) {
            XCTAssertEqual(found, "unknown")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_engineTooOld_localizedDescription_mentionsBothVersions() {
        let err = BootstrapError.engineTooOld(found: "0.1.12", required: "0.1.17")
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("0.1.12"), "message must include found version: \(msg)")
        XCTAssertTrue(msg.contains("0.1.17"), "message must include required version: \(msg)")
    }

    // MARK: - Helpers

    private func makeStatusClient(returning cbor: Data) -> BootstrapStatusClient {
        BootstrapStatusClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8091/bootstrap/status")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/cbor"]
                )!
                return (cbor, response)
            },
            sleeper: { _ in }
        )
    }

    /// Builds a minimal valid `/bootstrap/status` CBOR response with a
    /// custom `engine_version` field. Mirrors the static helper in
    /// `BootstrapStatusClientTests` but parameterised on the field we
    /// care about here.
    private func makeStatusCBOR(engineVersion: String) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "state": .text("uninitialized"),
            "engine_version": .text(engineVersion),
            "platform": .text("mac"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
            "owner_display_name": .null,
            "hh_id": .null,
            "hh_pub": .null,
        ]))
    }
}
