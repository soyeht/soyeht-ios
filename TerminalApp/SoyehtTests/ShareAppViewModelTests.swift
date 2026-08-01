import Foundation
import SoyehtCore
import XCTest

@testable import Soyeht

private struct StubAppsReader: ShareableAppsReading {
    let apps: [ShareableApp]
    let error: Error?

    init(apps: [ShareableApp] = [], error: Error? = nil) {
        self.apps = apps
        self.error = error
    }

    func shareableApps() async throws -> [ShareableApp] {
        if let error { throw error }
        return apps
    }
}

private actor RecordingMinter: ShareInviteMinting {
    struct Call: Equatable {
        let clawID: String
        let ttlSeconds: UInt64
    }

    private(set) var calls: [Call] = []
    private let result: ClawShareMintedInvite?
    private let error: Error?

    init(result: ClawShareMintedInvite? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func mintInvite(clawID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite {
        calls.append(Call(clawID: clawID, ttlSeconds: ttlSeconds))
        if let error { throw error }
        return result!
    }
}

private enum ShareTestError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "engine unreachable" }
}

@MainActor
final class ShareAppViewModelTests: XCTestCase {
    private func invite(uri: String = "soyeht://claw-share/v1?e=abc") -> ClawShareMintedInvite {
        ClawShareMintedInvite(uri: uri, slotId: Data([0x01]), expiresAt: 1_810_000_000)
    }

    private func app(_ name: String, running: Bool = true) -> ShareableApp {
        ShareableApp(clawID: name, displayName: name, isRunning: running)
    }

    func test_loadListsAppsAndDoesNotPreselectWhenThereIsAChoice() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances"), app("Notes")]),
            minter: RecordingMinter(result: invite())
        )

        await model.load()

        XCTAssertEqual(model.phase, .picking)
        XCTAssertEqual(model.apps.count, 2)
        XCTAssertNil(model.selectedAppID, "with more than one app the owner must choose")
        XCTAssertFalse(model.canShare)
    }

    func test_singleAppIsPreselected() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(result: invite())
        )

        await model.load()

        XCTAssertEqual(model.selectedAppID, "House finances")
        XCTAssertTrue(model.canShare)
    }

    func test_shareMintsForTheSelectedAppAndChosenDuration() async {
        let minter = RecordingMinter(result: invite(uri: "soyeht://claw-share/v1?e=zzz"))
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances"), app("Notes")]),
            minter: minter
        )
        await model.load()
        model.selectedAppID = "Notes"
        model.duration = .oneDay

        await model.share()

        let calls = await minter.calls
        // Typed explicitly: `24 * 60 * 60` infers as Int and fails to convert
        // to the UInt64 field under the CI toolchain, even though the local
        // one accepted it.
        let oneDaySeconds: UInt64 = 24 * 60 * 60
        XCTAssertEqual(calls, [.init(clawID: "Notes", ttlSeconds: oneDaySeconds)])
        guard case .shared(let link, _) = model.phase else {
            return XCTFail("expected shared phase, got \(model.phase)")
        }
        XCTAssertEqual(link, "soyeht://claw-share/v1?e=zzz")
    }

    func test_shareDoesNothingWithoutASelection() async {
        let minter = RecordingMinter(result: invite())
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("A"), app("B")]),
            minter: minter
        )
        await model.load()

        await model.share()

        let calls = await minter.calls
        XCTAssertTrue(calls.isEmpty, "must not burn a slot with nothing selected")
    }

    func test_loadFailureSurfacesInsteadOfShowingAnEmptyPicker() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(error: ShareTestError.boom),
            minter: RecordingMinter(result: invite())
        )

        await model.load()

        guard case .failed(let message) = model.phase else {
            return XCTFail("expected failed phase, got \(model.phase)")
        }
        XCTAssertEqual(message, "engine unreachable")
    }

    func test_mintFailureSurfacesAndDoesNotClaimSuccess() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(error: ShareTestError.boom)
        )
        await model.load()

        await model.share()

        guard case .failed = model.phase else {
            return XCTFail("expected failed phase, got \(model.phase)")
        }
    }

    func test_staleSelectionIsClearedWhenTheAppDisappears() async {
        // Reloading after an app is removed must not leave a selection
        // pointing at something the owner can no longer see — sharing it
        // would mint an invite for a name that is no longer on the list.
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("A"), app("B")]),
            minter: RecordingMinter(result: invite())
        )
        await model.load()
        model.selectedAppID = "B"

        let shrunk = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("A"), app("C")]),
            minter: RecordingMinter(result: invite())
        )
        shrunk.selectedAppID = "B"
        await shrunk.load()

        XCTAssertNil(shrunk.selectedAppID)
        XCTAssertFalse(shrunk.canShare)
    }

    func test_shareAnotherReturnsToThePickerKeepingTheAppList() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(result: invite())
        )
        await model.load()
        await model.share()

        model.shareAnother()

        XCTAssertEqual(model.phase, .picking)
        XCTAssertEqual(model.apps.count, 1)
    }

    func test_clawIDIsTheNameTheGuestWillSee() async {
        // `claw_id` is what the guest is shown ("Connect to X?"), so it must
        // be the human name, never an opaque instance id.
        let minter = RecordingMinter(result: invite())
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: minter
        )
        await model.load()

        await model.share()

        let calls = await minter.calls
        XCTAssertEqual(calls.first?.clawID, "House finances")
    }
}
