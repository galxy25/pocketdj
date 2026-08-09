import Foundation

/// Reads Apple's LIFETIME play counters off the signed-in Apple Music library via MusicKit and
/// maps them onto PocketDJ song ids — the recurring refresh for `AMPlayBaselineStore`, and the
/// successor to hand-parsing `Library.xml`.
///
/// ── WHY MUSICKIT AND NOT THE REST API ────────────────────────────────────────────────────────
/// The Apple Music REST API does not expose play counts and never has. `MusicKit.Song.playCount`
/// (`Int?`, iOS 16+ / macOS 14+ / visionOS 1+) does, but ONLY on a LIBRARY-scoped fetch — a
/// catalog-fetched `Song` reports nil by design. So this is a `MusicLibraryRequest`, always.
///
/// ── nil ≠ unknown, ON THIS PATH ──────────────────────────────────────────────────────────────
/// On a library request `nil` is how an UNPLAYED song reads, not "couldn't tell". Measured on a
/// real library: the non-nil count equalled the non-zero count EXACTLY (117 == 117 across 225
/// songs — no non-nil zero was ever observed), and 117/200 ≈ 58.5% matches the Library.xml
/// baseline's 56,224/96,020 = 58.55% to two decimals. So a nil here is dropped, and the caller's
/// store treats absent as zero. It is never written as a literal 0 row.
///
/// ── OFF THE MAIN ACTOR, AND CHECKPOINTED ─────────────────────────────────────────────────────
/// A 90k-song walk takes minutes (the lesson `AppleMusicLibraryIndexer` already carries), so this
/// is `nonisolated` and INCREMENTAL: the walk is sorted by `lastPlayedDate` descending and stops
/// at the store's high-water mark, so a routine refresh touches only what was played since the
/// last one. A nil mark (first ever capture) walks everything — and only then is the result a
/// complete SNAPSHOT.
///
/// ── IT DOES RUN UNATTENDED (this comment used to say the opposite) ────────────────────────────
/// "Explicit-trigger only, never on launch" was the right rule while the walk was all-or-nothing
/// at 100%: an automatic start was then minutes of work that any interruption threw away. `walk`
/// below CHECKPOINTS, so an automatic first run banks its progress and a resume continues from the
/// cursor — and the alternative (Browse's "Plays" column silently ranking by this app's own
/// playback until the owner happens to find a Settings button) is the bug that was reported.
/// Automatic starts stay NARROW and are both one-shot per launch:
/// `PlayCountService.autoCaptureIfNeverCaptured` fires only for an EMPTY baseline, and
/// `resumeCaptureIfInterrupted` only for a run already banked on disk. The routine refresh is
/// still explicit.
enum AppleMusicPlayCountCapture {

    /// What one walk produced.
    struct Result {
        /// songId → Apple's lifetime counter (+ Apple's own last-played date).
        var counts: [String: AMPlayBaselineStore.Entry] = [:]
        /// Epoch ms of the walk — the snapshot's `capturedAtMs`.
        var capturedAtMs: Double = 0
        /// The newest `lastPlayedDate` seen — the next incremental walk's stopping point.
        var maxLastPlayedMs: Double?
        /// Library rows examined (diagnostics; a full walk reports the library size).
        var scanned: Int = 0
        /// Rows whose Apple identity matched no PocketDJ song (diagnostics — a high number means
        /// the catalog's `appleMusicId` coverage is the thing to fix, not this).
        var unresolved: Int = 0
        /// Rows that reported a non-nil, non-zero `playCount` — counted BEFORE resolution, so it
        /// separates "Apple wouldn't tell us" from "we couldn't map what Apple told us".
        var withPlayCount: Int = 0
        /// FULL walk ⇒ `counts` is a complete snapshot and may be SET wholesale. An INCREMENTAL
        /// walk only carries recently-played rows, so its counts must be merged onto the previous
        /// snapshot, never used to replace it (see `merged`).
        var isFullWalk: Bool = true

        /// The walk read rows but Apple answered `nil` for every single `playCount` — the exact
        /// shape of the open iOS defect (forum 739587). It is NOT "you have played nothing":
        /// a library with rows that have `lastPlayedDate` set cannot also have zero plays.
        ///
        /// Distinguishing it matters twice over: such a walk must not be reported as a successful
        /// capture of nothing, and it must not leave a high-water mark behind — a mark makes every
        /// later walk incremental, so the install can never re-read the library it failed to read.
        var readNothing: Bool { scanned > 0 && withPlayCount == 0 }

        /// The mark to persist. Withheld on a `readNothing` walk, for the reason above.
        var highWaterToAdopt: Double? { readNothing ? nil : maxLastPlayedMs }

        /// The songs this walk actually RESOLVED — the only ones whose provisional stamps it is
        /// entitled to retire (see `AMPlayBaselineStore.replaceAll`).
        var observedSongIds: Set<String> { Set(counts.keys) }
    }

    /// Resolve one Apple library row to a PocketDJ song id. Injected (rather than reaching into
    /// `AppModel`) so the whole mapping layer is unit-testable with no MusicKit and no catalog.
    /// Returns nil for a row PocketDJ doesn't know — those are counted, not guessed at.
    typealias Resolver = @Sendable (_ catalogId: String?, _ title: String, _ artist: String) -> String?

    /// STRICT title+artist key — `keepVersion: true`, so a remix/live/instrumental cut can never
    /// stand in for the original (the repo's tight-matching rule for personal recordings).
    static func titleArtistKey(title: String, artist: String) -> String {
        let t = WriteBackMatcher.matchKey(title, keepVersion: true)
        let a = WriteBackMatcher.matchKey(artist, keepVersion: true)
        guard !t.isEmpty, !a.isEmpty else { return "" }
        return t + "|" + a
    }

    /// Title+artist → songId, with every AMBIGUOUS key removed. A key that two different catalog
    /// songs answer to is not an identification, and guessing would attribute a decade of someone
    /// else's plays to the wrong row.
    static func titleArtistIndex(_ rows: [(songId: String, title: String, artist: String)]) -> [String: String] {
        var out: [String: String] = [:]
        var ambiguous: Set<String> = []
        out.reserveCapacity(rows.count)
        for r in rows {
            let key = titleArtistKey(title: r.title, artist: r.artist)
            guard !key.isEmpty else { continue }
            if let existing = out[key] {
                if existing != r.songId { ambiguous.insert(key) }
            } else {
                out[key] = r.songId
            }
        }
        for k in ambiguous { out.removeValue(forKey: k) }
        return out
    }

    /// The walk's resolver: exact Apple catalog id FIRST, then the strict title+artist fallback.
    ///
    /// The fallback is not a nicety. Only 83.0% of the baseline's songs carry an `appleMusicId`
    /// (46,664 of 56,224, measured), so a catalog-id-only walk simply cannot see the rest — and
    /// the `Resolver` signature has always declared title and artist precisely so it could.
    static func resolver(byCatalogId: [String: String],
                         byTitleArtist: [String: String] = [:]) -> Resolver {
        { catalogId, title, artist in
            if let catalogId, let hit = byCatalogId[catalogId] { return hit }
            guard !byTitleArtist.isEmpty else { return nil }
            let key = titleArtistKey(title: title, artist: artist)
            guard !key.isEmpty else { return nil }
            return byTitleArtist[key]
        }
    }

    /// Fold an INCREMENTAL walk onto the existing snapshot: recently-played rows update their own
    /// keys and every untouched key survives.
    ///
    /// Still SET-not-ADD: the incoming `n` never adds to what was there, so re-running the same
    /// incremental walk is idempotent — the invariant the whole design rests on.
    ///
    /// `max`, not blind replace, for one specific reason: Apple can hold SEVERAL library rows for
    /// one catalog song, and an incremental walk only sees the row that was just played. Blindly
    /// writing that row's counter would drop its siblings' plays, which the previous full walk had
    /// summed in. Apple's counters only ever climb, so `max` is both loss-free and idempotent; a
    /// deliberate reset in Music.app is picked up by the next FULL walk — which is reachable, via
    /// Settings ▸ Play counts ▸ "Re-read everything from Apple Music" (`resetHighWater`).
    ///
    /// KNOWN, BOUNDED RESIDUAL. In that duplicate-row case an incremental walk cannot see the
    /// increase: prior is the SUM of the rows, the entry is ONE row, and `max` keeps the sum — so
    /// a single play can fail to land while its provisional stamp is retired (the song WAS
    /// observed). The alternative, blind replace, loses the siblings' plays outright and is
    /// strictly worse. The corrective is the same full re-read, which re-sums every row.
    static func merged(existing: [String: AMPlayBaselineStore.Entry],
                       incremental: [String: AMPlayBaselineStore.Entry]) -> [String: AMPlayBaselineStore.Entry] {
        var out = existing
        for (songId, entry) in incremental {
            guard let prior = out[songId] else { out[songId] = entry; continue }
            out[songId] = .init(n: max(prior.n, entry.n),
                                lastMs: maxDate(prior.lastMs, entry.lastMs))
        }
        return out
    }

    /// The position a row occupies under the walk's `lastPlayedDate` DESCENDING sort, as one
    /// comparable number. A row Apple has never played carries no date and sorts LAST, which is
    /// what the sentinel stands for — it must NOT collapse to 0, or an unplayed row would outrank
    /// every genuine 1970s-epoch timestamp and defeat the drift guard.
    static func sortKey(_ lastPlayedMs: Double?) -> Double {
        lastPlayedMs ?? -Double.greatestFiniteMagnitude
    }

    /// Newest of two optional epoch-ms dates (nil is "no date", never a zero).
    static func maxDate(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }

    /// Fold a walk's `Result` into the counts to STORE, honouring full-vs-incremental AND the
    /// SOURCE the existing baseline came from.
    ///
    /// A full walk is a snapshot — but only of the source that produced it, and the sources do not
    /// have the same reach. This walk resolves a library row through its Apple catalog id, which
    /// only songs carrying an `appleMusicId` have: measured against the owner's real data, that is
    /// 46,664 of the Library.xml baseline's 56,224 songs (83.0%) and 122,865 of its 144,517 plays
    /// (85.0%). Letting it REPLACE a `library-xml` baseline therefore deletes 9,560 songs and
    /// 21,652 plays and reports it as a success, with no undo — so across sources it FOLDS
    /// instead, which can raise a count or add a song but never drop one.
    ///
    /// Same-source is still a replace: that is what lets a genuine Music.app reset, or a song
    /// deleted from the library, actually propagate.
    static func countsToStore(_ result: Result,
                              existing: [String: AMPlayBaselineStore.Entry],
                              existingSource: String? = nil,
                              newSource: String? = nil) -> [String: AMPlayBaselineStore.Entry] {
        guard result.isFullWalk else { return merged(existing: existing, incremental: result.counts) }
        let sameSource = existingSource == nil || newSource == nil || existingSource == newSource
        if existing.isEmpty || sameSource { return result.counts }
        return merged(existing: existing, incremental: result.counts)
    }
}

// MARK: - The CHECKPOINTED walk
//
// The original `capture(since:resolve:)` above collects the whole library in a function-local
// `var` and hands it back once, at 100%. On a 96,000-song library that walk is 2-5 minutes, so
// ANY interruption — the user navigating away, the app backgrounding, a jetsam kill, a thrown
// MusicKit error, task cancellation — discarded every row of it and left the baseline empty.
// Browse then ranked by this app's own playback (nothing above single digits) while the real
// library held 50-play songs. That is the bug this section exists to kill.
//
// The shape below is `PlaylistAppleMusicSync`'s `RunSnapshot`, applied to a row walk: persist on
// every step, hydrate a `.running` snapshot as INTERRUPTED at launch, resume from the cursor.

/// The schema of the durable capture-run document. Bumped only on an INCOMPATIBLE change: a run
/// recorded under a different version is discarded (a fresh full walk), never mis-resumed.
let playCountRunSchemaVersion = 1

extension AppleMusicPlayCountCapture {

    /// One Apple library row, reduced to the only fields the walk reads. This is the seam the
    /// tests drive: a fake pager can emit these by the thousand, be interrupted at any page, and
    /// prove resume/idempotence without MusicKit, a network, or a signed-in library.
    struct LibraryRow: Sendable, Equatable {
        /// Apple's LIBRARY row id (`i.…`) — unique per row, and NOT the catalog id. Used only as
        /// the sort-drift guard's identity (see `walk`); it never reaches the store.
        var rowId: String
        var catalogId: String?
        var title: String
        var artist: String
        /// nil ⇒ never played, on a library-scoped fetch. Never stored as a literal 0.
        var playCount: Int?
        var lastPlayedMs: Double?
    }

    /// A pager over the library, sorted `lastPlayedDate` DESCENDING.
    ///
    /// `offset` rather than an opaque cursor because that is what MusicKit actually exposes:
    /// `MusicLibraryRequest` carries plain `limit`/`offset` stored properties, while
    /// `MusicItemCollection.nextBatch()` is an in-memory handle that cannot be serialized and so
    /// buys nothing across a relaunch. The real pager uses `nextBatch()` while the walk stays in
    /// ONE process (the proven path — `AppleMusicLibraryIndexer` rides it) and falls back to an
    /// `offset` request whenever the caller asks for a position it isn't already sitting on,
    /// which is exactly the resume case.
    protocol LibraryPager: Sendable {
        func page(offset: Int, limit: Int) async throws -> [LibraryRow]
    }

    /// Rows per library request.
    ///
    /// `MusicLibraryRequest.limit` is a plain stored property that `capture(since:)` never set, so
    /// the framework default (undocumented; 100 for library requests in practice) governed — about
    /// 960 IPC round trips for a 96k library. 500 cuts that to ~192 while keeping one page's
    /// materialized `MusicItemCollection` small (500 `Song` objects, comfortably under a MB), and
    /// it is the unit the cursor is aligned to, so it also bounds how much a mid-page failure can
    /// cost: nothing, because a page is folded whole or not at all.
    static let defaultPageLimit = 500

    /// MINIMUM rows between durable checkpoints (10 pages).
    ///
    /// The trade is loss-on-interruption against write cost. A checkpoint writes the run document
    /// AND the baseline; at 96k rows the baseline is 2.8 MB and ~109 ms to encode (measured), so
    /// checkpointing every 500-row page would be ~192 writes — minutes of pure I/O. 5,000 rows is
    /// ~20 writes on that library (~2 s of BACKGROUND encode+write across a 2-5 minute walk) while
    /// bounding worst-case loss to ~5,000 rows, a few seconds of walking.
    static let defaultCheckpointRows = 5_000

    /// CEILING on the adaptive interval — see `checkpointInterval`. Bounds worst-case loss on an
    /// interruption to ~25,000 rows (tens of seconds of walking) however large the library is.
    static let defaultMaxCheckpointRows = 25_000

    /// Rows to walk before the next checkpoint, given how much the run is already holding.
    ///
    /// A FIXED interval scales badly, because both persisted documents grow WITH the library while
    /// the interval does not: at 5,000 rows a 96k library takes ~20 whole-document writes (~115 MB
    /// of 2.8 MB baseline + ~3 MB run document) and a 500k library ~100 (~3 GB). Total write
    /// volume is O(N²/interval).
    ///
    /// Tying the interval to the accumulator makes the early checkpoints geometric instead — ~12
    /// on a 96k library rather than 20, and ~27 on a 500k one rather than 100, which is a ~5× cut
    /// in bytes written on the owner's library. `/ 2` rather than the raw count because in the
    /// degenerate case where every row resolves to a new song the accumulator grows exactly as
    /// fast as the cursor, so an interval equal to it would never come due at all.
    ///
    /// HONEST ABOUT WHAT THIS IS NOT: the `cap` re-flattens the tail, so total volume is still
    /// O(N²/cap) for a library large enough to reach it — it is a 5× constant, not a change of
    /// order. The cap is deliberate and is the other half of the trade: it is the bound on how
    /// much walking ONE interruption can cost (25,000 rows, tens of seconds), and letting the
    /// interval run free would make a 500k-song walk risk losing 125,000 rows at a time.
    static func checkpointInterval(accumulatedSongs: Int, floor: Int, cap: Int) -> Int {
        min(max(floor, cap), max(floor, accumulatedSongs / 2))
    }

    /// How many library row ids the run carries as the sort-drift guard's TIE-BREAKER.
    ///
    /// This used to be the whole guard, and as the whole guard it failed OPEN: it evicted the
    /// oldest id one-for-one per newly folded row, so once drift exceeded the cap the first
    /// duplicate through evicted a still-needed id, which then also slipped through — the window
    /// collapsed from the front and the REST of the walk double-folded. The guard is now a sort-key
    /// watermark (see `walk`), which needs no memory of individual rows and no cap; this set only
    /// separates rows that tie the watermark exactly.
    static let boundaryGuardCap = 1_000

    /// The durable record of ONE capture run: the cursor, the running totals, and the run's own
    /// per-song accumulator. Written atomically at every checkpoint; hydrated at launch so a run
    /// the app died in the middle of resumes instead of restarting.
    ///
    /// ── WHY THE ACCUMULATOR LIVES HERE AND NOT ONLY IN THE STORE ─────────────────────────────
    /// `counts` is the RUN-TO-DATE total per song, summed across Apple's duplicate library rows
    /// for one catalog song. The store cannot stand in for it: the store also holds counts from a
    /// previous baseline (an imported `playcounts.json`, an earlier walk), so "what has THIS run
    /// attributed to this song so far" is not recoverable from it. Keeping the accumulator in the
    /// run document makes a resume self-sufficient — it does not have to trust the store at all —
    /// and it is what lets the final commit run the whole-walk decisions (`readNothing`, the
    /// high-water mark, `countsToStore`, provisional retirement) over a COMPLETE walk, exactly as
    /// the un-checkpointed version did.
    struct Run: Codable, Equatable, Sendable {
        var schemaVersion: Int = playCountRunSchemaVersion
        /// "manual" · "auto" · "full" — audit only; every trigger drives this same code path.
        var trigger: String = "manual"
        /// Epoch ms the run STARTED. This is the snapshot's `capturedAtMs`, and it deliberately
        /// stays pinned across resumes: provisional stamps are retired at/below it, so the earlier
        /// (more conservative) value can only ever keep a play, never delete one Apple's counters
        /// had not yet absorbed.
        var startedMs: Double = 0
        var updatedMs: Double = 0
        /// The high-water mark the run started from. nil ⇒ FULL walk. Pinned for the run's life:
        /// changing it mid-walk would change where the walk stops.
        var since: Double?
        var isFullWalk: Bool = true
        /// The library sort the cursor is valid against. A stored run recorded under a different
        /// sort is discarded rather than resumed — an offset means nothing under a different order.
        var sortKey: String = Run.sortKeyLastPlayedDesc
        /// Rows consumed. THE resume offset. Always page-aligned (a page is folded whole or not
        /// at all), which is what makes "interrupted mid-batch" a state that cannot exist.
        var cursor: Int = 0
        /// songId → the run's SUMMED counter so far. See the type doc.
        var counts: [String: AMPlayBaselineStore.Entry] = [:]
        /// The sort key of the last row folded — THE sort-drift guard. See `walk`.
        ///
        /// Optional so a run document written before this field existed still decodes (a thrown
        /// decode discards the run and restarts a multi-minute walk from row 0). nil ⇒ nothing has
        /// been folded yet; the nil-`lastPlayedDate` region is `-greatestFiniteMagnitude`, never nil.
        var boundarySortMs: Double?
        /// Row ids that TIE `boundarySortMs` — the guard's only remaining exact-identity case.
        var boundaryRowIds: [String] = []
        /// Running total of `counts`, maintained as the walk folds. Keeps `audit` O(1) so progress
        /// can be published every page instead of only every checkpoint; a reduce over 46k entries
        /// per page would not be. Optional for the same decode-compatibility reason as above.
        var playsAccum: Int?
        /// Rows the LAST completed full walk found, carried forward as the progress denominator.
        /// A walk cannot know the library's size until it ends, and "Songs read 12,000" with no
        /// total is not progress.
        var libraryRowsEstimate: Int?
        var scanned: Int = 0
        var withPlayCount: Int = 0
        var unresolved: Int = 0
        var maxLastPlayedMs: Double?
        var checkpoints: Int = 0
        /// False while a run is live AND when the process died mid-run — the "interrupted" state
        /// the UI flags as resumable. True once the walk reached the end of the library (or the
        /// incremental mark).
        var completed: Bool = false
        /// WHY it stopped, in words the owner can act on.
        var stopReason: String = ""

        static let sortKeyLastPlayedDesc = "lastPlayedDate-desc"

        /// A fresh run against the store's current mark.
        static func starting(since: Double?, trigger: String, nowMs: Double) -> Run {
            Run(trigger: trigger, startedMs: nowMs, updatedMs: nowMs, since: since,
                isFullWalk: since == nil)
        }

        /// Can this stored run be picked back up? A completed run is history, not work; a run from
        /// another schema or another sort has a cursor that means nothing here.
        var isResumable: Bool {
            !completed && schemaVersion == playCountRunSchemaVersion
                && sortKey == Run.sortKeyLastPlayedDesc && startedMs > 0
        }

        /// The run as the whole-walk `Result` every existing decision is written against. Only
        /// meaningful for a COMPLETED run — see `readNothing`/`highWaterToAdopt`, both of which
        /// are whole-walk predicates that a partial must never be judged by.
        var result: Result {
            Result(counts: counts, capturedAtMs: startedMs, maxLastPlayedMs: maxLastPlayedMs,
                   scanned: scanned, unresolved: unresolved, withPlayCount: withPlayCount,
                   isFullWalk: isFullWalk)
        }

        var songsHeld: Int { counts.count }
        /// O(1) once the walk has started maintaining it; the reduce is only the fallback for a
        /// run document written before `playsAccum` existed.
        var playsHeld: Int { playsAccum ?? counts.values.reduce(0) { $0 + $1.n } }

        /// The O(1) projection Settings renders and the app hydrates at launch — everything the
        /// owner needs to answer "did this work?", and nothing that is O(library).
        var audit: Audit {
            Audit(schemaVersion: schemaVersion, trigger: trigger, startedMs: startedMs,
                  updatedMs: updatedMs, isFullWalk: isFullWalk, cursor: cursor, scanned: scanned,
                  withPlayCount: withPlayCount, unresolved: unresolved, songsHeld: songsHeld,
                  playsHeld: playsHeld, checkpoints: checkpoints, completed: completed,
                  stopReason: stopReason, libraryRowsEstimate: libraryRowsEstimate)
        }
    }

    /// The tiny sidecar the app reads at LAUNCH. Deliberately separate from `Run`: hydrating the
    /// audit must not cost a 2.5 MB decode on the way to the first frame, and the audit has to
    /// outlive the run document (which is deleted once its counts are committed).
    struct Audit: Codable, Equatable, Sendable {
        var schemaVersion: Int = playCountRunSchemaVersion
        var trigger: String = "manual"
        var startedMs: Double = 0
        var updatedMs: Double = 0
        var isFullWalk: Bool = true
        var cursor: Int = 0
        var scanned: Int = 0
        var withPlayCount: Int = 0
        var unresolved: Int = 0
        var songsHeld: Int = 0
        var playsHeld: Int = 0
        var checkpoints: Int = 0
        var completed: Bool = false
        var stopReason: String = ""
        /// Rows the last completed FULL walk found — the progress denominator. Optional so an
        /// audit sidecar written before this field existed still decodes.
        var libraryRowsEstimate: Int?
        /// When the owner DELIBERATELY cleared the baseline. Recorded so the first-run
        /// auto-capture does not rebuild, on the very next foreground, exactly what "Forget these
        /// play counts" (confirmation: "There is no undo") just removed.
        var clearedByOwnerMs: Double?

        /// The run died with the process (or was cancelled) and has work banked on disk.
        var isInterrupted: Bool { !completed && startedMs > 0 }
    }

    /// Walk the library in pages, folding each page into `run` and handing the caller a durable
    /// checkpoint every `checkpointRows` rows.
    ///
    /// ── SET, NEVER ADD, ACROSS A RESUME ───────────────────────────────────────────────────────
    /// Within one walk a song's counter is the SUM of Apple's duplicate library rows for it, so
    /// the fold below genuinely adds. That is only safe because every row is folded EXACTLY ONCE:
    ///   • the cursor is page-aligned, so a page is folded whole or not at all — there is no
    ///     "half a page" state to resume into;
    ///   • `run.counts[songId]` is the run's RUN-TO-DATE total, and every checkpoint hands the
    ///     store that total to SET (not a delta to add), so re-applying any checkpoint — a retry,
    ///     a resume that re-reads it, a duplicate call — is idempotent;
    ///   • the sort-drift guard below stops the one case where a row could be visited twice.
    /// Run the whole thing twice and the store lands on byte-identical bytes.
    ///
    /// ── THE SORT-DRIFT GUARD ──────────────────────────────────────────────────────────────────
    /// `lastPlayedDate` descending is not stable under mutation: play one song mid-walk and it
    /// jumps to row 0, shifting every later row by one, so an `offset` resume re-reads the row
    /// that sat just BEFORE the cursor. Folding that row a second time would add its plays twice —
    /// the single way a checkpointed walk can inflate a counter.
    ///
    /// The guard is a WATERMARK ON THE SORT KEY, not a set of row ids. `boundarySortMs` is the key
    /// of the last row folded; under a descending sort every row still to come has a key at or
    /// below it, so a row whose key is STRICTLY ABOVE it occupies a position the walk has already
    /// passed and is skipped. That covers unbounded drift for free — a row that drifts is a row
    /// that was just PLAYED, so its key is `now`, above everything already walked.
    ///
    /// A bounded id set survives only as the tie-breaker for rows whose key EQUALS the watermark,
    /// where the key cannot separate a re-served row from a genuinely new one. It is reset every
    /// time the watermark moves, so it holds one tie group rather than a sliding window.
    ///
    /// WHY NOT THE ID SET ALONE (what this replaced): it evicted the oldest id per newly folded
    /// row, so the first duplicate past the cap evicted a still-needed id, which then also slipped
    /// through — the window collapsed from the front and the rest of the walk double-folded. On a
    /// 3,000-row library interrupted at 1,500 with 1,100 rows played before the resume, ~73% of the
    /// library came back roughly DOUBLED, committed as authoritative, with no undo.
    ///
    /// RESIDUAL, bounded and harmless: the tail of nil-`lastPlayedDate` rows is one enormous tie
    /// group, so only the last 1,000 of them are covered exactly. A re-served row there can only
    /// inflate a counter if it has plays AND no last-played date, a shape Apple's counters do not
    /// produce (measured: non-nil count == non-zero count exactly, 117/117 over 225 songs).
    /// The mirror case — a row DELETED from the library mid-walk shifts rows earlier, so a resume
    /// skips one — costs a single row that the next full re-read picks up. Accepted, deliberately:
    /// the alternative (re-reading the whole library on every resume) is the bug being fixed.
    ///
    /// ── WHAT IS *NOT* DECIDED HERE ────────────────────────────────────────────────────────────
    /// `readNothing`, the high-water mark, the cross-source fold and provisional retirement are
    /// WHOLE-WALK judgements and are made once, by the caller, on a COMPLETED run. In particular
    /// `readNothing` (`scanned > 0 && withPlayCount == 0`) is true of the tail of every healthy
    /// descending walk, so evaluating it per checkpoint would call a good walk broken — and
    /// stamping a mark from a partial would make a genuinely broken read permanent.
    nonisolated static func walk(pager: any LibraryPager,
                                 run initial: Run,
                                 resolve: @escaping Resolver,
                                 pageLimit: Int = defaultPageLimit,
                                 checkpointRows: Int = defaultCheckpointRows,
                                 maxCheckpointRows: Int = defaultMaxCheckpointRows,
                                 nowMs: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                                 onProgress: @escaping @Sendable (Audit) async -> Void = { _ in },
                                 checkpoint: @escaping @Sendable (Run) async -> Void) async throws -> Run {
        var run = initial
        var recentOrder = run.boundaryRowIds
        var recent = Set(recentOrder)
        var sinceCheckpoint = 0
        // A run banked by a build that predates `playsAccum` carries none; derive it ONCE here so
        // the per-page audit stays O(1) for the rest of the walk.
        if run.playsAccum == nil { run.playsAccum = run.counts.values.reduce(0) { $0 + $1.n } }

        /// Remember one row id AT the current watermark. Bounded only as a backstop; the set is
        /// cleared whenever the watermark moves, so in normal walking it holds a handful of rows.
        func remember(_ rowId: String) {
            recentOrder.append(rowId)
            recent.insert(rowId)
            guard recentOrder.count > boundaryGuardCap else { return }
            let drop = recentOrder.count - boundaryGuardCap
            for old in recentOrder.prefix(drop) { recent.remove(old) }
            recentOrder.removeFirst(drop)
        }

        do {
            while true {
                // Cancellation is checked ONLY at a page boundary, on purpose: that is what keeps
                // the cursor page-aligned and makes "cancelled mid-batch" unrepresentable.
                try Task.checkCancellation()
                let page = try await pager.page(offset: run.cursor, limit: pageLimit)
                if page.isEmpty {
                    run.completed = true
                    run.stopReason = "Reached the end of your library"
                    run.updatedMs = nowMs()
                    // A FULL walk that reached the end has just measured the library — carry the
                    // number forward as the next run's progress denominator. `cursor` (rows the
                    // pager served) rather than `scanned` (rows folded), because the denominator's
                    // job is to predict how far the NEXT walk has to page.
                    if run.isFullWalk { run.libraryRowsEstimate = run.cursor }
                    // …and land a checkpoint on the way out. The `reachedMark` exit below always
                    // did; this one did not, so on a rejected commit the last interval's rows were
                    // never merged, and the audit's checkpoint count was under by one on EVERY
                    // successful full walk.
                    run.checkpoints += 1
                    await checkpoint(run)
                    break
                }
                var reachedMark = false
                for row in page {
                    // Sorted descending ⇒ the first row at/below the mark ends an INCREMENTAL
                    // walk. Rows with no last-played date sort last and are unplayed, so they end
                    // it too.
                    if let since = run.since {
                        guard let lastMs = row.lastPlayedMs, lastMs > since else {
                            reachedMark = true
                            break
                        }
                    }
                    // SORT-DRIFT GUARD (see the doc above).
                    let key = sortKey(row.lastPlayedMs)
                    if let boundary = run.boundarySortMs {
                        // Strictly ABOVE the last row folded ⇒ this position has already been
                        // walked, so the row either drifted to the front or was re-served by an
                        // offset resume. Either way, folding it again is the double-count.
                        if key > boundary { continue }
                        // Exactly AT the watermark the key cannot tell a re-served row from a
                        // genuinely new one with the same timestamp — that is what the id set is.
                        if key == boundary, recent.contains(row.rowId) { continue }
                        // The watermark moved: the previous tie group can never be re-served
                        // again, so drop it rather than carrying a sliding window.
                        if key != boundary { recentOrder.removeAll(); recent.removeAll() }
                    } else if recent.contains(row.rowId) {
                        continue    // a run banked before the watermark existed
                    }
                    run.boundarySortMs = key
                    remember(row.rowId)
                    run.scanned += 1
                    if let lastMs = row.lastPlayedMs, lastMs > (run.maxLastPlayedMs ?? 0) {
                        run.maxLastPlayedMs = lastMs
                    }
                    // nil ⇒ never played on a library fetch. Never stored, never written as a 0.
                    guard let plays = row.playCount, plays > 0 else { continue }
                    run.withPlayCount += 1
                    guard let songId = resolve(row.catalogId, row.title, row.artist) else {
                        run.unresolved += 1
                        continue
                    }
                    // Apple can hold several library rows for one catalog song (a duplicate add,
                    // the same track off two albums). They are the SAME song here, so their
                    // counters SUM — see the idempotence argument in the doc above.
                    let prior = run.counts[songId]
                    run.counts[songId] = .init(n: (prior?.n ?? 0) + plays,
                                               lastMs: maxDate(prior?.lastMs, row.lastPlayedMs))
                    run.playsAccum = (run.playsAccum ?? 0) + plays
                }
                run.cursor += page.count
                sinceCheckpoint += page.count
                run.updatedMs = nowMs()
                run.boundaryRowIds = recentOrder
                // ONLY an EMPTY page ends the walk (handled at the top of the loop). A SHORT page
                // deliberately does not: MusicKit gives no guarantee that every batch is full, and
                // treating a short one as the end would silently truncate the library and then
                // report success. The cost of being strict is one extra request per walk, which
                // returns nothing.
                if reachedMark {
                    run.completed = true
                    run.stopReason = "Everything played since the last read"
                }
                // Progress every PAGE, not every checkpoint: a 96k walk otherwise shows "Songs
                // read 0" for the first half-minute and then steps in 5,000s. This is publish-only
                // (an O(1) value struct, no disk), so it costs a `@Observable` invalidation.
                await onProgress(run.audit)
                let interval = checkpointInterval(accumulatedSongs: run.counts.count,
                                                  floor: checkpointRows, cap: maxCheckpointRows)
                if run.completed || sinceCheckpoint >= interval {
                    run.checkpoints += 1
                    await checkpoint(run)
                    sinceCheckpoint = 0
                }
                if run.completed { break }
            }
        } catch {
            // Land what the walk HAS before giving up — the whole point of the rebuild. The cursor
            // is page-aligned and the checkpoint write is atomic, so this can never leave a
            // half-written document, and the next run picks up from here.
            run.completed = false
            run.updatedMs = nowMs()
            run.boundaryRowIds = recentOrder
            run.stopReason = error is CancellationError
                ? "Stopped — it will pick up where it left off"
                : "Apple Music stopped answering: \(error.localizedDescription)"
            run.checkpoints += 1
            await checkpoint(run)
            throw error
        }
        return run
    }
}

#if canImport(MusicKit)
import MusicKit

extension AppleMusicPlayCountCapture {

    /// Can this build + device read play counts right now? Same gates streaming playback uses —
    /// the Simulator can never authorize, so this is device/Mac-real.
    static var isAvailable: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    // NOTE there is no all-in-one `capture(since:resolve:)` here any more. It collected the whole
    // library in a function-local `var` and returned it once, at 100% — so on a 96,000-song
    // library ANY interruption in those 2-5 minutes discarded every row. `walk` (above) replaced
    // it rather than joining it: two walks, one of them unresumable, is exactly how the wrong one
    // stays wired up. `MusicKitLibraryPager` below is what feeds the survivor.

    /// The catalog store id for a LIBRARY song. `id.rawValue` is the LIBRARY id (`i.…`), not a
    /// catalog id — the catalog id only rides the opaque `playParameters` blob. Same technique as
    /// `AppleMusicLibraryIndexer.catalogId(of:)` / `PlaylistWriteBack.catalogIds(of:)`.
    ///
    /// `encoder` is threaded in rather than allocated per song: this runs once per library row
    /// (96k times on the owner's library) and a fresh `JSONEncoder` each time was measurable.
    static func catalogId(of song: MusicKit.Song, encoder: JSONEncoder = JSONEncoder()) -> String? {
        guard let params = song.playParameters,
              let data = try? encoder.encode(params),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["catalogId", "catalogID"] {
            if let value = obj[key] { return "\(value)" }
        }
        if (obj["isLibrary"] as? Bool) != true, let value = obj["id"] { return "\(value)" }
        return nil
    }
}

/// The real `LibraryPager` — `MusicLibraryRequest<Song>` sorted `lastPlayedDate` descending.
///
/// Two paging mechanisms, used for what each is actually good for:
///   • `MusicItemCollection.nextBatch()` while the walk stays in ONE process. This is the proven
///     path (`AppleMusicLibraryIndexer` and the previous `capture(since:)` both ride it) and it
///     avoids re-issuing a request per page.
///   • `MusicLibraryRequest.offset` whenever the caller asks for a position this pager is not
///     already sitting on — which is precisely the RESUME case, after a relaunch, where the
///     `nextBatch()` handle no longer exists and could never have been serialized anyway.
///
/// An `actor` because it carries that cursor: the walk is `nonisolated` and must not be holding
/// the main actor, and two concurrent walks are prevented at the service, not here.
actor MusicKitLibraryPager: AppleMusicPlayCountCapture.LibraryPager {
    /// The collection most recently served, and the offset of the row AFTER it.
    private var last: MusicItemCollection<MusicKit.Song>?
    private var nextOffset: Int = -1
    /// One encoder for the whole walk — `catalogId(of:)` runs per row.
    private let encoder = JSONEncoder()

    init() {}

    func page(offset: Int, limit: Int) async throws -> [AppleMusicPlayCountCapture.LibraryRow] {
        var current: MusicItemCollection<MusicKit.Song>?
        if offset == nextOffset, let last, last.hasNextBatch {
            current = try await last.nextBatch(limit: limit)
        }
        if current == nil {
            var request = MusicLibraryRequest<MusicKit.Song>()
            // `lastPlayedDate` is a first-class LibrarySongSortProperties key, so the ordering is
            // done BY THE LIBRARY — no client-side sort over 96k rows.
            request.sort(by: \.lastPlayedDate, ascending: false)
            request.limit = limit
            request.offset = offset
            current = try await request.response().items
        }
        guard let current, !current.isEmpty else {
            last = nil
            nextOffset = -1
            return []
        }
        let enc = encoder
        let rows = current.map { song in
            AppleMusicPlayCountCapture.LibraryRow(
                rowId: song.id.rawValue,
                catalogId: AppleMusicPlayCountCapture.catalogId(of: song, encoder: enc),
                title: song.title,
                artist: song.artistName,
                playCount: song.playCount,
                lastPlayedMs: song.lastPlayedDate.map { $0.timeIntervalSince1970 * 1000 })
        }
        last = current
        nextOffset = offset + rows.count
        return rows
    }
}

#else

extension AppleMusicPlayCountCapture {
    /// No MusicKit in this build — the capture degrades to "read nothing", and the all-zero guard
    /// in `AMPlayBaselineStore.replaceAll` makes storing that a no-op rather than a wipe.
    static var isAvailable: Bool { false }
}

/// No MusicKit ⇒ no library to page. An empty first page ends the walk immediately, which the
/// caller reports as "read nothing" and the store's all-zero guard makes a no-op rather than a
/// wipe — the same degradation `capture` above already has.
actor MusicKitLibraryPager: AppleMusicPlayCountCapture.LibraryPager {
    init() {}
    func page(offset: Int, limit: Int) async throws -> [AppleMusicPlayCountCapture.LibraryRow] { [] }
}

#endif
