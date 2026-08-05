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
        let appID: String
        let ttlSeconds: UInt64
    }

    private(set) var calls: [Call] = []
    private let result: ClawShareMintedInvite?
    private let error: Error?

    init(result: ClawShareMintedInvite? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func mintInvite(appID: String, ttlSeconds: UInt64) async throws -> ClawShareMintedInvite {
        calls.append(Call(appID: appID, ttlSeconds: ttlSeconds))
        if let error { throw error }
        return result!
    }
}

private enum ShareTestError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "engine unreachable" }
}

private final class RecordingClipboard: ClipboardWriting, @unchecked Sendable {
    let requiresMainThread = false
    private(set) var written: [String] = []

    func writeString(_ value: String) {
        written.append(value)
    }
}

private final class RecordingLinkCache: ActiveShareLinkCaching, @unchecked Sendable {
    struct StoreCall: Equatable {
        let uri: String
        let slotId: Data
    }

    private(set) var storeCalls: [StoreCall] = []
    private let storeResult: Bool

    init(storeResult: Bool = true) {
        self.storeResult = storeResult
    }

    func store(uri: String, forSlotID slotID: Data) -> Bool {
        storeCalls.append(StoreCall(uri: uri, slotId: slotID))
        return storeResult
    }

    func uri(forSlotID slotID: Data) -> String? { nil }
    func remove(forSlotID slotID: Data) {}
    func prune(keeping keepSlotIDs: Set<Data>) {}
}

@MainActor
final class ShareAppViewModelTests: XCTestCase {
    private func invite(uri: String = "soyeht://claw-share/v1?e=abc") -> ClawShareMintedInvite {
        ClawShareMintedInvite(uri: uri, slotId: Data([0x01]), expiresAt: 1_810_000_000)
    }

    private func app(_ name: String, appID: String? = nil, running: Bool = true) -> ShareableApp {
        app(name, appID: appID, readiness: running ? .running : .stopped)
    }

    private func app(_ name: String, appID: String? = nil, readiness: ShareReadiness) -> ShareableApp {
        ShareableApp(appID: appID ?? name, displayName: name, readiness: readiness)
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
        XCTAssertEqual(calls, [.init(appID: "Notes", ttlSeconds: oneDaySeconds)])
        guard case .shared(let link, _) = model.phase else {
            return XCTFail("expected shared phase, got \(model.phase)")
        }
        XCTAssertEqual(link, "soyeht://claw-share/v1?e=zzz")
    }

    func test_shareStoresTheMintedLinkInTheCacheWithTheInvitesUriAndSlotId() async {
        let mintedInvite = invite(uri: "soyeht://claw-share/v1?e=cache-me")
        let linkCache = RecordingLinkCache()
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(result: mintedInvite),
            linkCache: linkCache
        )
        await model.load()

        await model.share()

        XCTAssertEqual(linkCache.storeCalls, [.init(uri: mintedInvite.uri, slotId: mintedInvite.slotId)])
    }

    func test_shareStillReachesSharedPhaseAndKeepsTheCurrentLinkWhenCacheStoreFails() async {
        let mintedInvite = invite(uri: "soyeht://claw-share/v1?e=uncacheable")
        let linkCache = RecordingLinkCache(storeResult: false)
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(result: mintedInvite),
            linkCache: linkCache
        )
        await model.load()

        await model.share()

        guard case .shared(let link, _) = model.phase else {
            return XCTFail("a failed cache write must not block the current screen's link — got \(model.phase)")
        }
        XCTAssertEqual(link, mintedInvite.uri, "the just-minted screen's own link is unaffected by a cache-write failure")
        XCTAssertEqual(linkCache.storeCalls.count, 1, "the write must still have been attempted exactly once")
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
        // Stable, non-technical copy -- never the raw `error.localizedDescription`
        // ("engine unreachable"), which the plan (§5.4) reserves for
        // diagnostics only, not the owner-facing message.
        XCTAssertNotEqual(message, "engine unreachable")
        XCTAssertFalse(message.isEmpty)
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

    func test_duplicateDisplayNamesStayIndependentlySelectableAndMintTheCorrectAppID() async {
        // Two apps may legitimately share a `displayName` (D6: identity is
        // `appID`, never name-derived). Both must list as distinct rows, and
        // selecting/minting one must never leak into the other's appID.
        let minter = RecordingMinter(result: invite())
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [
                app("Study", appID: "app_1"),
                app("Study", appID: "app_2"),
            ]),
            minter: minter
        )
        await model.load()
        XCTAssertEqual(model.apps.count, 2, "same display name must not collapse the two rows")

        model.selectedAppID = "app_2"
        await model.share()

        let calls = await minter.calls
        XCTAssertEqual(calls.first?.appID, "app_2", "must mint the SELECTED app's id, not the other same-named one")
    }

    // D1 (warn-and-allow): a stopped app must show the warning AND remain
    // fully shareable — the two things that could regress independently of
    // each other, so both are asserted in the same test rather than split
    // across two that could each pass while the other silently broke.

    func test_stoppedAppShowsTheWarningAndMintingIsStillPermitted() async {
        let minter = RecordingMinter(result: invite())
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances", running: false)]),
            minter: minter
        )
        await model.load()

        XCTAssertTrue(model.showsStoppedAppWarning)
        XCTAssertTrue(model.canShare, "D1 is warn-and-allow, not a hard gate")

        await model.share()

        let calls = await minter.calls
        guard case .shared = model.phase else {
            return XCTFail("expected a stopped app's share to still succeed, got \(model.phase)")
        }
        XCTAssertEqual(calls.count, 1, "minting for a stopped app must not be silently skipped")
    }

    func test_everyNonRunningReadinessWarnsAndMintingStaysPermitted() async {
        // D1 is warn-and-allow for the WHOLE non-running surface, not just
        // "stopped" — starting and unavailable must behave identically.
        for readiness: ShareReadiness in [.starting, .stopped, .unavailable] {
            let minter = RecordingMinter(result: invite())
            let model = ShareAppViewModel(
                reader: StubAppsReader(apps: [app("House finances", readiness: readiness)]),
                minter: minter
            )
            await model.load()

            XCTAssertTrue(model.showsStoppedAppWarning, "readiness \(readiness) must warn")
            XCTAssertTrue(model.canShare, "readiness \(readiness) must not block sharing")

            await model.share()
            let calls = await minter.calls
            XCTAssertEqual(calls.count, 1, "readiness \(readiness) must not silently skip the mint")
        }
    }

    func test_runningAppDoesNotShowTheWarning() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances", running: true)]),
            minter: RecordingMinter(result: invite())
        )
        await model.load()

        XCTAssertFalse(model.showsStoppedAppWarning)
        XCTAssertTrue(model.canShare)
    }

    func test_noWarningBeforeAnAppIsSelected() async {
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances", running: false), app("Notes", running: true)]),
            minter: RecordingMinter(result: invite())
        )
        await model.load()

        XCTAssertNil(model.selectedAppID, "two apps: nothing preselected")
        XCTAssertFalse(model.showsStoppedAppWarning, "no selection yet, nothing to warn about")
    }

    func test_copyLinkWritesTheCurrentLinkWhileShared() async {
        let clipboard = RecordingClipboard()
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances")]),
            minter: RecordingMinter(result: invite(uri: "soyeht://claw-share/v1?e=copy-me")),
            clipboard: clipboard
        )
        await model.load()
        await model.share()

        let copied = model.copyLink()

        XCTAssertTrue(copied)
        XCTAssertEqual(clipboard.written, ["soyeht://claw-share/v1?e=copy-me"])
    }

    func test_copyLinkDoesNothingOutsideTheSharedPhase() async {
        let clipboard = RecordingClipboard()
        let model = ShareAppViewModel(
            reader: StubAppsReader(apps: [app("House finances"), app("Notes")]),
            minter: RecordingMinter(result: invite()),
            clipboard: clipboard
        )
        await model.load()
        XCTAssertEqual(model.phase, .picking)

        let copied = model.copyLink()

        XCTAssertFalse(copied)
        XCTAssertTrue(clipboard.written.isEmpty)
    }

    // `expiryDayQualifier` is pure `Calendar` day arithmetic — no formatted
    // or localized text involved — so these are locale-agnostic by
    // construction, not by accident of which substrings happen to appear in
    // one locale's output.

    func test_dayQualifierIsTodayForASameDayExpiry() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 9))!
        let expiresAt = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 17))!

        XCTAssertEqual(
            ShareAppViewModel.expiryDayQualifier(for: expiresAt, now: now, calendar: calendar),
            .today
        )
    }

    func test_dayQualifierIsTomorrowForA24HourInvite() {
        // The exact bug the plan calls out: "A 24-hour invitation must never
        // show only the same clock time with no date." A 24h-out expiry
        // must resolve to a day-qualified case, never fall through to
        // "same as now."
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 17))!
        let expiresAt = calendar.date(byAdding: .hour, value: 24, to: now)!

        XCTAssertEqual(
            ShareAppViewModel.expiryDayQualifier(for: expiresAt, now: now, calendar: calendar),
            .tomorrow
        )
    }

    func test_dayQualifierIsOtherForAFarExpiry() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 9))!
        let expiresAt = calendar.date(byAdding: .day, value: 5, to: now)!

        XCTAssertEqual(
            ShareAppViewModel.expiryDayQualifier(for: expiresAt, now: now, calendar: calendar),
            .other
        )
    }

    /// Real timezone boundary, not just an ambient-default `Calendar`. Both
    /// instants below fall on the SAME calendar day in Kiritimati (UTC+14)
    /// but on DIFFERENT calendar days in UTC -- proving `expiryDayQualifier`
    /// resolves the day using the `Calendar` it's given, not the system's
    /// default zone (which is what every previous fixture here happened to
    /// share, ambiently, with the qualifier's arithmetic).
    func test_dayQualifierUsesTheGivenCalendarsTimeZoneAcrossAMidnightUTCBoundary() {
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!

        // 2026-08-05 00:30 Kiritimati == 2026-08-04 10:30 UTC.
        let now = kiritimati.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 0, minute: 30))!
        // 2026-08-05 23:00 Kiritimati == 2026-08-05 09:00 UTC -- a different
        // UTC calendar day from `now`, but the same Kiritimati day.
        let expiresAt = kiritimati.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 23))!

        XCTAssertEqual(
            ShareAppViewModel.expiryDayQualifier(for: expiresAt, now: now, calendar: kiritimati),
            .today,
            "must resolve using the given calendar's own time zone, not UTC or the system default"
        )

        // Sanity check that this genuinely crosses a boundary: the same two
        // instants, read through UTC, land on CONSECUTIVE UTC calendar days
        // (now = Aug 4 UTC, expiresAt = Aug 5 UTC) rather than the same one --
        // a different qualifier than Kiritimati's `.today` above, proving the
        // result actually depends on which calendar's time zone is used.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            ShareAppViewModel.expiryDayQualifier(for: expiresAt, now: now, calendar: utc),
            .tomorrow,
            "sanity check: these instants must actually straddle a UTC day boundary"
        )
    }

    /// Text-content check with the locale pinned explicitly, per review: a
    /// substring match against unpinned `.current`/`.autoupdatingCurrent`
    /// output would make this test's pass/fail depend on the machine's
    /// locale rather than on behavior.
    func test_unambiguousExpiryLabelNeverShowsABareClockTimeForA24HourInvite() {
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 17))!
        let expiresAt = calendar.date(byAdding: .hour, value: 24, to: now)!

        let label = ShareAppViewModel.unambiguousExpiryLabel(
            for: expiresAt, now: now, calendar: calendar, locale: locale
        )
        let bareTime = expiresAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        )

        XCTAssertNotEqual(label, bareTime, "must not render as a bare, dateless clock time")
        XCTAssertTrue(label.contains("Tomorrow"), "expected an explicit 'Tomorrow' qualifier, got: \(label)")
    }
}
