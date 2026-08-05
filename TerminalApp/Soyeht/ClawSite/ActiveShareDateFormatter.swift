import Foundation

/// Renders a share timestamp unambiguously: every label carries both a day
/// reference ("Today"/"Yesterday"/"Tomorrow", or a full date once it's none
/// of those) and a time. A formatter that dropped the day would let two
/// events exactly 24h apart — e.g. accepted yesterday at 2:32 PM and revoked
/// today at 2:32 PM — render as the identical clock time with no way to tell
/// them apart. `calendar`/`locale`/`timeZone` are constructor parameters and
/// `now` is a call parameter (never `Date()` read internally) so the exact
/// day boundary is deterministic and testable.
///
/// Mirrors `ShareAppViewModel.unambiguousExpiryLabel`'s wording and
/// `Date.FormatStyle` machinery (same "Today at 5:00 PM" / abbreviated-date
/// shape) so the two share-related screens read consistently; extended with
/// a "Yesterday" branch because Active Shares' `created_at`/`accepted_at`/
/// `revoked_at` — unlike a link's expiry — are routinely in the past.
protocol ActiveShareDateFormatting: Sendable {
    func label(for date: Date, now: Date) -> String
}

struct ActiveShareDateFormatter: ActiveShareDateFormatting {
    private let calendar: Calendar
    private let locale: Locale
    private let timeZone: TimeZone

    enum DayQualifier: Equatable {
        case yesterday
        case today
        case tomorrow
        case other
    }

    init(calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .current) {
        var calendar = calendar
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
    }

    func dayQualifier(for date: Date, now: Date) -> DayQualifier {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0
        switch dayOffset {
        case 0: return .today
        case 1: return .tomorrow
        case -1: return .yesterday
        default: return .other
        }
    }

    func label(for date: Date, now: Date) -> String {
        // `timeZone:` must be passed explicitly — `Date.FormatStyle` has its
        // own time zone independent of `calendar.timeZone`, which only
        // affects the calendar CALCULATIONS `Date.FormatStyle` performs
        // internally (e.g. which day a date's components fall on), not
        // which zone the rendered clock time is displayed in. Omitting it
        // here would silently render in the system's local zone regardless
        // of what was injected — exactly defeating the point of accepting
        // `timeZone` as a parameter in the first place.
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
        )
        switch dayQualifier(for: date, now: now) {
        case .yesterday:
            return "\(dayWord(.yesterday)) at \(time)"
        case .today:
            return "\(dayWord(.today)) at \(time)"
        case .tomorrow:
            return "\(dayWord(.tomorrow)) at \(time)"
        case .other:
            // Far enough out (or, for a distant past date, long enough ago)
            // that "Today"/"Yesterday"/"Tomorrow" would stop being
            // unambiguous on their own — spell out the date instead.
            return date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            )
        }
    }

    private func dayWord(_ qualifier: DayQualifier) -> String {
        switch qualifier {
        case .yesterday:
            return String(
                localized: "activeShares.day.yesterday", defaultValue: "Yesterday",
                comment: "Day qualifier for a share event that happened yesterday.")
        case .today:
            return String(
                localized: "activeShares.day.today", defaultValue: "Today",
                comment: "Day qualifier for a share event that happened today.")
        case .tomorrow:
            return String(
                localized: "activeShares.day.tomorrow", defaultValue: "Tomorrow",
                comment: "Day qualifier for a share event happening tomorrow.")
        case .other:
            return ""
        }
    }
}
