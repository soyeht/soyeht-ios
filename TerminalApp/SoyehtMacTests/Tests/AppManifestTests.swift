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
        let invalid = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme","entry":"bad"},"capabilities":[],"optionalCapabilities":[]}"#
        XCTAssertThrowsError(try AppManifest.decode(Data(invalid.utf8)))
    }
}
