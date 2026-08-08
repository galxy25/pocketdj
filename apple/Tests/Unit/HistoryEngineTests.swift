import XCTest
@testable import PocketDJ

/// The History filter/sort reuse path: History threads a `PlayRef` onto each song row and adds
/// the `lastPlayedAt` field, so the SAME FilterEngine/SortEngine/BrowseState.filterSort the
/// Browser uses power "most/least recently played" ordering and the "played between X and Y"
/// date-range filter — with no History-specific engine.
@MainActor
final class HistoryEngineTests: XCTestCase {

    private let day: Double = 24 * 60 * 60 * 1000

    /// A song row carrying a play at `playedAt` (epoch ms), like History builds per event.
    private func row(_ id: String, playedAt: Double,
                     source: PlayHistoryStore.PlaySource = .browser,
                     name: String? = nil) -> BrowseItem {
        let song = IndexSong.minimal(id: id, name: id.uppercased(), artist: "Artist \(id)")
        let ref = PlayRef(eventId: UUID(), playedAt: playedAt, source: source, contextName: name)
        return .song(song, albumName: "", play: ref)
    }

    // Three plays across three months.
    private var mayJunAug: [BrowseItem] {
        [ row("s_may", playedAt: 1_746_100_000_000),   // ~May 2026
          row("s_jun", playedAt: 1_749_000_000_000),   // ~Jun 2026
          row("s_aug", playedAt: 1_754_000_000_000) ]  // ~Aug 2026
    }

    private func ids(_ items: [BrowseItem]) -> [String] {
        items.compactMap { if case .song(let s, _, _, _, _) = $0 { return s.id } else { return nil } }
    }

    func testSortLastPlayedDescendingIsMostRecentFirst() {
        let out = SortEngine.apply(mayJunAug, [SortKey(field: "lastPlayedAt", dir: .desc)])
        XCTAssertEqual(ids(out), ["s_aug", "s_jun", "s_may"])
    }

    func testSortLastPlayedAscendingIsLeastRecentFirst() {
        let out = SortEngine.apply(mayJunAug, [SortKey(field: "lastPlayedAt", dir: .asc)])
        XCTAssertEqual(ids(out), ["s_may", "s_jun", "s_aug"])
    }

    /// "played between May and August 2026" — inclusive numeric `.between` on epoch-ms.
    func testDateRangeFilterKeepsOnlyInRangePlays() {
        var c = Clause(field: "lastPlayedAt", op: .between)
        c.min = 1_745_000_000_000   // late Apr 2026
        c.max = 1_755_000_000_000   // mid Aug 2026
        let out = FilterEngine.apply(mayJunAug, [c])
        XCTAssertEqual(Set(ids(out)), ["s_may", "s_jun", "s_aug"])

        // Narrow to June only → just the June play survives.
        var jun = Clause(field: "lastPlayedAt", op: .between)
        jun.min = 1_748_000_000_000
        jun.max = 1_750_000_000_000
        XCTAssertEqual(ids(FilterEngine.apply(mayJunAug, [jun])), ["s_jun"])
    }

    /// The full pipeline (text query + clause + sort) the History view drives off-main.
    func testFilterSortPipelineWithDateRangeAndRecencySort() {
        let base = mayJunAug
        let keys = base.map { _ in "" }   // no text query in this case
        var c = Clause(field: "lastPlayedAt", op: .between)
        c.min = 1_748_000_000_000
        c.max = 1_760_000_000_000
        let out = BrowseState.filterSort(base: base, searchKeys: keys, query: "",
                                         clauses: [c], sortKeys: [SortKey(field: "lastPlayedAt", dir: .desc)])
        XCTAssertEqual(ids(out), ["s_aug", "s_jun"])   // May excluded; recent-first
    }

    /// Two plays of the SAME song are DISTINCT rows (per-event ids) — no ForEach/engine collision.
    func testSameSongTwoPlaysHaveDistinctRowIds() {
        let a = row("dup", playedAt: 1_000, name: "Set A")
        let b = row("dup", playedAt: 2_000, name: "Set B")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("evt:"))
    }
}

// MARK: - Rewind slice (R5b): reconstructing a past run from the log

@MainActor
final class HistoryRewindSliceTests: XCTestCase {

    private func ev(_ song: String, at ms: Double, context: String?) -> PlayHistoryStore.PlayEvent {
        PlayHistoryStore.PlayEvent(id: UUID(), songId: song, playedAt: ms, source: .playlist,
                                   contextId: context, contextName: context,
                                   title: song, artist: "A", originInstallId: nil)
    }

    /// The slice is the tapped play AND everything that followed it IN THE SAME SET — which is
    /// exactly the "and every song afterwards plays in order" semantic, reconstructed from the log
    /// when the run is no longer live.
    func testSliceRunsFromTheTappedPlayToTheEndOfThatRun() {
        let a = ev("s1", at: 1_000, context: "set_A")
        let b = ev("s2", at: 2_000, context: "set_A")
        let c = ev("s3", at: 3_000, context: "set_A")
        let slice = HistoryView.rewindSlice(from: b.id, in: [a, b, c])
        XCTAssertEqual(slice.map(\.songId), ["s2", "s3"], "starts AT the tap, runs to the end")
    }

    /// It STOPS at a different set. Rewinding into yesterday's playlist must not drag in whatever
    /// was played afterwards from somewhere else — that was never part of this run.
    func testSliceStopsAtADifferentContext() {
        let a = ev("s1", at: 1_000, context: "set_A")
        let b = ev("s2", at: 2_000, context: "set_A")
        let other = ev("s9", at: 2_500, context: "set_B")
        let backAgain = ev("s3", at: 3_000, context: "set_A")
        let slice = HistoryView.rewindSlice(from: a.id, in: [a, b, other, backAgain])
        XCTAssertEqual(slice.map(\.songId), ["s1", "s2"],
                       "a play from another set ends the run — later set_A plays are a DIFFERENT run")
    }

    /// Browser singles have no context id; they group together rather than each being their own run.
    func testBrowserSinglesShareTheNilContext() {
        let a = ev("s1", at: 1_000, context: nil)
        let b = ev("s2", at: 2_000, context: nil)
        XCTAssertEqual(HistoryView.rewindSlice(from: a.id, in: [a, b]).map(\.songId), ["s1", "s2"])
    }

    func testUnknownEventYieldsNothing() {
        let a = ev("s1", at: 1_000, context: "set_A")
        XCTAssertTrue(HistoryView.rewindSlice(from: UUID(), in: [a]).isEmpty)
    }

    // MARK: - Multi-select universe (one entry per SONG, not per play)

    /// History renders one row per PLAY, so the same song appears many times. The multi-select
    /// id space (⌘A's universe, the ⇧-click range order, and the Share/Copy export) has to be
    /// the DEDUPED displayed order — otherwise a range between two rows of the same song is
    /// ambiguous and the count double-reports.
    func testDistinctSongsCollapsesRepeatPlaysKeepingFirstPosition() {
        let items = [playRow("s1", at: 3_000), playRow("s2", at: 2_000),
                     playRow("s1", at: 1_000), playRow("s3", at: 500)]
        XCTAssertEqual(HistoryView.distinctSongs(items).map(\.id), ["s1", "s2", "s3"])
    }

    /// One History row (a song + its play), like `HistoryView.makeRow` builds per event.
    private func playRow(_ id: String, at ms: Double) -> BrowseItem {
        let song = IndexSong.minimal(id: id, name: id.uppercased(), artist: "A")
        return .song(song, albumName: "",
                     play: PlayRef(eventId: UUID(), playedAt: ms, source: .browser, contextName: nil))
    }

    /// Non-song rows (and an empty result set) contribute nothing.
    func testDistinctSongsIgnoresNonSongItems() throws {
        let albums = try TestData.albumItemsTagged()
        XCTAssertTrue(HistoryView.distinctSongs(albums).isEmpty)
        XCTAssertTrue(HistoryView.distinctSongs([]).isEmpty)
    }
}
