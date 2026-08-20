import Foundation
import Observation

/// Tracks WHEN and HOW OFTEN each song is played on this device — the signal the storage
/// manager's soft-cap prune orders by (least-recently-played burned media is evicted
/// first). Plays funnel in from every surface: `RipsStore.nowPlaying` transitions (single
/// rows, set lists, burned local files, rip streaming), `PlaybackCoordinator.play`
/// successes (Apple Music streaming, which never touches `RipsStore.nowPlaying`), and the
/// Mix decks' transport funnel (`MixEngine.setPlaying`). A short re-count window absorbs
/// the overlap between those hooks (a burned play fires both 1 and 2) and seek/restarts.
///
/// Persists to Application Support `pocketdj-play-stats.json` (mirrors CollectionsStore
/// durable-JSON: atomic save, decode-on-init, PDJ_USE_FIXTURE test seam). Syncs across the
/// user's devices via CloudSyncService (whole-document LWW; `reloadFromDisk` applies pulls).
@MainActor
@Observable
final class PlayStatsStore {

    /// One song's play history (all this needs to order an LRP prune).
    struct Stat: Codable, Equatable {
        var playCount: Int
        /// Epoch ms of the most recent play (refreshed even inside the re-count window).
        var lastPlayedAt: Double
        /// How many of `playCount` were streamed through Apple Music — i.e. how many APPLE ALSO
        /// COUNTED on its own side. Subtracting these is what stops a combined lifetime total
        /// from counting one play twice once the next Apple snapshot lands (see
        /// `AMPlayBaselineStore`). OPTIONAL so older documents keep decoding untouched — new
        /// optional field, no schema bump (a bump has previously discarded user data here).
        var appleCount: Int?
        /// Plays recorded BEFORE this build began tagging plays by source — i.e. plays whose
        /// origin is UNKNOWABLE. `appleCount` is a per-row aggregate with no history, so a row
        /// written by an older build carries no way to tell an Apple Music stream from a rip.
        ///
        /// Stamped ONCE, at the upgrade migration (`migrateUntaggedRows`), and never touched
        /// again: every later play increments `playCount` (and `appleCount` when Apple saw it)
        /// while this stays put, so the untrusted share shrinks as the trusted one grows. Nil on
        /// every row created after the migration — a fresh install has none at all.
        ///
        /// Why it matters: without it, `nonApplePlayCount` classifies the whole pre-upgrade
        /// history as "Apple never saw this" and adds it on top of Apple's 144,517-play snapshot,
        /// which already contains the Apple share of it. Every legacy row would read too high,
        /// permanently.
        var preTagPlayCount: Int?
        /// Lifetime count of SKIPPED playbacks (advanced away from under 50% played — the
        /// SkipTracker verdict). ADDITIVE-OPTIONAL, no schema bump (precedent: `appleCount`,
        /// `preTagPlayCount` — a bump has previously discarded user data here). nil = 0.
        ///
        /// Cumulative HERE, not derived from the history log: the log is capped at
        /// `PlayHistoryStore.maxEvents` and trims its oldest events, so a per-song total that
        /// must survive relaunch (and years of listening) has to live in the aggregate store.
        var skipCount: Int? = nil
    }

    /// The persisted, versioned document.
    struct Document: Codable {
        var schemaVersion: Int = playStatsSchemaVersion
        var stats: [String: Stat] = [:]
        /// Epoch ms the source-tagging migration ran. Its PRESENCE is the flag — a nil means the
        /// rows in this document predate `appleCount` and must be stamped (see `Stat.preTagPlayCount`).
        /// ADDITIVE-OPTIONAL: an older document decodes to nil, which is exactly the state that
        /// triggers the migration. No schema bump.
        var appleTaggingMigratedAtMs: Double?
    }

    private(set) var stats: [String: Stat] = [:]
    /// Epoch ms the source-tagging migration ran — see `Document.appleTaggingMigratedAtMs`.
    private(set) var appleTaggingMigratedAtMs: Double?
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }

    /// Repeated notes for the SAME song inside this window refresh `lastPlayedAt` but don't
    /// re-count — a seek/restart (or the burned-play double-hook) isn't a second listen.
    nonisolated static let recountWindowMs: Double = 30_000

    init(fileURL: URL = PlayStatsStore.defaultURL(),
         now: Double = Date().timeIntervalSince1970 * 1000) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            stats = doc.stats
            appleTaggingMigratedAtMs = doc.appleTaggingMigratedAtMs
        }
        migrateUntaggedRows(now: now)
    }

    /// Stamp every row that predates source tagging. A row written by THIS build always carries a
    /// `preTagPlayCount` (0 for a brand-new song — see `notePlayed`), so a NIL is an unambiguous
    /// "an older build wrote this" and can be migrated safely at ANY adoption point: launch, or a
    /// CloudSync pull that brings rows from a device still running the old build.
    ///
    /// Runs on a fresh install too (against an empty map), which is the point: the flag lands
    /// immediately, so nothing created from here on is ever mistaken for legacy.
    private func migrateUntaggedRows(now: Double) {
        var changed = false
        for (id, var s) in stats where s.preTagPlayCount == nil {
            s.preTagPlayCount = s.playCount
            stats[id] = s
            changed = true
        }
        if appleTaggingMigratedAtMs == nil { appleTaggingMigratedAtMs = now; changed = true }
        if changed { save() }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-play-stats.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches
    /// the user's real stats). Mirrors CollectionsStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-play-stats.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Record a play. `at` is injectable for tests; callers use the default (now).
    ///
    /// `appleCounted` TAGS THE SOURCE and is the whole double-count defence. Apple increments its
    /// OWN counter whenever PocketDJ streams through `ApplicationMusicPlayer`, so such a play will
    /// arrive again in the next `AMPlayBaselineStore` snapshot; recording it here as well is
    /// correct for THIS store (it is a play, and the LRP prune must see it) but must be
    /// subtractable when the two are combined. Everything else — rip, stem, vinyl, digital, local
    /// file, Mix decks — leaves it false and accumulates permanently.
    func notePlayed(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000,
                    appleCounted: Bool = false) {
        guard !songId.isEmpty else { return }
        if var s = stats[songId] {
            if nowMs - s.lastPlayedAt >= Self.recountWindowMs {
                s.playCount += 1
                if appleCounted { s.appleCount = (s.appleCount ?? 0) + 1 }
            }
            s.lastPlayedAt = max(s.lastPlayedAt, nowMs)
            stats[songId] = s
        } else {
            // `preTagPlayCount: 0` is LOAD-BEARING, not decoration: it is what makes a nil on some
            // other row mean "written before tagging existed" rather than "no legacy plays". The
            // migration relies on that distinction to stay safe when re-run after a cloud pull.
            stats[songId] = Stat(playCount: 1, lastPlayedAt: nowMs,
                                 appleCount: appleCounted ? 1 : nil, preTagPlayCount: 0)
        }
        save()
    }

    /// Record a SKIP (the SkipTracker verdict: advanced away with <50% played). Increments the
    /// lifetime `skipCount` and saves — the same persistence discipline as `notePlayed`, so the
    /// total survives relaunch. No re-count window: the tracker classifies each playback at most
    /// once, so every call here is a distinct verdict.
    func noteSkipped(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        if var s = stats[songId] {
            s.skipCount = (s.skipCount ?? 0) + 1
            stats[songId] = s
        } else {
            // Every real playback path already notePlayed()'d at track start, so this row should
            // exist — belt-and-braces for a skip arriving first. `playCount: 0` (not 1): a skip
            // is not a play, and `preTagPlayCount: 0` keeps the legacy-migration invariant (see
            // `notePlayed`).
            stats[songId] = Stat(playCount: 0, lastPlayedAt: nowMs, appleCount: nil,
                                 preTagPlayCount: 0, skipCount: 1)
        }
        save()
    }

    /// Every song with a non-zero lifetime skip count, as a plain value map — the snapshot the
    /// rec ranking's skip penalty is built from (same shape as `PlayCountService.snapshot()`).
    func skipCountsSnapshot() -> [String: Int] {
        stats.compactMapValues { s in (s.skipCount ?? 0) > 0 ? s.skipCount : nil }
    }

    /// Lifetime skip count for one song (0 if never skipped) — the per-song read History uses.
    func skipCount(_ songId: String) -> Int { stats[songId]?.skipCount ?? 0 }

    /// PEER-PLAY SEAM: when this song was last played on ANOTHER device. Wired at app init to
    /// `PlayHistoryStore.lastPlayedAtAnyDevice` once history merges across devices; nil in tests.
    ///
    /// DERIVED, NOT ACCUMULATED — deliberately. The obvious implementation is to feed merged peer
    /// events into `notePlayed`, but that mutates a running counter from a log that can be
    /// re-merged (a re-pull, a device restore, a backup import), and every replay would inflate the
    /// count and drag the eviction order with it. Reading the merged log at query time cannot
    /// double-count by construction, no bookkeeping required.
    @ObservationIgnored var peerLastPlayedAt: ((String) -> Double?)?

    /// Epoch ms of the last play ON ANY DEVICE, or nil if never played (⇒ pruned first).
    /// This is the storage prune's LRP key, so a play on the Mac protects the phone's copy too.
    func lastPlayedAt(_ songId: String) -> Double? {
        let local = stats[songId]?.lastPlayedAt
        guard let peer = peerLastPlayedAt?(songId) else { return local }
        guard let local else { return peer }
        return max(local, peer)
    }

    /// This device's own last play, ignoring peers — for anything that must reason about local
    /// behaviour specifically rather than "was this listened to anywhere".
    func lastPlayedAtLocally(_ songId: String) -> Double? { stats[songId]?.lastPlayedAt }
    func playCount(_ songId: String) -> Int { stats[songId]?.playCount ?? 0 }

    /// Plays Apple did NOT also count — the only part of this store that may be ADDED to an
    /// Apple snapshot without double-counting. See `notePlayed(appleCounted:)`.
    ///
    /// `appleKnowsSong` is the legacy join. A row's `preTagPlayCount` plays predate source
    /// tagging, so their origin is unknowable; when Apple's baseline HAS a counter for this song,
    /// the honest reading is that those plays are already inside it, and adding them would
    /// double-count the entire pre-upgrade history against the 144,517-play snapshot. When Apple
    /// has never heard of the song (vinyl, a rip, My Digital), no snapshot can contain them and
    /// they are kept in full.
    ///
    /// The residual error is a deliberate UNDER-count and it is bounded: a legacy row for a song
    /// Apple also knows loses whatever share of its untagged plays were really rips. Under-showing
    /// is the recoverable direction — over-showing is not, because there is no way back to the
    /// true number once a count has been inflated.
    func nonApplePlayCount(_ songId: String, appleKnowsSong: Bool = false) -> Int {
        guard let s = stats[songId] else { return 0 }
        return Self.nonAppleCount(s, appleKnowsSong: appleKnowsSong)
    }

    private static func nonAppleCount(_ s: Stat, appleKnowsSong: Bool) -> Int {
        let untrusted = appleKnowsSong ? (s.preTagPlayCount ?? 0) : 0
        return max(0, s.playCount - (s.appleCount ?? 0) - untrusted)
    }

    /// A pure copy of the NON-APPLE counts, for the combined lifetime total's off-main readers.
    /// `appleKnownSongIds` is the baseline's key set — the same legacy join `nonApplePlayCount`
    /// makes, applied in bulk.
    func nonApplePlayCountsSnapshot(appleKnownSongIds: Set<String> = []) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(stats.count)
        for (id, s) in stats {
            let n = Self.nonAppleCount(s, appleKnowsSong: appleKnownSongIds.contains(id))
            if n > 0 { out[id] = n }
        }
        return out
    }

    /// A pure copy of the play counts for OFF-MAIN weighting (the Collectors Puzzle
    /// sampler snapshots this on the main actor, then samples detached).
    func playCountsSnapshot() -> [String: Int] { stats.mapValues(\.playCount) }

    /// This app's own last-played stamps in bulk (epoch ms), for the same OFF-MAIN consumers.
    ///
    /// LOCAL ONLY — deliberately not folded through the `peerLastPlayedAt` seam. That seam is a
    /// per-song closure into `PlayHistoryStore`, and calling it once per row here would turn a
    /// dictionary map into tens of thousands of history lookups on the main actor. The merge that
    /// matters (Apple's far larger baseline) happens in `PlayCountService.lastPlayedSnapshot`.
    func lastPlayedSnapshot() -> [String: Double] { stats.mapValues(\.lastPlayedAt) }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW — see the sync design doc).
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        stats = doc.stats
        // A cloud copy from a device that never ran the migration must not un-set the flag here —
        // take the OLDER of the two marks so the legacy era stays covered on both sides.
        appleTaggingMigratedAtMs = [appleTaggingMigratedAtMs, doc.appleTaggingMigratedAtMs]
            .compactMap { $0 }.min()
        migrateUntaggedRows(now: Date().timeIntervalSince1970 * 1000)
    }

    /// Wipe all play history: reset the in-memory map (so the UI updates immediately) and
    /// remove the persisted document. `try?` swallows a missing file, mirroring `save()`.
    func clear() {
        stats = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let doc = Document(stats: stats, appleTaggingMigratedAtMs: appleTaggingMigratedAtMs)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let playStatsSchemaVersion = 1
