import XCTest
@testable import SoyehtMacDomain

final class AppManifestTests: XCTestCase {
    private let valid = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme"},"capabilities":[],"optionalCapabilities":[]}"#

    func testValidManifestIsAccepted() throws {
        XCTAssertEqual(try AppManifest.decode(Data(valid.utf8)).id, "notes-app")
    }

    func testUnknownManifestKeyIsRejected() {
        XCTAssertThrowsError(try AppManifest.decode(Data((valid.dropLast() + #",\"injected\":true}"#).utf8)))
    }

    func testUnknownPublisherKeyIsRejected() {
        let invalid = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme","INJETADA":"bad"},"capabilities":[],"optionalCapabilities":[]}"#
        XCTAssertThrowsError(try AppManifest.decode(Data(invalid.utf8)))
    }

    func testParentKeyInjectedIntoPublisherIsRejected() {
        let invalid = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme","entry":"bad"},"capabilities":[],"optionalCapabilities":[]}"#
        XCTAssertThrowsError(try AppManifest.decode(Data(invalid.utf8)))
    }

    func testEntryContainingParentReferenceIsRejected() {
        XCTAssertThrowsError(try AppManifest.decode(Data(valid.replacingOccurrences(of: "index.html", with: "../index.html").utf8)))
    }

    func testManifestOverMaximumSizeIsRejectedBeforeDecoding() {
        XCTAssertThrowsError(try AppManifest.decode(Data(repeating: 0x20, count: AppManifest.maximumByteCount + 1))) { error in
            XCTAssertEqual(error as? AppManifestError, .fileTooLarge)
        }
    }

    func testKnownCapabilityIsAccepted() throws {
        let raw = valid.replacingOccurrences(of: #"\"capabilities\":[]"#, with: #"\"capabilities\":[\"metrics.read\"]"#)
        let manifest = try AppManifest.decode(Data(raw.utf8))
        XCTAssertEqual(manifest.capabilities, [AppCapability.metricsRead.rawValue])
    }

    func testUnknownCapabilityIsRejected() {
        let raw = valid.replacingOccurrences(of: #"\"capabilities\":[]"#, with: #"\"capabilities\":[\"network.read\"]"#)
        XCTAssertThrowsError(try AppManifest.decode(Data(raw.utf8)))
    }
}
