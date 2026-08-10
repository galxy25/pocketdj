import XCTest
@testable import PocketDJ

/// HOW OFTEN For You REFRESHES — owner: *"have a setting in settings for how frequently For You Tab
/// refreshes (default to Friday @ 4:20 and support hourly, daily, or monthly)."*
///
/// The failures this file exists to prevent, in the order they would actually bite:
///
///  1. **A MISSED SLOT IS SKIPPED FOREVER.** The naive check is "is it Friday 16:20 right now",
///     which is false essentially always — the phone is asleep at 16:20. `isDue` compares the
///     cache against the MOST RECENT scheduled instant instead, so a Friday that went by while the
///     app was closed refreshes on Monday rather than waiting for the next Friday.
///  2. **A REFRESH LOOP.** If due-ness were computed against a rolling window rather than a fixed
///     instant, the pass that just ran could still read as due and re-run on the next read — two
///     full catalog sweeps back to back, forever. `testRefreshingClearsDuenessForEveryCadence`
///     pins that shut for all five cadences.
///  3. **THE SETTING SILENTLY RESETS EVERYTHING ELSE.** A non-optional field added to
///     `SettingsData` fails the decode of every existing blob, and `load` falls back to `.default`
///     — wiping the user's sources, servers and keys. The persistence tests below are the guard.
///
/// Every case runs against a FIXED Gregorian calendar in a FIXED zone. `.current` would make the
/// weekday and DST arithmetic depend on the machine running the suite.
final class ForYouRefreshScheduleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// A local wall-clock instant in the fixed zone.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.date(from: c)!
    }

    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    private func due(now: Date, last: Date?, cadence: ForYouRefreshCadence,
                     minutes: Int = ForYouRefreshSchedule.defaultMinutes,
                     weekday: Int = ForYouRefreshSchedule.defaultWeekday) -> Bool {
        ForYouRefreshSchedule.isDue(nowMs: ms(now),
                                    lastRefreshedAtMs: last.map(ms) ?? 0,
                                    cadence: cadence, minutesOfDay: minutes,
                                    weekday: weekday, calendar: cal)
    }

    // ── Sanity on the fixture: 2026-08-07 must really be a Friday ───────────────────────────────

    func testFixtureCalendarWeekdays() {
        // Calendar numbering: 1 = Sunday … 6 = Friday.
        XCTAssertEqual(cal.component(.weekday, from: at(2026, 8, 7)), 6, "2026-08-07 is a Friday")
        XCTAssertEqual(ForYouRefreshSchedule.defaultWeekday, 6)
        XCTAssertEqual(ForYouRefreshSchedule.defaultMinutes, 16 * 60 + 20, "4:20 PM")
        XCTAssertEqual(ForYouRefreshSchedule.defaultCadence, .weekly)
    }

    // ── manual ─────────────────────────────────────────────────────────────────────────────────

    /// `.manual` preserves the SHIPPED behaviour (refresh only from the ⋯ menu). It must never
    /// report due — not even with a cache from last year, and not even with no cache at all.
    func testManualIsNeverDue() {
        XCTAssertFalse(due(now: at(2026, 8, 7, 23, 59), last: at(2025, 1, 1), cadence: .manual))
        XCTAssertFalse(due(now: at(2026, 8, 7, 23, 59), last: nil, cadence: .manual))
        XCTAssertNil(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 23, 59), cadence: .manual,
                                                    minutesOfDay: 980, weekday: 6, calendar: cal))
        XCTAssertNil(ForYouRefreshSchedule.nextFire(after: at(2026, 8, 7), cadence: .manual,
                                                    minutesOfDay: 980, weekday: 6, calendar: cal))
    }

    // ── weekly (the default: Friday 16:20) ─────────────────────────────────────────────────────

    func testWeeklyFiresOnlyAfterFridayFireTime() {
        // Thursday's cache, one minute BEFORE Friday 16:20 → not yet.
        XCTAssertFalse(due(now: at(2026, 8, 7, 16, 19), last: at(2026, 8, 6, 9), cadence: .weekly))
        // One minute after → due.
        XCTAssertTrue(due(now: at(2026, 8, 7, 16, 21), last: at(2026, 8, 6, 9), cadence: .weekly))
    }

    /// THE MISSED-SLOT CASE. Friday 16:20 passed while the app was closed; the owner opens it on
    /// Monday. He must get a fresh feed then — not five more days of the old one.
    func testWeeklyMissedSlotFiresOnNextRead() {
        let lastRefresh = at(2026, 8, 5, 10)          // Wednesday
        XCTAssertTrue(due(now: at(2026, 8, 10, 8), last: lastRefresh, cadence: .weekly),
                      "a Friday missed while the app was closed must fire on Monday")
    }

    func testWeeklyNotDueAgainUntilTheFollowingFriday() {
        let refreshedAtFire = at(2026, 8, 7, 16, 20)  // Friday, right on the slot
        XCTAssertFalse(due(now: at(2026, 8, 8, 12), last: refreshedAtFire, cadence: .weekly))
        XCTAssertFalse(due(now: at(2026, 8, 13, 23, 59), last: refreshedAtFire, cadence: .weekly))
        XCTAssertTrue(due(now: at(2026, 8, 14, 16, 21), last: refreshedAtFire, cadence: .weekly),
                      "next Friday's slot")
    }

    /// The weekday is configurable; the walk-back must find the right one. Sunday = 1.
    func testWeeklyHonoursAChosenWeekday() {
        // Sunday 2026-08-09. On Saturday the most recent Sunday fire is a week earlier.
        XCTAssertTrue(due(now: at(2026, 8, 9, 17), last: at(2026, 8, 4), cadence: .weekly, weekday: 1))
        XCTAssertFalse(due(now: at(2026, 8, 9, 17), last: at(2026, 8, 9, 16, 30),
                           cadence: .weekly, weekday: 1))
    }

    /// TODAY IS THE TARGET WEEKDAY BUT THE FIRE TIME IS STILL AHEAD. The walk-back has to reach
    /// back a full week rather than returning nothing (which would read as "never due").
    func testWeeklyBeforeTodaysFireUsesLastWeeksSlot() {
        let fire = ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 9), cadence: .weekly,
                                                  minutesOfDay: 980, weekday: 6, calendar: cal)
        XCTAssertEqual(fire, at(2026, 7, 31, 16, 20), "the previous Friday's 16:20")
    }

    // ── daily ──────────────────────────────────────────────────────────────────────────────────

    func testDailyFiresOncePastTheChosenTime() {
        XCTAssertFalse(due(now: at(2026, 8, 7, 16, 19), last: at(2026, 8, 6, 17), cadence: .daily))
        XCTAssertTrue(due(now: at(2026, 8, 7, 16, 21), last: at(2026, 8, 6, 17), cadence: .daily))
        // Already refreshed after today's slot.
        XCTAssertFalse(due(now: at(2026, 8, 7, 20), last: at(2026, 8, 7, 16, 30), cadence: .daily))
    }

    func testDailyBeforeTodaysFireUsesYesterdays() {
        let fire = ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 3), cadence: .daily,
                                                  minutesOfDay: 980, weekday: 6, calendar: cal)
        XCTAssertEqual(fire, at(2026, 8, 6, 16, 20))
    }

    // ── hourly ─────────────────────────────────────────────────────────────────────────────────

    /// Hourly rides the MINUTE half of the chosen time (":20 past every hour" for the 4:20
    /// default) rather than a rolling 60-minute timer, so the readout stays predictable.
    func testHourlyFiresAtTheChosenMinutePastEachHour() {
        XCTAssertEqual(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 10, 25),
                                                      cadence: .hourly, minutesOfDay: 980,
                                                      weekday: 6, calendar: cal),
                       at(2026, 8, 7, 10, 20))
        // Before this hour's :20 → the previous hour's.
        XCTAssertEqual(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 10, 5),
                                                      cadence: .hourly, minutesOfDay: 980,
                                                      weekday: 6, calendar: cal),
                       at(2026, 8, 7, 9, 20))
        XCTAssertTrue(due(now: at(2026, 8, 7, 10, 25), last: at(2026, 8, 7, 9, 30), cadence: .hourly))
        XCTAssertFalse(due(now: at(2026, 8, 7, 10, 25), last: at(2026, 8, 7, 10, 22), cadence: .hourly))
    }

    // ── monthly ────────────────────────────────────────────────────────────────────────────────

    func testMonthlyFiresOnTheFirstAtTheChosenTime() {
        XCTAssertEqual(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 15), cadence: .monthly,
                                                      minutesOfDay: 980, weekday: 6, calendar: cal),
                       at(2026, 8, 1, 16, 20))
        XCTAssertTrue(due(now: at(2026, 8, 15), last: at(2026, 7, 20), cadence: .monthly))
        XCTAssertFalse(due(now: at(2026, 8, 15), last: at(2026, 8, 3), cadence: .monthly))
        // Before this month's slot → last month's.
        XCTAssertEqual(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 1, 9), cadence: .monthly,
                                                      minutesOfDay: 980, weekday: 6, calendar: cal),
                       at(2026, 7, 1, 16, 20))
    }

    // ── invariants ─────────────────────────────────────────────────────────────────────────────

    /// A COLD CACHE (`refreshedAtMs == 0`) is due under every real cadence — the tab has nothing
    /// to show and must build one.
    func testNeverRefreshedIsDueUnderEveryRealCadence() {
        for c in ForYouRefreshCadence.allCases where c != .manual {
            XCTAssertTrue(due(now: at(2026, 8, 7, 18), last: nil, cadence: c), "\(c) on a cold cache")
        }
    }

    /// NO LOOP. A completed refresh stamps `refreshedAtMs = now`, and `now >= lastFire` always, so
    /// the very next read is not due. Without this the schedule would re-run two full catalog
    /// sweeps on every foreground.
    func testRefreshingClearsDuenessForEveryCadence() {
        let now = at(2026, 8, 7, 16, 21)
        for c in ForYouRefreshCadence.allCases {
            XCTAssertFalse(due(now: now, last: now, cadence: c),
                           "\(c) must not still be due immediately after a refresh")
        }
    }

    func testNextFireIsAlwaysAheadAndSpacedByCadence() {
        let now = at(2026, 8, 7, 16, 21)
        for c in ForYouRefreshCadence.allCases where c != .manual {
            let next = ForYouRefreshSchedule.nextFire(after: now, cadence: c, minutesOfDay: 980,
                                                      weekday: 6, calendar: cal)
            XCTAssertNotNil(next, "\(c)")
            XCTAssertGreaterThan(next!, now, "\(c) next fire must be in the future")
        }
        XCTAssertEqual(ForYouRefreshSchedule.nextFire(after: now, cadence: .weekly, minutesOfDay: 980,
                                                      weekday: 6, calendar: cal),
                       at(2026, 8, 14, 16, 20))
        XCTAssertEqual(ForYouRefreshSchedule.nextFire(after: now, cadence: .hourly, minutesOfDay: 980,
                                                      weekday: 6, calendar: cal),
                       at(2026, 8, 7, 17, 20))
    }

    /// Out-of-range inputs are CLAMPED, not trapped — a corrupt blob must not crash the tab or
    /// make it permanently un-refreshable.
    func testOutOfRangeInputsAreClamped() {
        XCTAssertNotNil(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 23), cadence: .daily,
                                                       minutesOfDay: -50, weekday: 6, calendar: cal))
        XCTAssertNotNil(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 23), cadence: .daily,
                                                       minutesOfDay: 99_999, weekday: 6, calendar: cal))
        XCTAssertNotNil(ForYouRefreshSchedule.lastFire(before: at(2026, 8, 7, 23), cadence: .weekly,
                                                       minutesOfDay: 980, weekday: 42, calendar: cal))
        XCTAssertFalse(ForYouRefreshSchedule.weekdayName(6).isEmpty)
    }
}

/// The SETTING itself: defaults, clamping, round-trip, and — the one that matters — that adding it
/// cannot wipe an existing install's settings.
@MainActor
final class ForYouRefreshSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    func testDefaultsAreWeeklyFridayAt420PM() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(s.forYouRefreshCadence, .weekly)
        XCTAssertEqual(s.forYouRefreshMinutes, 16 * 60 + 20)
        XCTAssertEqual(s.forYouRefreshWeekday, 6)   // Friday
    }

    func testClampsAndRoundTrips() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.forYouRefreshMinutes = -1
        XCTAssertEqual(s.forYouRefreshMinutes, 0)
        s.forYouRefreshMinutes = 5000
        XCTAssertEqual(s.forYouRefreshMinutes, 1439)
        s.forYouRefreshWeekday = 0
        XCTAssertEqual(s.forYouRefreshWeekday, 1)
        s.forYouRefreshWeekday = 99
        XCTAssertEqual(s.forYouRefreshWeekday, 7)

        s.forYouRefreshCadence = .hourly
        s.forYouRefreshMinutes = 30
        s.forYouRefreshWeekday = 2
        s.persist()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.forYouRefreshCadence, .hourly)
        XCTAssertEqual(reloaded.forYouRefreshMinutes, 30)
        XCTAssertEqual(reloaded.forYouRefreshWeekday, 2)
    }

    /// AN EXISTING INSTALL'S BLOB HAS NO SUCH KEYS. It must decode fine, keep every other value,
    /// and land on the default cadence — the alternative (a failed decode) silently resets sources,
    /// server URLs and search keys to factory.
    func testOlderBlobWithoutTheKeysDecodesAndKeepsOtherSettings() {
        let defaults = freshDefaults()
        let seed = SettingsStore(defaults: defaults)
        seed.ripServerURL = "https://example.invalid"
        seed.persist()
        // Strip the new keys from the persisted blob, exactly as a pre-feature build wrote it.
        var blob = try! JSONSerialization.jsonObject(
            with: defaults.data(forKey: "pdj.settings.v1")!) as! [String: Any]
        blob.removeValue(forKey: "forYouRefreshCadence")
        blob.removeValue(forKey: "forYouRefreshMinutes")
        blob.removeValue(forKey: "forYouRefreshWeekday")
        defaults.set(try! JSONSerialization.data(withJSONObject: blob), forKey: "pdj.settings.v1")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.ripServerURL, "https://example.invalid", "other settings survived")
        XCTAssertEqual(reloaded.forYouRefreshCadence, .weekly)
        XCTAssertEqual(reloaded.forYouRefreshMinutes, 16 * 60 + 20)
        XCTAssertEqual(reloaded.forYouRefreshWeekday, 6)
    }

    /// A cadence string written by a NEWER build (or a corrupt one) falls back to the default
    /// rather than failing the whole decode.
    func testUnknownCadenceFallsBackToDefault() {
        let defaults = freshDefaults()
        SettingsStore(defaults: defaults).persist()
        var blob = try! JSONSerialization.jsonObject(
            with: defaults.data(forKey: "pdj.settings.v1")!) as! [String: Any]
        blob["forYouRefreshCadence"] = "fortnightly"
        defaults.set(try! JSONSerialization.data(withJSONObject: blob), forKey: "pdj.settings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).forYouRefreshCadence, .weekly)
    }

    /// The nuclear reset must put the schedule back to Friday 16:20 like every other value.
    func testResetEverythingRestoresTheDefault() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.forYouRefreshCadence = .monthly
        s.forYouRefreshMinutes = 61
        s.forYouRefreshWeekday = 3
        s.persist()
        s.resetEverything()
        XCTAssertEqual(s.forYouRefreshCadence, .weekly)
        XCTAssertEqual(s.forYouRefreshMinutes, 16 * 60 + 20)
        XCTAssertEqual(s.forYouRefreshWeekday, 6)
    }
}
