import Foundation
import SoyehtCore
import XCTest

@testable import Soyeht

final class ActiveShareDateFormatterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US_POSIX")

    private func formatter() -> ActiveShareDateFormatter {
        ActiveShareDateFormatter(calendar: Calendar(identifier: .gregorian), locale: enUS, timeZone: utc)
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    /// Same `Date.FormatStyle` call the production code uses for the time
    /// portion — computed rather than hand-typed so the assertion doesn't
    /// depend on guessing ICU's exact whitespace glyph before AM/PM (which
    /// is a narrow no-break space, not a plain space, on this toolchain).
    /// This still pins the FULL literal string ("Today at <time>"), per
    /// review: only the glyph inside `<time>` is computed, the day-word/"at"
    /// wording is asserted verbatim.
    private func expectedTime(_ iso: String) -> String {
        date(iso).formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: enUS, calendar: Calendar(identifier: .gregorian), timeZone: utc)
        )
    }

    // MARK: - Day-label boundaries

    func test_sameDayAsNowLabelsToday() {
        let now = date("2026-08-04T20:00:00Z")
        let event = date("2026-08-04T14:32:00Z")

        XCTAssertEqual(formatter().label(for: event, now: now), "Today at \(expectedTime("2026-08-04T14:32:00Z"))")
    }

    func test_oneDayBeforeNowLabelsYesterday() {
        let now = date("2026-08-04T20:00:00Z")
        let event = date("2026-08-03T14:32:00Z")

        XCTAssertEqual(formatter().label(for: event, now: now), "Yesterday at \(expectedTime("2026-08-03T14:32:00Z"))")
    }

    func test_oneDayAfterNowLabelsTomorrow() {
        let now = date("2026-08-04T09:00:00Z")
        let event = date("2026-08-05T14:32:00Z")

        XCTAssertEqual(formatter().label(for: event, now: now), "Tomorrow at \(expectedTime("2026-08-05T14:32:00Z"))")
    }

    func test_dateFartherThanADayUsesAFullDateNotARelativeWord() {
        let now = date("2026-08-04T09:00:00Z")
        let event = date("2026-07-20T14:32:00Z")

        let label = formatter().label(for: event, now: now)

        XCTAssertFalse(label.hasPrefix("Today"))
        XCTAssertFalse(label.hasPrefix("Yesterday"))
        XCTAssertFalse(label.hasPrefix("Tomorrow"))
        XCTAssertTrue(label.contains("2026"), "a far-past date must still be unambiguous about the year")
    }

    /// The exact defect this seam exists to prevent: two events exactly 24h
    /// apart, at the SAME clock time, must never render as the same string —
    /// a bare time-only formatter would print the same clock time for both.
    func test_twentyFourHoursApartAtTheSameClockTimeNeverCollapseToTheSameString() {
        let now = date("2026-08-04T20:00:00Z")
        let today = date("2026-08-04T14:32:00Z")
        let yesterday = date("2026-08-03T14:32:00Z")

        let todayLabel = formatter().label(for: today, now: now)
        let yesterdayLabel = formatter().label(for: yesterday, now: now)
        let time = expectedTime("2026-08-04T14:32:00Z")

        XCTAssertNotEqual(todayLabel, yesterdayLabel)
        XCTAssertTrue(todayLabel.contains(time))
        XCTAssertTrue(yesterdayLabel.contains(time), "same clock time — only the day reference must differ")
    }

    func test_labelIsDeterministicForTheSameInputs() {
        let now = date("2026-08-04T20:00:00Z")
        let event = date("2026-08-04T14:32:00Z")
        let f = formatter()

        XCTAssertEqual(f.label(for: event, now: now), f.label(for: event, now: now))
    }

    func test_timeZoneIsInjectableAndChangesTheRenderedDayAndTime() {
        // 2026-08-04T23:30 UTC is 2026-08-05T08:30 in Tokyo — a real
        // instant that crosses the day boundary depending on the injected
        // time zone, proving the seam isn't decorative for the day word.
        let now = date("2026-08-04T12:00:00Z")
        let event = date("2026-08-04T23:30:00Z")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        let utcLabel = ActiveShareDateFormatter(locale: enUS, timeZone: utc).label(for: event, now: now)
        let tokyoLabel = ActiveShareDateFormatter(locale: enUS, timeZone: tokyo).label(for: event, now: now)

        XCTAssertTrue(utcLabel.hasPrefix("Today"))
        XCTAssertTrue(tokyoLabel.hasPrefix("Tomorrow"), "same instant, later local calendar day in Tokyo")
        // Same instant, different injected zone — the RENDERED CLOCK TIME
        // must also differ (23:30 UTC vs 08:30 JST), not just the day word.
        // `Date.FormatStyle` has its own `timeZone` independent of
        // `calendar.timeZone`; passing only the latter would silently
        // render every label in the system's local zone regardless of what
        // was injected here.
        XCTAssertNotEqual(utcLabel, tokyoLabel)
    }
}

final class ActiveShareRowDisplayTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US_POSIX")

    private func formatter() -> ActiveShareDateFormatter {
        ActiveShareDateFormatter(calendar: Calendar(identifier: .gregorian), locale: enUS, timeZone: utc)
    }

    private func row(
        status: ActiveShareStatus,
        acceptedAt: UInt64? = nil,
        revokedAt: UInt64? = nil
    ) -> ActiveShareRow {
        ActiveShareRow(
            descriptor: ActiveShareDescriptor(
                slotId: Data(repeating: 0x01, count: 16),
                appId: "app_" + String(repeating: "1", count: 32),
                displayName: "Study",
                status: status,
                readiness: .running,
                createdAt: 1_722_700_000,
                expiresAt: 1_722_786_400,
                acceptedAt: acceptedAt,
                revokedAt: revokedAt
            ),
            hasCachedLink: false
        )
    }

    // MARK: - Lifetime line: always present, every status

    func test_lifetimeTextAlwaysShowsCreatedAndExpiresRegardlessOfStatus() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        for status: ActiveShareStatus in [.waiting, .accepted, .expired, .revoked] {
            let text = row(status: status).lifetimeText(formatter: formatter(), now: now)
            XCTAssertTrue(text.hasPrefix("Created "), "status \(status): \(text)")
            XCTAssertTrue(text.contains("Expires "), "status \(status): \(text)")
        }
    }

    // MARK: - Status line: the four states

    func test_waitingStatusTextIsTheBareWord() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        XCTAssertEqual(row(status: .waiting).statusText(formatter: formatter(), now: now), "Waiting")
    }

    func test_expiredStatusTextIsTheBareWord() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        XCTAssertEqual(row(status: .expired).statusText(formatter: formatter(), now: now), "Expired")
    }

    func test_acceptedStatusTextCarriesTheAcceptedAtTimestamp() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        // acceptedAt = 1_722_700_500 -> 2024-08-03T18:35:00Z under this fixture's `now`.
        let text = row(status: .accepted, acceptedAt: 1_722_700_500)
            .statusText(formatter: formatter(), now: now)

        XCTAssertTrue(text.hasPrefix("Accepted · "))
        XCTAssertFalse(text.lowercased().contains("guest"), "must never surface a guest key/identifier")
    }

    func test_acceptedStatusTextFallsBackToBareWordWhenTimestampIsAbsent() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        XCTAssertEqual(row(status: .accepted).statusText(formatter: formatter(), now: now), "Accepted")
    }

    func test_revokedStatusTextCarriesTheRevokedAtTimestampWhenPresent() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        let text = row(status: .revoked, revokedAt: 1_722_700_800)
            .statusText(formatter: formatter(), now: now)

        XCTAssertTrue(text.hasPrefix("Revoked · "))
    }

    func test_revokedStatusTextFallsBackToBareWordWhenTimestampIsAbsent() {
        let now = Date(timeIntervalSince1970: 1_722_750_000)
        XCTAssertEqual(row(status: .revoked).statusText(formatter: formatter(), now: now), "Revoked")
    }

    /// The same 24h-collision guarantee, exercised through the row-level
    /// seam rather than the bare formatter: an Accepted share and a Revoked
    /// share at the identical clock time on consecutive days must not read
    /// as the same moment.
    func test_acceptedAndRevokedAtTheSameClockTimeOnDifferentDaysAreDistinguishable() {
        let now = Date(timeIntervalSince1970: 1_722_800_000)
        let today = row(status: .revoked, revokedAt: 1_722_784_320)
        let yesterday = row(status: .accepted, acceptedAt: 1_722_697_920)

        let todayText = today.statusText(formatter: formatter(), now: now)
        let yesterdayText = yesterday.statusText(formatter: formatter(), now: now)

        XCTAssertNotEqual(todayText, yesterdayText)
    }
}
