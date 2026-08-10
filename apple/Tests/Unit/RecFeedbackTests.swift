import XCTest
@testable import PocketDJ

/// ACCEPT / REJECT — the store, the ranking's response to it, and the one-decision-model property
/// the whole two-mode design rests on.
///
/// The owner asked for BOTH modes: act on what is playing (deck / mini bar / CarPlay / widget /
/// lock screen) and come back to the tile later and work the list. The failure this file exists to
/// prevent is the obvious one for a feature shaped like that — two paths that can disagree, so a
/// thumbs-down given in the car is not there when the tile is opened. Every surface writes through
/// `RecFeedbackStore.toggle`, so the property is testable directly: same store, same function,
/// same rows.
///
/// The second thing it guards is the SPLIT between the two halves of a rejection, which is what
/// makes a mis-tap survivable:
///   · SUPPRESSION — scoped to one list, expires in seven days, sinks the row, never removes it.
///   · TASTE — global, decaying over years, only ever subtracts score, never removes anything.
@MainActor
final class RecFeedbackTests: XCTestCase {

    private var tempDir: URL!
    private func makeStore() -> RecFeedbackStore {
        RecFeedbackStore(fileURL: tempDir.appendingPathComponent("\(UUID().uuidString).json"))
    }

    private let day = 86_400_000.0
    private let crateA = "pkt_house"
    private let crateB = "pkt_soul"
    private let zone = ForYouTileRoute.Kind.zone.rawValue

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-feedback-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // ========================================================================
    // MARK: - The store: record, read, undo
    // ========================================================================

    func testRecordingAVerdictAndReadingItBack() {
        let s = makeStore()
        s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 1000)
        s.record(songId: "b", scope: crateA, verdict: .accepted, surface: .nowPlaying, at: 1000)

        XCTAssertEqual(s.verdict(songId: "a", scope: crateA), .rejected)
        XCTAssertEqual(s.verdict(songId: "b", scope: crateA), .accepted)
        XCTAssertNil(s.verdict(songId: "c", scope: crateA), "no opinion is not an opinion")
        XCTAssertTrue(s.isSuppressed(songId: "a", scope: crateA, nowMs: 1000))
        XCTAssertFalse(s.isSuppressed(songId: "b", scope: crateA, nowMs: 1000))
    }

    /// THE UNDO. Tapping a lit control again clears it — one function, so a driver's instinctive
    /// second tap means the same thing on the lock screen as on a tile row.
    ///
    /// It is recorded as a `cleared` ROW rather than a deletion, so a peer device holding the older
    /// `rejected` cannot resurrect it through the union merge.
    func testToggleFlipsAndTheSecondTapIsAnUndo() {
        let s = makeStore()
        XCTAssertEqual(s.toggle(songId: "a", to: .rejected, scope: crateA, surface: .tile, at: 1), .rejected)
        XCTAssertEqual(s.verdict(songId: "a", scope: crateA), .rejected)

        // Second 👎 = undo, not a second rejection.
        XCTAssertNil(s.toggle(songId: "a", to: .rejected, scope: crateA, surface: .tile, at: 2))
        XCTAssertNil(s.verdict(songId: "a", scope: crateA), "the row is neutral again")
        XCTAssertFalse(s.isSuppressed(songId: "a", scope: crateA, nowMs: 3), "and no longer sunk")
        XCTAssertTrue(s.decisions.contains { $0.verdict == "cleared" },
                      "the undo is a row, not a deletion — a peer's older opinion cannot win")

        // 👍 on a 👎 row FLIPS rather than clearing.
        XCTAssertEqual(s.toggle(songId: "a", to: .rejected, scope: crateA, surface: .tile, at: 4), .rejected)
        XCTAssertEqual(s.toggle(songId: "a", to: .accepted, scope: crateA, surface: .tile, at: 5), .accepted)
        XCTAssertEqual(s.verdict(songId: "a", scope: crateA), .accepted)
    }

    /// SAME-MILLISECOND TIES RESOLVE BY TAP ORDER.
    ///
    /// A UUID tie-break — the obvious move — decides a double-tap by a random number, and the
    /// double-tap IS the undo path: reject then immediately un-reject, both stamped in the same
    /// millisecond, and the surviving row is a coin flip. The per-device sequence makes it exact.
    func testTwoTapsInOneMillisecondResolveByTapOrderNotByRowId() {
        for _ in 0..<25 {              // repeat: a UUID tiebreak would pass this ~half the time
            let s = makeStore()
            s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 7_000)
            s.record(songId: "a", scope: crateA, verdict: .cleared, surface: .tile, at: 7_000)
            XCTAssertNil(s.verdict(songId: "a", scope: crateA),
                         "the LATER tap wins, even in the same millisecond")
        }
    }

    // ========================================================================
    // MARK: - Suppression is SCOPED and it EXPIRES
    // ========================================================================

    /// A reject in one crate must not silence the song anywhere else. "Suppression is local, taste
    /// is not" — this is the local half.
    func testARejectInOneListDoesNotSuppressTheSongInAnother() {
        let s = makeStore()
        s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 0)

        XCTAssertTrue(s.isSuppressed(songId: "a", scope: crateA, nowMs: 0))
        XCTAssertFalse(s.isSuppressed(songId: "a", scope: crateB, nowMs: 0), "another crate")
        XCTAssertFalse(s.isSuppressed(songId: "a", scope: zone, nowMs: 0), "nor In Da Zone")
        XCTAssertNil(s.verdict(songId: "a", scope: crateB), "and the glyph is hollow there")
        XCTAssertEqual(s.activeTombstones(scope: crateB, nowMs: 0).count, 0)

        // …but the TASTE half IS global: the rejection still teaches every list.
        XCTAssertNotNil(s.weights(.rejected, nowMs: 0)["a"])
    }

    /// THE SEVEN DAYS, derived at READ time from the stored stamp — never by a sweep. This app can
    /// go a month between launches, and a sweep that never fires leaves every rejected item buried
    /// forever, which is the permanent exclusion the rule exists to prevent.
    func testTheTombstoneExpiresButTheVerdictAndTheUndoDoNot() {
        let s = makeStore()
        s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 0)

        XCTAssertTrue(s.isSuppressed(songId: "a", scope: crateA, nowMs: 6 * day))
        XCTAssertFalse(s.isSuppressed(songId: "a", scope: crateA, nowMs: 8 * day),
                       "after seven days the song ranks normally again")
        XCTAssertFalse(s.isSuppressed(songId: "a", scope: crateA, nowMs: 400 * day),
                       "…and a month-closed app expires correctly on the first render")

        // THE VERDICT OUTLIVES THE TOMBSTONE. That is what keeps the undo control lit and
        // reachable indefinitely — the seven days govern the SINK, not the opinion.
        XCTAssertEqual(s.verdict(songId: "a", scope: crateA), .rejected,
                       "the 👎 stays lit so the mis-tap stays undoable")
        XCTAssertNil(s.toggle(songId: "a", to: .rejected, scope: crateA, surface: .tile, at: 400 * day),
                     "and tapping it five years later still clears it")
    }

    // ========================================================================
    // MARK: - The ranking rule: SINK, never filter — and re-inject
    // ========================================================================

    /// Rejected rows sink to the BOTTOM of their own list, in reject order, and the survivors keep
    /// the engine's order exactly.
    func testRankedIdsSinksRejectedRowsAndKeepsSurvivorOrder() {
        let s = makeStore()
        s.record(songId: "b", scope: crateA, verdict: .rejected, surface: .tile, at: 2000)
        s.record(songId: "d", scope: crateA, verdict: .rejected, surface: .tile, at: 1000)

        let out = s.rankedIds(["a", "b", "c", "d", "e"], scope: crateA, nowMs: 2000)
        XCTAssertEqual(Array(out.prefix(3)), ["a", "c", "e"], "survivors keep the engine's order")
        XCTAssertEqual(Array(out.suffix(2)), ["d", "b"], "sunk rows sit together, oldest reject first")
        XCTAssertEqual(Set(out), Set(["a", "b", "c", "d", "e"]), "nothing is lost")

        // After the window, the ordering is untouched again.
        XCTAssertEqual(s.rankedIds(["a", "b", "c", "d", "e"], scope: crateA, nowMs: 9 * day),
                       ["a", "b", "c", "d", "e"])
    }

    /// RE-INJECTION — the property that keeps a mis-tap recoverable.
    ///
    /// The engine has already DROPPED the tombstoned songs (they are passed to it as
    /// `ZoneEngine.Feedback.suppressed`), so without this the rejected row would simply vanish from
    /// the tile — taking the lit 👎 that undoes it with it, and leaving the only recovery "find
    /// that exact song somewhere else in the app and get it playing".
    func testATombstonedRowIsReAddedAtTheBottomEvenWhenTheEngineDroppedIt() {
        let s = makeStore()
        s.record(songId: "gone", scope: crateA, verdict: .rejected, surface: .tile, at: 1000)

        // The engine's output no longer contains "gone" at all.
        let out = s.rankedIds(["a", "b"], scope: crateA, nowMs: 1000)
        XCTAssertEqual(out, ["a", "b", "gone"], "the undo control is put back within reach")
        // …and it falls off by itself when the tombstone lapses.
        XCTAssertEqual(s.rankedIds(["a", "b"], scope: crateA, nowMs: 9 * day), ["a", "b"])
    }

    /// THE CARD AND THE LIST CANNOT DISAGREE. A tile that promises twelve suggestions must open on
    /// twelve — the defect that appears the moment the count is computed one way on the card and
    /// the rows another way on the screen.
    func testVisibleCountMatchesWhatTheListActuallyOffers() {
        let s = makeStore()
        s.record(songId: "b", scope: crateA, verdict: .rejected, surface: .tile, at: 1000)
        let ids = ["a", "b", "c"]

        let count = s.visibleCount(ids, scope: crateA, nowMs: 1000)
        let ranked = s.rankedIds(ids, scope: crateA, nowMs: 1000)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(ranked.prefix(count)), ["a", "c"],
                       "the first `visibleCount` rows are exactly the live offer")
        XCTAssertEqual(ranked.count, 3, "the sunk row is still on screen underneath it")
        // No feedback at all ⇒ the count is just the count.
        XCTAssertEqual(s.visibleCount(ids, scope: crateB, nowMs: 1000), 3)
    }

    // ========================================================================
    // MARK: - One decision model behind every entry point
    // ========================================================================

    /// A verdict given on ANY surface is immediately the answer every other surface reads. There is
    /// no synchronization step because there is only one copy.
    func testAVerdictFromAnySurfaceIsImmediatelyVisibleToEveryOther() {
        let s = makeStore()
        // The car.
        s.toggle(songId: "a", to: .rejected, scope: zone, surface: .carPlay, at: 100)
        XCTAssertEqual(s.verdict(songId: "a", scope: zone), .rejected)
        XCTAssertTrue(s.isSuppressed(songId: "a", scope: zone, nowMs: 100))

        // The tile, later, undoing it.
        XCTAssertNil(s.toggle(songId: "a", to: .rejected, scope: zone, surface: .tile, at: 200))
        XCTAssertNil(s.verdict(songId: "a", scope: zone))

        // A widget, on a different song.
        s.toggle(songId: "b", to: .accepted, scope: zone, surface: .widget, at: 300)
        XCTAssertEqual(s.verdict(songId: "b", scope: zone), .accepted)

        let surfaces = Set(s.decisions.map(\.surface))
        XCTAssertEqual(surfaces, ["carPlay", "tile", "widget"],
                       "every surface wrote to the SAME log")
    }

    /// The taste weight decays on the same half-life as every other recency signal, and is floored
    /// rather than zeroed so an old, consistent pattern still counts for something.
    func testVerdictWeightDecaysWithAge() {
        let s = makeStore()
        s.record(songId: "fresh", scope: crateA, verdict: .rejected, surface: .tile, at: 0)
        s.record(songId: "old", scope: crateA, verdict: .rejected, surface: .tile, at: -2000 * day)

        let w = s.weights(.rejected, nowMs: 0)
        XCTAssertEqual(w["fresh"] ?? 0, 1.0, accuracy: 0.01)
        XCTAssertLessThan(w["old"] ?? 1, w["fresh"] ?? 0)
        XCTAssertGreaterThanOrEqual(w["old"] ?? 0, 0.05, "floored, never zero")
    }

    /// The GLOBAL opinion is the latest verdict in ANY scope — rejecting a song in one crate and
    /// accepting it in another is a real thing a listener can do, and the later of the two is what
    /// they currently think.
    func testTheGlobalTasteSignalFollowsTheLatestVerdictAcrossScopes() {
        let s = makeStore()
        s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 100)
        XCTAssertNotNil(s.weights(.rejected, nowMs: 200)["a"])

        s.record(songId: "a", scope: crateB, verdict: .accepted, surface: .tile, at: 300)
        XCTAssertNil(s.weights(.rejected, nowMs: 400)["a"], "the later opinion supersedes")
        XCTAssertNotNil(s.weights(.accepted, nowMs: 400)["a"])
        // …while the SCOPED suppression in crate A is untouched: they are different mechanisms.
        XCTAssertTrue(s.isSuppressed(songId: "a", scope: crateA, nowMs: 400))
    }

    // ========================================================================
    // MARK: - Durability
    // ========================================================================

    /// A decision made in the car must survive the app being killed. `flush()` is the scenePhase
    /// `.background` path; this drives it and re-reads with a genuinely new store instance.
    func testDecisionsAndThePlayingScopeSurviveARelaunch() {
        let url = tempDir.appendingPathComponent("relaunch.json")
        do {
            let s = RecFeedbackStore(fileURL: url)
            s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .carPlay, at: 5000)
            s.beginPlayback(scope: crateA, songIds: ["a", "b"], at: 5000)
            s.flush()
        }
        let reopened = RecFeedbackStore(fileURL: url)
        XCTAssertEqual(reopened.verdict(songId: "a", scope: crateA), .rejected)
        XCTAssertTrue(reopened.isSuppressed(songId: "a", scope: crateA, nowMs: 5000),
                      "the seven days run from the ORIGINAL stamp, not from relaunch")
        // THE PLAYING SCOPE IS PERSISTED. A widget or lock-screen tap can be drained after a cold
        // launch; an in-memory-only scope would be nil by then and the verdict dropped exactly
        // when the listener could least tell.
        XCTAssertEqual(reopened.scope(forPlaying: "a"), crateA)
    }

    /// Union-by-id after a CloudSync pull; the later stamp wins per `(scope, song)`.
    func testCloudPullUnionsRowsAndResolvesByTime() throws {
        let url = tempDir.appendingPathComponent("sync.json")
        let mine = RecFeedbackStore(fileURL: url)
        mine.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 1000)
        mine.flush()

        // A peer's document: the same song, accepted LATER, plus a row we have never seen.
        let peer = RecFeedbackStore(fileURL: tempDir.appendingPathComponent("peer.json"))
        peer.record(songId: "a", scope: crateA, verdict: .accepted, surface: .tile, at: 2000)
        peer.record(songId: "z", scope: crateB, verdict: .rejected, surface: .widget, at: 1500)
        peer.flush()
        let payload = try Data(contentsOf: peer.syncFileURL)

        mine.applyPulledPayload(payload)
        mine.reloadFromDisk()
        XCTAssertEqual(mine.verdict(songId: "a", scope: crateA), .accepted, "later stamp wins")
        XCTAssertEqual(mine.verdict(songId: "z", scope: crateB), .rejected, "peer rows are unioned in")
    }

    /// The wire carries EVERY verdict including `cleared` — withholding rejections would upload
    /// half of what the listener said and leave the cloud recommending back exactly what was
    /// thumbed down; withholding the undo would leave the server holding an opinion forever.
    func testWireProjectionCarriesRejectionsAndUndosToo() {
        let s = makeStore()
        s.record(songId: "a", scope: crateA, verdict: .rejected, surface: .tile, at: 100)
        s.record(songId: "b", scope: crateA, verdict: .accepted, surface: .widget, at: 200)
        s.record(songId: "a", scope: crateA, verdict: .cleared, surface: .carPlay, at: 300)

        let events = s.recFeedbackEvents(sinceMs: 0)
        XCTAssertEqual(events.map(\.verdict), ["rejected", "accepted", "cleared"], "oldest first")
        XCTAssertEqual(events.map(\.context), [crateA, crateA, crateA], "the scope rides the wire")
        XCTAssertEqual(events.map(\.surface), ["tile", "widget", "carPlay"])
        XCTAssertEqual(s.recFeedbackEvents(sinceMs: 250).count, 1, "the cursor is honoured")
    }

    // ========================================================================
    // MARK: - The playing scope (the SYNC half's missing half)
    // ========================================================================

    /// The now-playing surfaces have one track and no list, so they have to be TOLD which tile the
    /// track is a recommendation in. Membership is checked, not just "a rec queue is running".
    func testThePlayingScopeIsMembershipCheckedAndClearable() {
        let s = makeStore()
        XCTAssertNil(s.scope(forPlaying: "a"), "nothing running ⇒ no scope ⇒ the controls hide")

        s.beginPlayback(scope: zone, songIds: ["a", "b"], at: 0)
        XCTAssertEqual(s.scope(forPlaying: "a"), zone)
        XCTAssertNil(s.scope(forPlaying: "manually-queued"),
                     "a track queued on top of a zone set is not filed against the zone")

        // A NEW queue from somewhere else retires the scope entirely — otherwise starting a
        // playlist that happens to contain a zone song would re-expose the thumbs and file the
        // verdict against `zone`.
        s.endPlaybackScope()
        XCTAssertNil(s.scope(forPlaying: "a"))
    }

    /// The lifecycle hook is WIRED, not merely defined. `playNow` is the single funnel every
    /// "start playing this set" path in the app goes through, so hanging the retire there is what
    /// makes the scope unable to outlive its queue.
    func testStartingAnyOtherSetRetiresTheScopeThroughTheRealFunnel() {
        let s = makeStore()
        let collections = CollectionsStore(fileURL: tempDir.appendingPathComponent("c.json"))
        collections.onPlaybackReplaced = { [weak s] in s?.endPlaybackScope() }

        s.beginPlayback(scope: zone, songIds: ["a"], at: 0)
        XCTAssertEqual(s.scope(forPlaying: "a"), zone)

        // `playNow` with no AppModel wired returns nil, but the hook must still have fired — the
        // scope is retired at the TOP of the funnel, before anything can fail.
        _ = collections.playNow(songIds: ["a"], name: "Some Playlist")
        XCTAssertNil(s.scope(forPlaying: "a"),
                     "a queue from anywhere else clears the recommendation scope")
    }

    // ========================================================================
    // MARK: - What the RANKING does with it
    // ========================================================================

    private func song(_ id: String, artist: String, year: Int? = nil,
                      bpm: Double? = nil, camelot: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// Only `suppressed` removes a row, and it is the caller's SCOPED, expiring set.
    func testOnlyTheScopedTombstoneRemovesASongFromTheQueue() {
        var songs: [IndexSong] = []
        for i in 0..<40 { songs.append(song("s\(i)", artist: "Artist \(i % 5)", year: 1990 + i % 20)) }
        let genres = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, "hip-hop") })
        let plays = (0..<5).map { ZoneEngine.Play(songId: "s\($0)", playedAtMs: -3 * 86_400_000) }

        func queue(_ fb: ZoneEngine.Feedback) -> [String] {
            ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                playCount: { _ in 1 }, feedback: fb, nowMs: 0).songIds
        }
        let baseline = queue(ZoneEngine.Feedback())
        guard let victim = baseline.first(where: { !$0.hasSuffix("0") }) else {
            return XCTFail("need a queue to work with")
        }

        // A GLOBAL rejection (taste) must NOT remove it — that was the permanent-ban defect.
        let tasteOnly = queue(ZoneEngine.Feedback(rejected: [victim: 1.0]))
        XCTAssertTrue(tasteOnly.contains(victim),
                      "a reject given in ANOTHER list must not delete the row here")

        // The SCOPED tombstone does remove it (and the view puts it back at the bottom).
        let suppressed = queue(ZoneEngine.Feedback(suppressed: [victim]))
        XCTAssertFalse(suppressed.contains(victim))
    }

    /// A REJECTION TEACHES, not merely hides — the half that makes this "fed into the
    /// recommendation engine" rather than a seven-day view filter.
    ///
    /// It is a DEMOTION and never a ban: one thumbs-down on a song by an artist the listener
    /// otherwise plays constantly must not cancel that artist out of the queue.
    func testARejectionDemotesTheRejectedShapeWithoutErasingIt() {
        // Two clearly separated REGIONS of the library — a 1960s jazz side and a 2000s hip-hop
        // side — with enough distinct artists on each that the three-per-artist cap is not what
        // decides the answer.
        var songs: [IndexSong] = []
        for i in 0..<16 { songs.append(song("jazz\(i)", artist: "Jazz \(i % 8)", year: 1960 + i % 4)) }
        for i in 0..<16 { songs.append(song("hip\(i)", artist: "Hip \(i % 8)", year: 2004 + i % 4)) }
        songs.append(song("seedJ", artist: "Jazz 0", year: 1961))
        songs.append(song("seedH", artist: "Hip 0", year: 2005))
        var genres = Dictionary(uniqueKeysWithValues: songs.map {
            ($0.id, $0.id.hasPrefix("jazz") ? "jazz" : "hip-hop")
        })
        genres["seedJ"] = "jazz"; genres["seedH"] = "hip-hop"
        // Both regions are in the taste profile — the listener plays both.
        let plays = [ZoneEngine.Play(songId: "seedJ", playedAtMs: -3 * 86_400_000),
                     ZoneEngine.Play(songId: "seedH", playedAtMs: -3 * 86_400_000)]

        func rank(_ fb: ZoneEngine.Feedback) -> [String] {
            ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                playCount: { _ in 1 }, feedback: fb, nowMs: 0).songIds
        }
        func jazzShare(_ ids: [String]) -> Double {
            guard !ids.isEmpty else { return 0 }
            return Double(ids.filter { $0.hasPrefix("jazz") }.count) / Double(ids.count)
        }

        let before = rank(ZoneEngine.Feedback())
        // ONE rejection of ONE jazz song, with nothing suppressed in this list — so the only thing
        // reaching this queue is the taste signal. It has to move the whole REGION, not one row.
        let after = rank(ZoneEngine.Feedback(rejected: ["jazz1": 1.0]))

        XCTAssertLessThan(jazzShare(after), jazzShare(before),
                          "the rejected SHAPE is demoted, not just the one row")
        XCTAssertTrue(after.contains { $0.hasPrefix("jazz") },
                      "…but the region is demoted, never censored — this is not a ban")
        // NOTE the taste signal can still push the rejected song itself out of a length-bounded
        // queue — that is RANKING, not filtering, and the difference matters: the engine never
        // removes it (`testOnlyTheScopedTombstoneRemovesASongFromTheQueue`), and the tile puts any
        // live tombstone back at the bottom so the undo control stays reachable
        // (`testATombstonedRowIsReAddedAtTheBottomEvenWhenTheEngineDroppedIt`).
    }

    /// A 👍 is taste evidence even for a song that was never played, so it shapes what "similar"
    /// means — without joining the FAMILIAR pool, which would be claiming the listener has heard it.
    func testAnAcceptedSongShapesTheQueueWithoutJoiningTheFamiliarPool() {
        var songs: [IndexSong] = []
        for i in 0..<10 { songs.append(song("jazz\(i)", artist: "Jazz \(i)", year: 1960)) }
        for i in 0..<10 { songs.append(song("hip\(i)", artist: "Hip \(i)", year: 2005)) }
        songs.append(song("seed", artist: "Hip 0", year: 2005))
        songs.append(song("liked", artist: "Jazz 0", year: 1960))
        var genres = Dictionary(uniqueKeysWithValues: songs.map {
            ($0.id, $0.id.hasPrefix("jazz") || $0.id == "liked" ? "jazz" : "hip-hop")
        })
        genres["seed"] = "hip-hop"
        let plays = [ZoneEngine.Play(songId: "seed", playedAtMs: -3 * 86_400_000)]

        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 1 },
                                    feedback: ZoneEngine.Feedback(accepted: ["liked": 1.0]),
                                    nowMs: 0)
        let pools = Dictionary(q.picks.map { ($0.songId, $0.pool) }, uniquingKeysWith: { a, _ in a })
        if let p = pools["liked"] {
            XCTAssertEqual(p, .rediscovery, "a 👍'd song was never HEARD — it is not 'familiar'")
        }
        XCTAssertTrue(q.songIds.contains { $0.hasPrefix("jazz") },
                      "the 👍 pulled its neighbourhood into the queue")
    }

    /// The safety property: no feedback ⇒ the ranking is exactly what it was before this feature.
    func testEmptyFeedbackLeavesTheQueueIdentical() {
        var songs: [IndexSong] = []
        for i in 0..<30 { songs.append(song("s\(i)", artist: "Artist \(i % 6)", year: 1980 + i)) }
        let genres = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, "soul") })
        let plays = (0..<4).map { ZoneEngine.Play(songId: "s\($0)", playedAtMs: -2 * 86_400_000) }

        let a = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 3 }, nowMs: 0)
        let b = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 3 }, feedback: ZoneEngine.Feedback(), nowMs: 0)
        XCTAssertEqual(a.picks, b.picks)
    }

    /// The collection tile follows the same two rules as the zone.
    func testCollectionSuggestionsSinkOnlyTheScopedTombstone() {
        var tracks: [ZoneEngine.Track] = []
        for i in 0..<20 {
            tracks.append(ZoneEngine.Track(songId: "t\(i)", artistKey: "artist \(i % 4)",
                                           artistName: "Artist \(i % 4)", genre: "soul",
                                           year: 1975 + i % 10))
        }
        let members = ["t0", "t1", "t2"]
        let base = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks, playCount: { _ in 1 })
        guard let victim = base.first else { return XCTFail("need suggestions") }

        let taste = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                           playCount: { _ in 1 },
                                           feedback: ZoneEngine.Feedback(rejected: [victim: 1.0]))
        XCTAssertTrue(taste.contains(victim), "a global taste signal demotes, it does not delete")

        let scoped = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                            playCount: { _ in 1 },
                                            feedback: ZoneEngine.Feedback(suppressed: [victim]))
        XCTAssertFalse(scoped.contains(victim), "the tile's own tombstone removes it from the offer")
    }

    /// A collection tile ranks on all three families too — "not just artist based" has to be true
    /// of the crate tiles, not only In Da Zone.
    func testCollectionSuggestionsUseTheThreeFamiliesNotJustArtist() {
        // Members: one artist, one era, one tempo/key shape.
        let members = ["m0", "m1"]
        var tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "seed", artistName: "Seed", genre: "soul",
                             year: 1972, bpm: 96, camelot: "8A"),
            ZoneEngine.Track(songId: "m1", artistKey: "seed", artistName: "Seed", genre: "soul",
                             year: 1973, bpm: 98, camelot: "8A"),
        ]
        // Two candidates by the SAME (non-seed) artist and genre, differing only in era + groove.
        tracks.append(ZoneEngine.Track(songId: "close", artistKey: "other", artistName: "Other",
                                       genre: "soul", year: 1972, bpm: 97, camelot: "8A"))
        tracks.append(ZoneEngine.Track(songId: "far", artistKey: "other", artistName: "Other",
                                       genre: "soul", year: 2018, bpm: 174, camelot: "3B"))

        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks, playCount: { _ in 1 })
        guard let i = out.firstIndex(of: "close"), let j = out.firstIndex(of: "far") else {
            return XCTFail("both candidates should be suggested: \(out)")
        }
        XCTAssertLessThan(i, j, "same artist, same genre — era and groove decide, as they must")
    }

    // ========================================================================
    // MARK: - A verdict must REDRAW the surface that reads it
    // ========================================================================

    /// THE BUG THIS FILE MISSED, and the reason a 👎 looked like it did nothing: every read on this
    /// store goes through the memoized `derived` index, and `derived` was `@ObservationIgnored`. A
    /// SwiftUI body calling `verdict(songId:scope:)` therefore registered NO dependency, so the
    /// thumb never filled, the row never sank, and — once the tile toolbars started gating ▶ on the
    /// live half — a transport control could sit lit over a list with nothing live in it. Popping
    /// the screen and re-entering "fixed" it, which is the signature of a missing dependency rather
    /// than a missing write.
    ///
    /// `withObservationTracking` is the empirical form of "would SwiftUI redraw?": it is the same
    /// mechanism `@Observable` view bodies use. One test per READER, because each one is a separate
    /// door onto `derived` and a future refactor could take any single one back off the index.
    func testEveryDerivedReadRegistersAnObservationDependency() {
        func assertRedraws(_ label: String, _ read: @escaping (RecFeedbackStore) -> Void) {
            let store = makeStore()
            let fired = expectation(description: label)
            withObservationTracking {
                read(store)
            } onChange: {
                fired.fulfill()
            }
            store.toggle(songId: "s1", to: .rejected, scope: crateA, surface: .tile)
            wait(for: [fired], timeout: 2)
        }

        assertRedraws("verdict") { _ = $0.verdict(songId: "s1", scope: self.crateA) }
        assertRedraws("anyVerdict") { _ = $0.anyVerdict(songId: "s1") }
        assertRedraws("activeTombstones") { _ = $0.activeTombstones(scope: self.crateA) }
        assertRedraws("isSuppressed") { _ = $0.isSuppressed(songId: "s1", scope: self.crateA) }
        assertRedraws("partition") { _ = $0.partition(["s1", "s2"], scope: self.crateA) }
        assertRedraws("visibleCount") { _ = $0.visibleCount(["s1", "s2"], scope: self.crateA) }
    }
}
