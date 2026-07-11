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
