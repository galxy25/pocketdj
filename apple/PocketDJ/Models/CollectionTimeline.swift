import Foundation

/// Which stream the Collection tab is showing (F8 — the ONE TRUE TIMELINE).
///
/// `activity` is the DEFAULT and is exactly what the Collection tab has always been: the
/// `CollectionActivityStore` feed of adds / hearts / unhearts / removes, newest first. The owner
/// was explicit that opening the tab must look unchanged — "by default it just shows its current
/// view of the most recent additions to your collection and favoriting" — so the timeline is
/// strictly OPT-IN, one segment away.
///
/// `songs` / `albums` are the timeline proper: the WHOLE catalog ordered by when it entered the
/// library, filterable by a cutoff date and reversible in direction.
enum TimelineGrain: String, CaseIterable, Hashable, Identifiable {
    case activity, songs, albums

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .songs:    return "Songs"
        case .albums:   return "Albums"
        }
    }

    var symbol: String {
        switch self {
        case .activity: return "clock.arrow.circlepath"
        case .songs:    return "music.note"
        case .albums:   return "square.stack"
        }
    }

    /// Accessibility-id token (`collection-grain-<token>`).
    var a11y: String { rawValue }
}

/// THE ONE TRUE TIMELINE — the pure, off-main core behind the Collection tab's catalog stream.
///
/// ## What it is
/// Every song (or every album) in the catalog, placed on one axis: WHEN IT WAS ADDED. Filterable
/// to "added after <date>", reversible ascending/descending, and annotated with LISTENING PROGRESS
/// so the stream doubles as a record of what he has actually heard.
///
/// ## Why it is a free function over value types
/// The catalog is ~96,000 songs. Deriving that inside a SwiftUI body is a bug this repo has shipped
/// more than once (see `AppModel.recentlyAddedSongIds`'s memo, and the `collections-sequencer-perf`
/// round). Everything here is `nonisolated` + pure so `CollectionTimelineView` can run it on a
/// detached task and publish a finished `[Row]`; the view body only ever indexes into that array.
///
/// ## Add dates, and the rows that have none
/// `dateAdded` is present on ~93,510 of ~96,021 index rows. A row with no add date CANNOT be placed
/// in a temporal stream — there is no honest position for it — so it is EXCLUDED from the rows and
/// COUNTED into `Summary.undated`, which the view states plainly under the progress readout
/// ("2,511 songs have no add date and aren't placed in the timeline"). Silently dropping them would
/// make the timeline look like the whole library; silently placing them at 0 (or at "now") would
/// invent history. The count is over the WHOLE catalog and is deliberately independent of the date
/// cutoff — it describes the library, not the window.
enum CollectionTimeline {

    /// One row of the stream: a song, or an album standing in for its tracks.
    ///
    /// `heard` / `total` carry the PROGRESS: for a song row `total` is 1 and `heard` is 0 or 1; for
    /// an album row they are its indexed track count and how many of those have ever been played.
    /// Both are computed in the builder — never in a view body.
    struct Row: Identifiable, Hashable {
        enum Kind: String, Hashable { case song, album }

        var kind: Kind
        /// The catalog id (song id or album id) — what a tap navigates to.
        var itemId: String

        /// Namespaced so a song and an album can never collide in a `ForEach`/`scrollTo` id space.
        ///
        /// COMPUTED, not stored, and that is a scale decision rather than a style one: storing it
        /// meant minting ~93,000 new strings on every build (one per catalog row), all to serve a
        /// value only the ~120 RENDERED rows ever ask for. The sort's tiebreak reads `itemId`
        /// instead — within one build every row is the same `kind`, so the two orderings are
        /// identical.
        var id: String { (kind == .song ? "s:" : "a:") + itemId }
        var title: String
        var artist: String
        /// The song's album (for artwork); nil for a song with no indexed album. On an album row
        /// this is the album's own id.
        var albumId: String?
        /// Position on the axis, epoch ms. For an album this is the NEWEST add-time among its
        /// indexed tracks — see `buildAlbums`.
        var addedAtMs: Double
        /// Tracks on this row that have been played at least once.
        var heard: Int
        /// Indexed tracks on this row.
        var total: Int
        /// Lifetime plays summed over the row.
        var plays: Int
        /// This row opens a new calendar month in the current direction — the view draws the month
        /// divider off this flag rather than comparing neighbours in the body.
        var startsMonth: Bool = false
        /// "March 2024" for the divider (empty unless `startsMonth`).
        var monthLabel: String = ""

        var fullyHeard: Bool { total > 0 && heard == total }
    }

    /// The counts the header reads. Every one of them is produced by the same single pass that
    /// builds the rows — the view never recounts.
    struct Summary: Equatable {
        /// Rows emitted (songs, or albums, depending on grain).
        var rows: Int = 0
        /// SONGS represented by those rows (an album row contributes its track count).
        var songs: Int = 0
        /// …of which have been played at least once.
        var heard: Int = 0
        /// Lifetime plays across the window.
        var plays: Int = 0
        /// Catalog items of this grain with NO add date — not placed in the stream (see the type doc).
        var undated: Int = 0
        /// ALBUMS grain only: dated songs with no indexed album, which therefore have no album row
        /// to live on. Zero in the songs grain, where every song is its own row.
        var ungrouped: Int = 0
        /// Rows the date cutoff excluded (dated, but older than "since").
        var beforeCutoff: Int = 0

        /// 0…1 share of the window that has been heard; 0 when the window is empty.
        var progress: Double { songs > 0 ? Double(heard) / Double(songs) : 0 }
    }

    struct Result: Equatable {
        var rows: [Row] = []
        var summary = Summary()
    }

    /// Everything the build needs, as VALUES — so the whole thing can cross to a detached task.
    /// The two catalog dictionaries are copy-on-write, so passing them is O(1), not a deep copy.
    struct Input {
        var songsById: [String: IndexSong] = [:]
        var albumsById: [String: IndexAlbum] = [:]
        /// song id → epoch ms it entered the library. Built by
        /// `AppModel.addedAtBySongId(songsById:songSourceById:filterToOwnLibrary:overrides:)`,
        /// which is the SAME union the "Recently added" playlist ranks — one implementation, so the
        /// timeline and that playlist can never disagree about when something arrived.
        var addedAt: [String: Double] = [:]
        /// song id → lifetime plays (`PlayCountService.snapshot()`). SPARSE: a song absent here has
        /// never been played, which is the common case (47.8% of the catalog has no play data).
        var playCounts: [String: Int] = [:]
        var grain: TimelineGrain = .songs
        /// Cutoff: keep rows added at or after this instant. nil ⇒ all time.
        var afterMs: Double?
        var ascending: Bool = false
        /// Free-text filter over title + artist (the History search field). Empty ⇒ everything.
        var query: String = ""
    }

    // MARK: - Build

    nonisolated static func build(_ input: Input) -> Result {
        var result = input.grain == .albums ? buildAlbums(input) : buildSongs(input)
        sortAndMark(&result.rows, ascending: input.ascending)
        result.summary.rows = result.rows.count
        return result
    }

    private nonisolated static func buildSongs(_ i: Input) -> Result {
        let needle = fold(i.query)
        var out = Result()
        out.rows.reserveCapacity(min(i.songsById.count, 4096))
        for (id, song) in i.songsById {
            guard let at = i.addedAt[id], at > 0 else { out.summary.undated += 1; continue }
            if let after = i.afterMs, at < after { out.summary.beforeCutoff += 1; continue }
            if !needle.isEmpty, !fold(song.name + "\n" + song.artist).contains(needle) { continue }
            let n = i.playCounts[id] ?? 0
            out.summary.songs += 1
            out.summary.plays += n
            if n > 0 { out.summary.heard += 1 }
            out.rows.append(Row(kind: .song, itemId: id, title: song.name,
                                artist: song.artist, albumId: song.albumId, addedAtMs: at,
                                heard: n > 0 ? 1 : 0, total: 1, plays: n))
        }
        return out
    }

    /// Albums grain. An album's POSITION is the NEWEST add-time among its indexed tracks, not the
    /// oldest: a record he is still filling in (three tracks in 2019, the rest last week) belongs
    /// where the library actually changed, and "most recent additions" — the reading the default
    /// view has always had — would otherwise bury it years back. The earliest track's date is not
    /// lost so much as not shown; the songs grain is where per-track dates live.
    ///
    /// A song with no indexed album has no album row to join. It is counted into
    /// `Summary.ungrouped` and stated in the header rather than being dropped in silence.
    private nonisolated static func buildAlbums(_ i: Input) -> Result {
        struct Agg { var at: Double = 0; var heard = 0; var total = 0; var plays = 0 }
        let needle = fold(i.query)
        var out = Result()
        var byAlbum: [String: Agg] = [:]
        byAlbum.reserveCapacity(min(i.albumsById.count, 4096))

        for (id, song) in i.songsById {
            let at = i.addedAt[id] ?? 0
            guard let aid = song.albumId, i.albumsById[aid] != nil else {
                // No album to hang it on. Undated wins the tally — an item with neither a date nor
                // an album is unplaceable for the more fundamental of the two reasons.
                if at > 0 { out.summary.ungrouped += 1 } else { out.summary.undated += 1 }
                continue
            }
            var agg = byAlbum[aid] ?? Agg()
            agg.at = max(agg.at, at)
            agg.total += 1
            let n = i.playCounts[id] ?? 0
            agg.plays += n
            if n > 0 { agg.heard += 1 }
            byAlbum[aid] = agg
        }

        out.rows.reserveCapacity(min(byAlbum.count, 4096))
        for (aid, agg) in byAlbum {
            guard let album = i.albumsById[aid] else { continue }
            guard agg.at > 0 else { out.summary.undated += 1; continue }
            if let after = i.afterMs, agg.at < after { out.summary.beforeCutoff += 1; continue }
            if !needle.isEmpty, !fold(album.name + "\n" + album.artist).contains(needle) { continue }
            out.summary.songs += agg.total
            out.summary.heard += agg.heard
            out.summary.plays += agg.plays
            out.rows.append(Row(kind: .album, itemId: aid, title: album.name,
                                artist: album.artist, albumId: aid, addedAtMs: agg.at,
                                heard: agg.heard, total: agg.total, plays: agg.plays))
        }
        return out
    }

    /// Order the stream and stamp the month dividers.
    ///
    /// The tiebreak on `id` is not cosmetic: dictionary iteration order is arbitrary and Swift's
    /// sort is not stable, so equal-timestamp rows would otherwise shuffle between two builds of
    /// the SAME data — which in a paged list reads as rows randomly swapping places. (The same
    /// determinism bug `AppModel.newestFirst` documents.)
    nonisolated static func sortAndMark(_ rows: inout [Row], ascending: Bool) {
        rows.sort { a, b in
            if a.addedAtMs != b.addedAtMs {
                return ascending ? a.addedAtMs < b.addedAtMs : a.addedAtMs > b.addedAtMs
            }
            return a.itemId < b.itemId
        }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        var lastKey = Int.min
        for idx in rows.indices {
            let date = Date(timeIntervalSince1970: rows[idx].addedAtMs / 1000)
            let comps = cal.dateComponents([.year, .month], from: date)
            let key = (comps.year ?? 0) * 100 + (comps.month ?? 0)
            if key != lastKey {
                rows[idx].startsMonth = true
                rows[idx].monthLabel = fmt.string(from: date)
                lastKey = key
            }
        }
    }

    // MARK: - Cue jumps

    /// Index of the row a cue point at `atMs` should land on, in a stream already ordered in
    /// `ascending` direction. nil for an empty stream.
    ///
    /// Binary partition-search, not a scan: this runs on a tap against up to ~93k rows, and the
    /// predicate ("we have reached the cue") is monotone over a sorted array, which is exactly the
    /// precondition a partition point needs. A cue that falls past the end of the stream clamps to
    /// the last row rather than failing — a bookmark can outlive the window it was set in (the user
    /// narrowed the date filter afterwards) and landing at the edge is more useful than nothing.
    nonisolated static func jumpIndex(rows: [Row], atMs: Double, ascending: Bool) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let reached = ascending ? rows[mid].addedAtMs >= atMs : rows[mid].addedAtMs <= atMs
            if reached { hi = mid } else { lo = mid + 1 }
        }
        return min(lo, rows.count - 1)
    }

    // MARK: - Helpers

    /// Case/diacritic-insensitive fold — the same normalisation the Browser's text match uses, so
    /// searching the timeline behaves like searching anywhere else. Skipped entirely for an empty
    /// query so the common case allocates nothing per row.
    private nonisolated static func fold(_ s: String) -> String {
        s.isEmpty ? "" : s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
