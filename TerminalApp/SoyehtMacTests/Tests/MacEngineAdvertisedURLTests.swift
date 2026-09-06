import XCTest
@testable import SoyehtMacDomain
import SoyehtCore

final class MacEngineAdvertisedURLTests: XCTestCase {
    private let installation = PairingInstallIdentity(profile: "dev", bootstrapPort: 8101)

    private func offer(_ hosts: [(String, PairingTransport)]) -> PairingAddressOffer {
        PairingAddressOffer(installation: installation, generation: "listener-snapshot", candidates: hosts.map {
            PairingAddressCandidate(url: URL(string: "http://\($0.0):8101")!, transport: $0.1,
                                    operations: [.addDevice], availability: .listening)
        })
    }

    func testPresentationPreservesTailnetWithoutPhoneEvidence() throws {
        let url = try MacEngineAdvertisedURL.resolve(
            offer: offer([("192.168.1.20", .localNetwork), ("100.64.0.10", .tailnet)]),
            operation: .addDevice, installation: installation)
        XCTAssertEqual(url.host, "100.64.0.10")
    }

    func testLANOnlyListenerCanBePresented() throws {
        let url = try MacEngineAdvertisedURL.resolve(offer: offer([("192.168.1.20", .localNetwork)]),
                                                    operation: .addDevice, installation: installation)
        XCTAssertEqual(url.host, "192.168.1.20")
    }

    func testMissingListenersCannotBecomeLoopbackSuccess() {
        XCTAssertThrowsError(try MacEngineAdvertisedURL.resolve(offer: offer([]),
            operation: .addDevice, installation: installation)) {
            XCTAssertEqual($0 as? PairingAddressError, .noAvailableEndpoint)
        }
    }

    func testListenerForAnotherOperationCannotBePresented() {
        XCTAssertThrowsError(try MacEngineAdvertisedURL.resolve(offer: offer([("100.64.0.10", .tailnet)]),
            operation: .firstOwner, installation: installation)) {
            XCTAssertEqual($0 as? PairingAddressError, .operationUnavailable)
        }
    }

    func testMacConsumersReadEngineFactsWithoutIndependentInterfaceRanking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SoyehtMac")
        for file in ["Welcome/SetupInvitationListener/SetupInvitationListener.swift",
                     "PreferencesDevicesViewController.swift", "Pairing/MacPairingAdvertisement.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("BootstrapPairingAddressesClient"), file)
            XCTAssertFalse(source.contains("MacEngineAdvertisedURL.lanIPv4Addresses"), file)
            XCTAssertFalse(source.contains("best_qr_host"), file)
        }
    }
}
