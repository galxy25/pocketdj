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
/// ── OFF THE MAIN ACTOR, AND NEVER ON LAUNCH ──────────────────────────────────────────────────
/// A 90k-song walk takes minutes (the lesson `AppleMusicLibraryIndexer` already carries), so this
/// is `nonisolated`, explicit-trigger only, and INCREMENTAL: the walk is sorted by
/// `lastPlayedDate` descending and stops at the store's high-water mark, so a routine refresh
/// touches only what was played since the last one. A nil mark (first ever capture) walks
/// everything — and only then is the result a complete SNAPSHOT.
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
        /// FULL walk ⇒ `counts` is a complete snapshot and may be SET wholesale. An INCREMENTAL
        /// walk only carries recently-played rows, so its counts must be merged onto the previous
        /// snapshot, never used to replace it (see `merged`).
        var isFullWalk: Bool = true
    }

    /// Resolve one Apple library row to a PocketDJ song id. Injected (rather than reaching into
    /// `AppModel`) so the whole mapping layer is unit-testable with no MusicKit and no catalog.
    /// Returns nil for a row PocketDJ doesn't know — those are counted, not guessed at.
    typealias Resolver = @Sendable (_ catalogId: String?, _ title: String, _ artist: String) -> String?

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
    /// deliberate reset in Music.app is picked up by the next FULL walk.
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

    /// Newest of two optional epoch-ms dates (nil is "no date", never a zero).
    static func maxDate(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }

    /// Fold a walk's `Result` into the counts to STORE, honouring full-vs-incremental.
    static func countsToStore(_ result: Result,
                              existing: [String: AMPlayBaselineStore.Entry]) -> [String: AMPlayBaselineStore.Entry] {
        result.isFullWalk ? result.counts : merged(existing: existing, incremental: result.counts)
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

    /// Walk the library newest-play-first and collect play counts.
    ///
    /// `since` = the store's high-water mark (epoch ms). Rows whose `lastPlayedDate` is at/below
    /// it end the walk — everything older already has its counter in the snapshot. nil = full
    /// walk (and only a full walk yields a replaceable snapshot).
    ///
    /// `nonisolated` + `async`: the caller must NOT be holding the main actor. Explicit trigger
    /// only; never wire this to app launch.
    nonisolated static func capture(since: Double?, resolve: @escaping Resolver,
                                    nowMs: Double = Date().timeIntervalSince1970 * 1000) async throws -> Result {
        var request = MusicLibraryRequest<MusicKit.Song>()
        // `playCount` and `lastPlayedDate` are both first-class LibrarySongSortProperties keys, so
        // this ordering is done BY THE LIBRARY — no client-side sort over 90k rows.
        request.sort(by: \.lastPlayedDate, ascending: false)
        let response = try await request.response()

        var result = Result(capturedAtMs: nowMs, isFullWalk: since == nil)
        var batch: MusicItemCollection<MusicKit.Song>? = response.items
        outer: while let current = batch, !current.isEmpty {
            for song in current {
                let lastMs = song.lastPlayedDate.map { $0.timeIntervalSince1970 * 1000 }
                // Sorted descending ⇒ the first row at/below the mark ends the incremental walk.
                // Rows with NO last-played date sort last and can never be newer than the mark,
                // so they end it too — and they are unplayed, which is nothing to record.
                if let since {
                    guard let lastMs, lastMs > since else { break outer }
                }
                result.scanned += 1
                if let lastMs, lastMs > (result.maxLastPlayedMs ?? 0) { result.maxLastPlayedMs = lastMs }
                // nil ⇒ never played (see the type doc). Never stored, never written as a 0.
                guard let plays = song.playCount, plays > 0 else { continue }
                guard let songId = resolve(catalogId(of: song), song.title, song.artistName) else {
                    result.unresolved += 1
                    continue
                }
                // Apple can hold several library rows for one catalog song (a duplicate add, the
                // same track off two albums). They are the SAME song to PocketDJ, so their
                // counters SUM — taking the max would silently lose plays.
                let prior = result.counts[songId]
                result.counts[songId] = .init(n: (prior?.n ?? 0) + plays,
                                              lastMs: maxDate(prior?.lastMs, lastMs))
            }
            batch = current.hasNextBatch ? try await current.nextBatch() : nil
        }
        return result
    }

    /// The catalog store id for a LIBRARY song. `id.rawValue` is the LIBRARY id (`i.…`), not a
    /// catalog id — the catalog id only rides the opaque `playParameters` blob. Same technique as
    /// `AppleMusicLibraryIndexer.catalogId(of:)` / `PlaylistWriteBack.catalogIds(of:)`.
    private static func catalogId(of song: MusicKit.Song) -> String? {
        guard let params = song.playParameters,
              let data = try? JSONEncoder().encode(params),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["catalogId", "catalogID"] {
            if let value = obj[key] { return "\(value)" }
        }
        if (obj["isLibrary"] as? Bool) != true, let value = obj["id"] { return "\(value)" }
        return nil
    }
}

#else

extension AppleMusicPlayCountCapture {
    /// No MusicKit in this build — the capture degrades to "read nothing", and the all-zero guard
    /// in `AMPlayBaselineStore.replaceAll` makes storing that a no-op rather than a wipe.
    static var isAvailable: Bool { false }

    nonisolated static func capture(since: Double?, resolve: @escaping Resolver,
                                    nowMs: Double = Date().timeIntervalSince1970 * 1000) async throws -> Result {
        Result(capturedAtMs: nowMs, isFullWalk: since == nil)
    }
}

#endif
