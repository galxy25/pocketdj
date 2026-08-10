import Foundation

/// HOW OFTEN For You RE-RANKS ITSELF — the schedule behind Settings ▸ For You ▸ Refresh.
///
/// Owner, verbatim: *"have a setting in settings for how frequently For You Tab refreshes (default
/// to Friday @ 4:20 and support hourly, daily, or monthly)."*
///
/// ── WHY "MANUAL ONLY" IS IN THE LIST ─────────────────────────────────────────────────────────
/// The tab SHIPPED as refresh-on-demand — owner, earlier and equally verbatim: *"history for you
/// should cache the last result and only refresh when you hit a refresh button in the menu."*
/// Dropping that option would take away behaviour he asked for and is using today, so it stays as
/// an explicit choice; it is simply no longer the DEFAULT. The default is `weekly`, Friday 16:20
/// local, exactly as asked.
///
/// The ⋯ ▸ Refresh keeps working under every cadence including `.manual` — a schedule is an
/// ADDITIONAL trigger, never a replacement for his hands.
enum ForYouRefreshCadence: String, CaseIterable, Codable, Sendable, Identifiable {
    /// No automatic refresh. Only ⋯ ▸ Refresh (and the one-shot cold-install build) recompute.
    case manual
    /// At `minutesOfDay % 60` past EVERY hour — i.e. the default 16:20 becomes ":20 past".
    case hourly
    /// Once a day at the chosen local time.
    case daily
    /// Once a week on the chosen weekday at the chosen local time. THE DEFAULT (Friday 16:20).
    case weekly
    /// Once a month, on the 1st, at the chosen local time.
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Only when I ask"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

/// The PURE schedule arithmetic. No stores, no clock of its own (the clock rides in as `nowMs`),
/// no SwiftUI — so it is unit-tested directly and callable from anywhere.
///
/// ── DUE-NESS IS EVALUATED AT READ TIME, NEVER BY A TIMER ─────────────────────────────────────
/// There is no scheduled sweep and no background task behind this. The app is very often NOT
/// running at 16:20 on a Friday, and a timer that never fires would leave the feed frozen forever
/// — the exact failure mode this setting exists to prevent. Instead the question "is a refresh
/// due?" is asked when For You is READ (the tab opening, the app returning to the foreground), and
/// answered against the LAST-REFRESHED STAMP already carried by `ForYouFeedSnapshot.refreshedAtMs`.
/// No second source of truth, and nothing to keep in sync.
///
/// ── MISSED SLOTS FIRE LATE, NOT NEVER ────────────────────────────────────────────────────────
/// `isDue` does not ask "is it Friday 16:20 right now" — it asks "has the MOST RECENT scheduled
/// instant already passed, and is the cached feed older than it?" So a phone that was off all
/// weekend refreshes the moment it is opened on Monday, instead of waiting a further five days for
/// the next Friday. Same rule for every cadence, which is why there is one `lastFire` and not five.
///
/// ── IT CANNOT LOOP ───────────────────────────────────────────────────────────────────────────
/// A completed refresh stamps `refreshedAtMs = now`, and `now >= lastFire` by construction, so the
/// very next evaluation is not due. A refresh that BAILS (empty catalog — see
/// `ForYouFeedStore.refresh`) does not move the stamp, so it is retried on the next read, which is
/// the behaviour we want.
enum ForYouRefreshSchedule {

    /// Friday 16:20 local — the shipped default (`weekday` in `Calendar`'s 1 = Sunday numbering).
    static let defaultCadence = ForYouRefreshCadence.weekly
    static let defaultMinutes = 16 * 60 + 20
    static let defaultWeekday = 6

    static let minutesRange = 0...1439
    static let weekdayRange = 1...7

    /// Localized weekday name for the picker (1 = Sunday … 7 = Saturday).
    static func weekdayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let idx = min(max(weekday, 1), 7) - 1
        let names = calendar.weekdaySymbols
        return idx < names.count ? names[idx] : "Friday"
    }

    /// The MOST RECENT scheduled instant at or before `now`, or `nil` for `.manual` (which has no
    /// schedule at all). This single function is what makes a missed slot fire late rather than
    /// never — every cadence answers the same question.
    static func lastFire(before now: Date,
                         cadence: ForYouRefreshCadence,
                         minutesOfDay: Int,
                         weekday: Int,
                         calendar: Calendar = .current) -> Date? {
        guard cadence != .manual else { return nil }
        let mins = min(max(minutesOfDay, 0), 1439)
        let hour = mins / 60, minute = mins % 60

        switch cadence {
        case .manual:
            return nil

        case .hourly:
            // ":MM past every hour" rather than a rolling 60-minute timer: it keeps the readout
            // predictable ("next refresh 3:20") and keeps the default 4:20 meaningful.
            var c = calendar.dateComponents([.year, .month, .day, .hour], from: now)
            c.minute = minute; c.second = 0; c.nanosecond = 0
            guard let candidate = calendar.date(from: c) else { return nil }
            return candidate <= now ? candidate
                : calendar.date(byAdding: .hour, value: -1, to: candidate)

        case .daily:
            guard let candidate = instant(hour, minute, onDayOf: now, calendar) else { return nil }
            return candidate <= now ? candidate
                : calendar.date(byAdding: .day, value: -1, to: candidate)

        case .weekly:
            // Walk back at most 8 days looking for the target weekday's fire time. 8 and not 7
            // because TODAY may be the target weekday with its fire time still ahead of us, in
            // which case the answer is the same weekday a week ago.
            let target = min(max(weekday, 1), 7)
            for back in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                      let candidate = instant(hour, minute, onDayOf: day, calendar),
                      candidate <= now,
                      calendar.component(.weekday, from: candidate) == target
                else { continue }
                return candidate
            }
            return nil

        case .monthly:
            var c = calendar.dateComponents([.year, .month], from: now)
            c.day = 1; c.hour = hour; c.minute = minute; c.second = 0; c.nanosecond = 0
            guard let candidate = calendar.date(from: c) else { return nil }
            return candidate <= now ? candidate
                : calendar.date(byAdding: .month, value: -1, to: candidate)
        }
    }

    /// The NEXT scheduled instant strictly after `now` — the "Next refresh" readout in Settings.
    /// Derived from `lastFire` so the two can never disagree about where the grid sits.
    static func nextFire(after now: Date,
                         cadence: ForYouRefreshCadence,
                         minutesOfDay: Int,
                         weekday: Int,
                         calendar: Calendar = .current) -> Date? {
        guard let last = lastFire(before: now, cadence: cadence, minutesOfDay: minutesOfDay,
                                  weekday: weekday, calendar: calendar) else { return nil }
        switch cadence {
        case .manual:  return nil
        case .hourly:  return calendar.date(byAdding: .hour, value: 1, to: last)
        case .daily:   return calendar.date(byAdding: .day, value: 1, to: last)
        case .weekly:  return calendar.date(byAdding: .day, value: 7, to: last)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: last)
        }
    }

    /// Is an automatic refresh due?
    ///
    /// `lastRefreshedAtMs` is `ForYouFeedSnapshot.refreshedAtMs`: `0` means "never computed", which
    /// is due under any real cadence (the cold-install first build takes that case first in
    /// practice, but answering honestly here keeps the function usable on its own).
    static func isDue(nowMs: Double,
                      lastRefreshedAtMs: Double,
                      cadence: ForYouRefreshCadence,
                      minutesOfDay: Int,
                      weekday: Int,
                      calendar: Calendar = .current) -> Bool {
        guard cadence != .manual else { return false }
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        guard let fire = lastFire(before: now, cadence: cadence, minutesOfDay: minutesOfDay,
                                  weekday: weekday, calendar: calendar) else { return false }
        guard lastRefreshedAtMs > 0 else { return true }
        return Date(timeIntervalSince1970: lastRefreshedAtMs / 1000) < fire
    }

    /// `hour:minute` on the calendar day containing `day`.
    private static func instant(_ hour: Int, _ minute: Int, onDayOf day: Date,
                                _ calendar: Calendar) -> Date? {
        var c = calendar.dateComponents([.year, .month, .day], from: day)
        c.hour = hour; c.minute = minute; c.second = 0; c.nanosecond = 0
        return calendar.date(from: c)
    }
}
