import XCTest
@testable import PocketDJ

/// CROSS-PLATFORM GOLDEN DUMP for the Pocket Wheel (P2-POC-14) — the fixture is the law both the
/// iOS and the Android implementations are held to (the `timbre-parity.json` precedent).
///
/// OPT-IN: skipped unless `PDJ_DUMP_PARITY=1` (xcodebuild forwards it as
/// `TEST_RUNNER_PDJ_DUMP_PARITY=1`). When enabled it writes
/// `apple/Tests/Fixtures/pocket-wheel-parity.json` next to this source tree from the REAL Swift
/// implementation (no third copy of the maths). Android's `PocketWheelParityGoldenTest` replays the same
/// inputs and must match to 1e-9 (exact ids / tokens / strings).
///
/// Inputs: the shared 3-week `pocket-wheel-history.json` (moments, best match) and the synthetic
/// catalogue of `PocketRunPlannerTests.universe()` (first-100 rows, the post-Drake re-plan).
final class PocketWheelParityDumpTests: XCTestCase {

    private static let outURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/pocket-wheel-parity.json")

    func testDumpPocketWheelParityFixture() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PDJ_DUMP_PARITY"] == "1" || env["TEST_RUNNER_PDJ_DUMP_PARITY"] == "1",
                          "opt-in: set PDJ_DUMP_PARITY=1 to regenerate pocket-wheel-parity.json")

        let fixture = try PocketMomentEngineTests.loadFixture()
        let snap = PocketMomentEngine.build(PocketMomentEngineTests.input(fixture))

        var doc: [String: Any] = ["v": 1, "nowMs": fixture.nowMs]
        doc["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap))

        // Best match at fixed Nows (wheel-only; no fallbacks → rich / neighbourhood / history tiers).
        typealias N = PocketBestMatch.Now
        let nows: [(String, N)] = [
            ("tue-8:30-carplay", N(hour: 8.5, dow: 2, mode: .carPlay, ctx: nil)),
            ("sat-9:12-running", N(hour: 9.2, dow: 6, mode: .running, ctx: nil)),
            ("wed-21:18-unknown", N(hour: 21.3, dow: 3, mode: nil, ctx: nil)),
            ("wed-12:30-unknown", N(hour: 12.5, dow: 3, mode: nil, ctx: nil)),
            ("sun-15:30-trip-ctx", N(hour: 15.5, dow: 7, mode: .trip, ctx: "trip:trp_ab")),
            ("fri-3:00-unknown", N(hour: 3.0, dow: 5, mode: nil, ctx: nil)),
            ("mon-23:50-mix", N(hour: 23.83, dow: 1, mode: .mix, ctx: nil)),
            ("continuity-skips", N(hour: 12.5, dow: 3, mode: nil, ctx: nil,
                                   recentCollections: ["pkt_chill": 1.0], recentSkipRate: 0.6)),
        ]
        func profileDump(_ p: PocketProfile) -> [String: Any] {
            var d: [String: Any] = ["tier": p.tier.rawValue, "caption": p.caption, "detail": p.detail,
                                    "momentKeys": p.momentKeys.map(\.token),
                                    "collections": p.collections, "artists": p.artists, "genres": p.genres]
            if let k = p.key { d["key"] = k.token }
            if let m = p.mode { d["mode"] = m.rawValue }
            if let c = p.dominantCollectionId { d["dominantCollectionId"] = c }
            if let v = p.bpmLo { d["bpmLo"] = v }
            if let v = p.bpmHi { d["bpmHi"] = v }
            if let v = p.eraLo { d["eraLo"] = v }
            if let v = p.eraHi { d["eraHi"] = v }
            return d
        }
        doc["bestMatch"] = nows.map { (name, now) -> [String: Any] in
            let r = PocketBestMatch.best(snapshot: snap, now: now)
            var nd: [String: Any] = ["hour": now.hour, "dow": now.dow, "recentCollections": now.recentCollections]
            if let m = now.mode { nd["mode"] = m.rawValue }
            if let c = now.ctx { nd["ctx"] = c }
            if let s = now.recentSkipRate { nd["recentSkipRate"] = s }
            var out: [String: Any] = ["name": name, "now": nd, "profile": profileDump(r.profile),
                                      "alternatives": r.alternatives.map(profileDump)]
            if let w = r.winner {
                out["winner"] = ["key": w.key.token, "match": w.match, "quality": w.quality,
                                 "continuity": w.continuity, "score": w.score]
            }
            return out
        }

        // First 100 rows for fixed seeds on the synthetic catalogue.
        let universe = PocketRunPlannerTests.universe()
        let profile = PocketRunPlannerTests.profile()
        func rowDump(_ r: PocketRunPlanner.Row) -> [String: Any] {
            var d: [String: Any] = ["songId": r.songId, "slot": r.slot, "score": r.score]
            if let c = r.collectionId { d["collectionId"] = c }
            return d
        }
        var runs: [[String: Any]] = []
        for seed: UInt64 in [42, 7] {
            let p = PocketRunPlanner.plan(.init(profile: profile, candidates: universe, tuning: .neutral, seed: seed))
            runs.append(["seed": seed, "rows": p.rows.map(rowDump),
                         "bench": p.bench.prefix(25).map { ["songId": $0.songId, "score": $0.score] as [String: Any] },
                         "benchCount": p.bench.count])
        }
        doc["runs"] = runs

        // The Drake scenario: fast skip of the first Drake row bans him; re-plan every upcoming row.
        let plan = PocketRunPlanner.plan(.init(profile: profile, candidates: universe, tuning: .neutral, seed: 42))
        let first = try XCTUnwrap(plan.rows.first { universe[$0.songId]!.features.artistKeys.contains("drake") })
        let verdict = PocketTuning.Verdict(songId: first.songId, skipped: true, fraction: 0.08, atMs: 0,
                                           momentKey: "h08|d2|carPlay", rowCollectionId: first.collectionId)
        let ev = PocketTuning.runEvidence([verdict], features: { universe[$0]?.features })
        let mult = PocketTuning.multipliers(ev, allowBans: true)
        let upcoming = plan.rows.filter { $0.slot > first.slot }
        func uid(_ slot: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", slot))! }
        let live = upcoming.map { PocketRunPlanner.LiveRow(uid: uid($0.slot), songId: $0.songId, slot: $0.slot, collectionId: $0.collectionId) }
        var neighbours: [UUID: (prev: String?, next: String?)] = [:]
        for (i, r) in live.enumerated() {
            neighbours[r.uid] = (i > 0 ? live[i - 1].songId : nil, i + 1 < live.count ? live[i + 1].songId : nil)
        }
        let rp = PocketRunPlanner.replan(profile: profile, candidates: universe, tuning: mult, familiarity: [:],
                                         live: live, inRun: Set(plan.rows.map(\.songId)), neighbours: neighbours)
        let slotOf = Dictionary(uniqueKeysWithValues: live.map { ($0.uid, $0.slot) })
        doc["replan"] = [
            "seed": 42, "skippedSongId": first.songId, "skippedSlot": first.slot, "verdictStrength": verdict.strength ?? 0,
            "multipliers": mult.byKey, "bannedArtists": mult.bannedArtists.sorted(),
            "banned": rp.banned,
            "replacements": rp.replacements.map { r -> [String: Any] in
                var d: [String: Any] = ["slot": r.slot, "songId": r.songId, "score": r.score]
                if let c = r.collectionId { d["collectionId"] = c }
                return d
            },
            "removedSlots": rp.removals.compactMap { slotOf[$0] }.sorted(),
        ] as [String: Any]

        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.outURL, options: .atomic)
        print("PocketWheelParityDump wrote \(data.count) bytes to \(Self.outURL.path)")
        XCTAssertFalse(snap.moments.isEmpty)
    }
}
