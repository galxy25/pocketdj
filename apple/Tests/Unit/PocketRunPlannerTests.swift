import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 5a — the run planner (§4.2), the live re-plan (§4.4–4.5, the Drake
/// scenario), the tuning fold (§4.6), and the W2 100-played-through invariant.
final class PocketRunPlannerTests: XCTestCase {

    // MARK: A synthetic catalog: Potential (R&B / hip-hop, Drake-heavy), Late Night, misc.

    static let rnbArtists = ["Drake", "Bryson Tiller", "6LACK", "dvsn", "Majid Jordan", "PARTYNEXTDOOR", "SZA",
                             "Frank Ocean", "Jhené Aiko", "Kehlani", "Brent Faiyaz", "Daniel Caesar"]
    static let otherArtists = (0..<24).map { "Artist \($0)" }

    static func candidate(_ id: String, artist: String, genre: String, bpm: Double, year: Int,
                          memberships: [String: Double], instant: Bool = false, camelot: String? = nil) -> PocketRunPlanner.Candidate {
        PocketRunPlanner.Candidate(id: id, title: id, artist: artist, lengthMs: 200_000,
                                   features: .init(artistKeys: RecVersionIdentity.creditArtistKeys(artist),
                                                   album: "alb_\(id.prefix(5))", genre: genre, year: year, bpm: bpm),
                                   camelot: camelot, memberships: memberships, startsInstantly: instant)
    }

    static func universe() -> [String: PocketRunPlanner.Candidate] {
        var out: [String: PocketRunPlanner.Candidate] = [:]
        for i in 0..<160 {
            let artist = rnbArtists[i % rnbArtists.count]
            let id = "pot_\(i)"
            out[id] = candidate(id, artist: artist, genre: i % 4 == 0 ? "hip-hop" : "r&b", bpm: 86 + Double(i % 9) * 3,
                                year: 2012 + i % 10, memberships: ["pl_pot": 1], instant: i % 7 == 0,
                                camelot: "\(i % 12 + 1)A")
        }
        // Drake features on other people's songs (the ban is on credit keys).
        out["feat_1"] = candidate("feat_1", artist: "Rihanna feat. Drake", genre: "r&b", bpm: 92, year: 2016, memberships: ["pl_pot": 1])
        for i in 0..<80 {
            let id = "late_\(i)"
            out[id] = candidate(id, artist: otherArtists[i % 12], genre: "electronic", bpm: 70 + Double(i % 10) * 2,
                                year: 1994 + i % 8, memberships: ["pkt_late": 1])
        }
        for i in 0..<120 {
            let id = "misc_\(i)"
            out[id] = candidate(id, artist: otherArtists[12 + i % 12], genre: i % 2 == 0 ? "r&b" : "rock", bpm: 100 + Double(i % 5),
                                year: 2014 + i % 6, memberships: [:])
        }
        return out
    }

    static func profile() -> PocketProfile {
        PocketProfile(tier: .rich, key: .init(hour: 8, dow: 2, mode: .carPlay), momentKeys: [.init(hour: 8, dow: 2, mode: .carPlay)],
                      caption: "Tue 8 AM · CarPlay", detail: "Potential · 23 plays",
                      collections: ["pl_pot": 0.7, "pkt_late": 0.3],
                      artists: Dictionary(uniqueKeysWithValues: rnbArtists.prefix(6).map { ($0.lowercased(), 1.0 / 6) }),
                      genres: ["r&b": 0.6, "hip-hop": 0.3, "electronic": 0.1],
                      bpmLo: 88, bpmHi: 100, eraLo: 2012, eraHi: 2022, mode: .carPlay)
    }

    private func plan(seed: UInt64 = 42, excluded: Set<String> = [], tuning: PocketTuning.Multipliers = .neutral) -> PocketRunPlanner.Plan {
        PocketRunPlanner.plan(.init(profile: Self.profile(), candidates: Self.universe(), excluded: excluded, tuning: tuning, seed: seed))
    }

    // MARK: Plan

    func testHundredSlotsUniqueSongs() {
        let p = plan()
        XCTAssertEqual(p.rows.count, 100)
        XCTAssertEqual(Set(p.rows.map(\.songId)).count, 100)
        XCTAssertEqual(p.rows.map(\.slot), Array(1...100))
        XCTAssertTrue(Set(p.bench.map(\.songId)).isDisjoint(with: p.rows.map(\.songId)), "the bench holds what wasn't placed")
        XCTAssertFalse(p.bench.isEmpty)
    }

    func testCollectionQuotaKeepsTheRunAboutItsColour() {
        let p = plan()
        let pot = p.rows.filter { $0.collectionId == "pl_pot" }.count
        let late = p.rows.filter { $0.collectionId == "pkt_late" }.count
        XCTAssertGreaterThanOrEqual(pot, 40, "dominant collection ≥ 40 %")
        XCTAssertGreaterThan(pot, late)
        XCTAssertGreaterThan(late, 0, "the second collection gets its share")
        XCTAssertEqual(PocketRunPlanner.quotas(profile: Self.profile(), slots: 100), ["pl_pot": 70, "pkt_late": 30])
        var thin = Self.profile(); thin.collections = ["a": 0.3, "b": 0.35, "c": 0.35]
        XCTAssertEqual(PocketRunPlanner.quotas(profile: thin, slots: 100)["b"].map { $0 >= 35 } ?? false, true)
    }

    func testArtistCapSpacingAndNewcomerFloor() {
        let p = plan()
        let u = Self.universe()
        var counts: [String: Int] = [:]
        let keys = p.rows.map { u[$0.songId]!.features.artistKeys }
        for k in keys.joined() { counts[k, default: 0] += 1 }
        XCTAssertLessThanOrEqual(counts.values.max() ?? 0, PocketRunPlanner.artistCap, "≤ 6 per artist")
        for i in 1..<keys.count {
            for j in max(0, i - 3)..<i {
                XCTAssertTrue(Set(keys[i]).isDisjoint(with: keys[j]), "no artist twice within 4 slots (\(j + 1)→\(i + 1))")
            }
        }
        let top = Set(Self.profile().artists.keys)
        let newcomers = keys.filter { !$0.contains(where: top.contains) }.count
        XCTAssertGreaterThanOrEqual(newcomers, 20, "≥ 20 % newcomers")
    }

    func testDeterministicBySeedAndInstantFirstRows() {
        XCTAssertEqual(plan(seed: 7), plan(seed: 7))
        XCTAssertNotEqual(plan(seed: 7).rows.map(\.songId), plan(seed: 8).rows.map(\.songId))
        let u = Self.universe()
        for r in plan().rows.prefix(3) { XCTAssertTrue(u[r.songId]!.startsInstantly, "first audio is instant (\(r.songId))") }
    }

    func testExclusionsAndBans() {
        let excluded: Set<String> = ["pot_0", "pot_1", "pot_2"]
        var t = PocketTuning.Multipliers()
        t.bannedArtists = ["drake"]
        let p = plan(excluded: excluded, tuning: t)
        let u = Self.universe()
        XCTAssertTrue(Set(p.rows.map(\.songId)).isDisjoint(with: excluded))
        XCTAssertFalse(p.rows.contains { u[$0.songId]!.features.artistKeys.contains("drake") }, "banned incl. features")
    }

    // MARK: The Drake scenario (§4.5)

    func testDrakeFastSkipBansAndReplacesUpcomingDrakeWithSimilarOtherArtists() {
        let u = Self.universe()
        let p = plan()
        let drakeRows = p.rows.filter { u[$0.songId]!.features.artistKeys.contains("drake") }
        XCTAssertGreaterThanOrEqual(drakeRows.count, 2, "precondition: Drake is in the run")
        let first = drakeRows[0]
        // Fast skip at 0:20 / 4:10 → strength −1.0.
        let v = PocketTuning.Verdict(songId: first.songId, skipped: true, fraction: 0.08, atMs: 0,
                                     momentKey: "h08|d2|carPlay", rowCollectionId: first.collectionId)
        XCTAssertEqual(v.strength, -1.0)
        let ev = PocketTuning.runEvidence([v], features: { u[$0]?.features })
        let m = PocketTuning.multipliers(ev, allowBans: true)
        XCTAssertEqual(m.byKey["artist:drake"] ?? 1, 0.333, accuracy: 0.001)
        XCTAssertTrue(m.bannedArtists.contains("drake"))
        let genreKey = "genre:" + (u[first.songId]!.features.genre ?? "")
        XCTAssertEqual(m.byKey[genreKey] ?? 1, 0.667, accuracy: 0.001, "the genre drops one notch")
        XCTAssertEqual(m.byKey["collection:pl_pot"] ?? 1, 0.8, accuracy: 0.001, "the colour barely moves")

        // Re-plan every upcoming row after the skipped one.
        let upcoming = p.rows.filter { $0.slot > first.slot }
        let live = upcoming.map { PocketRunPlanner.LiveRow(uid: UUID(), songId: $0.songId, slot: $0.slot, collectionId: $0.collectionId) }
        var neighbours: [UUID: (prev: String?, next: String?)] = [:]
        for (i, r) in live.enumerated() {
            neighbours[r.uid] = (i > 0 ? live[i - 1].songId : nil, i + 1 < live.count ? live[i + 1].songId : nil)
        }
        let result = PocketRunPlanner.replan(profile: Self.profile(), candidates: u, tuning: m, familiarity: [:],
                                             live: live, inRun: Set(p.rows.map(\.songId)), neighbours: neighbours)
        XCTAssertEqual(result.banned, ["drake"])
        let byUid = Dictionary(uniqueKeysWithValues: result.replacements.map { ($0.uid, $0) })
        for r in live where u[r.songId]!.features.artistKeys.contains("drake") {
            guard let rep = byUid[r.uid] else {
                XCTAssertTrue(result.removals.contains(r.uid)); continue
            }
            let x = u[rep.songId]!
            XCTAssertFalse(x.features.artistKeys.contains("drake"), "no Drake, no Drake features")
            XCTAssertEqual(rep.slot, r.slot, "slot-wise substitution keeps the arc")
            XCTAssertEqual(x.features.genre.map { ["r&b", "hip-hop"].contains($0) }, true, "musically similar (\(rep.songId))")
            XCTAssertFalse(Set(p.rows.map(\.songId)).contains(rep.songId), "never a song already in the run")
        }
        XCTAssertFalse(result.replacements.contains { $0.songId == "feat_1" }, "Rihanna feat. Drake is banned too")
        XCTAssertEqual(Set(result.replacements.map(\.songId)).count, result.replacements.count, "no duplicate replacements")
    }

    func testRowsAreRemovedWhenNothingClearsTheFitFloor() {
        // A tiny universe: the only candidates are banned or already in the run.
        var u: [String: PocketRunPlanner.Candidate] = [:]
        u["d1"] = Self.candidate("d1", artist: "Drake", genre: "r&b", bpm: 90, year: 2016, memberships: ["pl_pot": 1])
        u["d2"] = Self.candidate("d2", artist: "Drake", genre: "r&b", bpm: 92, year: 2017, memberships: ["pl_pot": 1])
        var t = PocketTuning.Multipliers(); t.bannedArtists = ["drake"]
        let row = PocketRunPlanner.LiveRow(uid: UUID(), songId: "d2", slot: 5, collectionId: "pl_pot")
        let r = PocketRunPlanner.replan(profile: Self.profile(), candidates: u, tuning: t, familiarity: [:], live: [row],
                                        inRun: ["d1", "d2"], neighbours: [:])
        XCTAssertEqual(r.removals, [row.uid])
        XCTAssertTrue(r.replacements.isEmpty)
    }

    func testInFlightRipRowsTakeOnlyInstantReplacements() {
        let u = Self.universe()
        var t = PocketTuning.Multipliers(); t.bannedArtists = ["drake"]
        let row = PocketRunPlanner.LiveRow(uid: UUID(), songId: "pot_0", slot: 9, collectionId: "pl_pot", requiresInstant: true)
        let r = PocketRunPlanner.replan(profile: Self.profile(), candidates: u, tuning: t, familiarity: [:], live: [row],
                                        inRun: ["pot_0"], neighbours: [:])
        let rep = try! XCTUnwrap(r.replacements.first)
        XCTAssertTrue(u[rep.songId]!.startsInstantly)
    }

    func testTopUpRespectsBansCapAndRun() {
        let u = Self.universe()
        var t = PocketTuning.Multipliers(); t.bannedArtists = ["drake"]
        let picks = PocketRunPlanner.topUp(count: 5, profile: Self.profile(), candidates: u, tuning: t, familiarity: [:],
                                           inRun: ["pot_1", "pot_13"], tail: ["pot_13"])
        XCTAssertEqual(picks.count, 5)
        XCTAssertFalse(picks.contains { u[$0.songId]!.features.artistKeys.contains("drake") })
        XCTAssertFalse(picks.contains { ["pot_1", "pot_13"].contains($0.songId) })
    }

    // MARK: W2 — 100 played-through

    func testRowsNeededInvariant() {
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 0, currentIsRun: true, currentFraction: 0.1), 99)
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 49, currentIsRun: true, currentFraction: 0.2), 50)
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 99, currentIsRun: true, currentFraction: 0.5), 1,
                       "the 100th is playing: keep a spare in case it's skipped")
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 99, currentIsRun: true, currentFraction: 0.95), 0,
                       "…and drop it once the 100th can no longer be a skip — STOP at 100")
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 100, currentIsRun: false, currentFraction: nil), 0)
        XCTAssertEqual(PocketRunStore.rowsNeeded(target: 100, playedThrough: 10, currentIsRun: false, currentFraction: nil), 90)
    }
}

/// §4.6 — what carries into future runs.
final class PocketTuningTests: XCTestCase {

    private let day = 86_400_000.0
    private func features(_ id: String) -> PocketTuning.Features? {
        ["s1": .init(artistKeys: ["drake"], genre: "r&b"), "s2": .init(artistKeys: ["sza"], genre: "r&b")][id]
    }
    private func v(_ song: String, skipped: Bool, f: Double?, at: Double, key: String) -> PocketTuning.Verdict {
        .init(songId: song, skipped: skipped, fraction: f, atMs: at, momentKey: key, rowCollectionId: nil)
    }

    func testStrengths() {
        XCTAssertEqual(v("s", skipped: true, f: 0.1, at: 0, key: "").strength, -1.0)
        XCTAssertEqual(v("s", skipped: true, f: 0.3, at: 0, key: "").strength, -0.6)
        XCTAssertEqual(v("s", skipped: false, f: 0.95, at: 0, key: "").strength, 0.5)
        XCTAssertEqual(v("s", skipped: false, f: 0.7, at: 0, key: "").strength, 0.2)
        XCTAssertNil(v("s", skipped: false, f: nil, at: 0, key: "").strength)
    }

    func testFoldWeightsOwnRelatedGlobalAndDecay() {
        let now = 100 * day
        let own = PocketMomentKey(hour: 8, dow: 2, mode: .carPlay)
        let fold = { (key: String, at: Double) in
            PocketTuning.fold(verdicts: [self.v("s1", skipped: true, f: 0.1, at: at, key: key)], for: own, nowMs: now,
                              features: self.features).neg["artist:drake"] ?? 0
        }
        XCTAssertEqual(fold("h08|d2|carPlay", now), 1.0, accuracy: 1e-9, "own moment ×1")
        XCTAssertEqual(fold("h08|d3|carPlay", now), 0.5, accuracy: 1e-9, "Wed 8 AM CarPlay is related ×0.5")
        XCTAssertEqual(fold("h09|d2|carPlay", now), 0.5, accuracy: 1e-9, "±1 h related")
        XCTAssertEqual(fold("h08|d2|trip", now), 0.5, accuracy: 1e-9, "related mode")
        XCTAssertEqual(fold("h21|d6|mix", now), 0.15, accuracy: 1e-9, "a global aversion leaks in gently")
        XCTAssertEqual(fold("h08|d2|carPlay", now - 30 * day), 0.5, accuracy: 1e-9, "30-day half-life")
    }

    func testBansDoNotPersistAcrossRuns() {
        let e = PocketTuning.fold(verdicts: [v("s1", skipped: true, f: 0.1, at: 0, key: "h08|d2|carPlay")],
                                  for: PocketMomentKey(hour: 8, dow: 2, mode: .carPlay), nowMs: 0, features: features)
        let next = PocketTuning.multipliers(e, allowBans: false)
        XCTAssertTrue(next.bannedArtists.isEmpty, "W5: run-only ban")
        XCTAssertEqual(next.byKey["artist:drake"] ?? 1, 0.333, accuracy: 0.001, "…but rarer next time")
        XCTAssertTrue(PocketTuning.multipliers(e, allowBans: true).bannedArtists.contains("drake"))
        // Two ordinary skips also ban; one does not.
        let two = PocketTuning.runEvidence([v("s1", skipped: true, f: 0.3, at: 0, key: ""), v("s1", skipped: true, f: 0.3, at: 0, key: "")],
                                           features: features)
        XCTAssertTrue(PocketTuning.multipliers(two, allowBans: true).bannedArtists.contains("drake"))
        let one = PocketTuning.runEvidence([v("s1", skipped: true, f: 0.3, at: 0, key: "")], features: features)
        XCTAssertFalse(PocketTuning.multipliers(one, allowBans: true).bannedArtists.contains("drake"))
    }

    func testVerdictsFromHistoryAndRelatedness() {
        let run = UUID()
        var e = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s1_clean", playedAt: 5, source: .pocket, contextId: nil,
                                           contextName: nil, title: nil, artist: nil, originInstallId: nil)
        e.pocketRun = PocketRunTag(runId: run, momentKey: "h08|d2|carPlay", rowCollectionId: "pl", slot: 3)
        e.wasSkipped = true
        let plain = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s2", playedAt: 6, source: .pocket, contextId: nil,
                                               contextName: nil, title: nil, artist: nil, originInstallId: nil)
        let vs = PocketTuning.verdicts(from: [e, plain])
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs[0].verdict.songId, "s1_clean".hasSuffix("_clean") ? SongVariant.baseId("s1_clean") : "s1_clean")
        XCTAssertTrue(PocketTuning.verdicts(from: [e], excludingRun: run).isEmpty)
        let a = PocketMomentKey(hour: 8, dow: 2, mode: .carPlay)
        XCTAssertTrue(PocketTuning.isRelated(a, .init(hour: 10, dow: 2, mode: .carPlay)))
        XCTAssertFalse(PocketTuning.isRelated(a, .init(hour: 11, dow: 2, mode: .carPlay)))
        XCTAssertFalse(PocketTuning.isRelated(a, .init(hour: 8, dow: 6, mode: .carPlay)), "weekday ≠ weekend")
        XCTAssertFalse(PocketTuning.isRelated(a, a))
    }
}
