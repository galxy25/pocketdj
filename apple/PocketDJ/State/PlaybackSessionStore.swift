import Foundation

/// Version stamp on the persisted snapshot — bump on breaking shape changes. A mismatched
/// (older/newer) file simply doesn't restore (`load()` → nil); it is never migrated.
let playbackSessionSchemaVersion = 1

/// Off-main, serialized, last-writer-wins JSON writer (the `MixSessionWriter` pattern): the
/// atomic file write runs on a background executor, and a monotonic `version` guard means a
/// late-arriving stale snapshot can never clobber a newer one — including the DELETE that
/// `clear()` issues (a nil payload removes the file). `markWritten` advances the watermark
/// for a write `flush()` already performed synchronously.
private actor PlaybackSessionWriter {
    private var written = 0
    func write(_ data: Data?, version: Int, to url: URL) {
        guard version > written else { return }
        written = version
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
    func markWritten(_ version: Int) { written = max(written, version) }
}

/// Durable Playback Sessions — the single overwrite-in-place snapshot of the app-scoped
/// `SetlistPlayer` run, written IN REAL TIME as playback happens (never at exit): the full
/// queue (played + current + up next, including shuffle order and live-queue edits such as
/// jukebox guest requests), the index cursor, and the current song's position. Force-quit or
/// restart the phone, reopen, and `SetlistPlayer.restore(from:)` rebuilds the Now Playing
/// deck exactly as it was — held, never auto-playing.
///
/// Each queue row snapshots title/artist/lengthMs so a restore is SELF-CONTAINED and instant:
/// no catalog lookup happens at launch (the catalog may not even be loaded yet). The file is
/// ~KBs (`pocketdj-playback-session.json` in Application Support); structural changes write
/// immediately, position refreshes are throttled (~5 s) while playing and immediate on a
/// pause/resume transition. `load()` is deliberately lenient — ANY decode failure returns nil
/// so a corrupt/old file can never block or crash launch.
@MainActor
final class PlaybackSessionStore {

    /// The run's origin collection. `kind` is a `PlayHistoryStore.PlaySource` rawValue
    /// (persisted token — never rename); `id` is the sequencer's `sourceSetlistId`; `name`
    /// the captured display name ("Friday Night Mix").
    struct SourceRef: Codable, Equatable {
        var kind: String
        var id: String?
        var name: String?
        /// NAVIGABLE origin collection (the Up Next header's collection button target):
        /// a `PlaySource` rawValue + the origin collection's id. Optional so pre-existing
        /// snapshots (which lack the keys) still decode and restore.
        var originKind: String?
        var originId: String?
    }

    /// One queue row — a self-contained snapshot of `SetlistPlayer.Item` (fresh `uid`s are
    /// minted on restore; a uid is per-instance row identity, not durable data).
    struct Row: Codable, Equatable {
        var songId: String
        var title: String
        var artist: String
        var lengthMs: Int?
        var repeatCount: Int?
    }

    struct Snapshot: Codable, Equatable {
        var schemaVersion: Int = playbackSessionSchemaVersion
        /// Identity of ONE run — fresh per `play()`, re-adopted by a restore.
        var sessionId: String
        var source: SourceRef
        var queue: [Row]
        /// The cursor: `queue[0..<index]` = played this run, `queue[index]` = current.
        var index: Int
        /// Position within the CURRENT song (ms from the song's own 0:00 — never a
        /// shared-album-file offset), so restore can resume mid-song.
        var positionMs: Int
        var isPlaying: Bool
        /// Whole-session repeat mode (`RepeatMode` rawValue). Optional/defaulted so pre-existing
        /// snapshots (written before this field) still decode without a schema bump — the same
        /// forward-compat discipline `SourceRef.originKind/originId` follow.
        var repeatMode: String? = nil
        /// Whether the running queue's upcoming tail is live-shuffled. Optional/defaulted so
        /// pre-existing snapshots still decode.
        var shuffleEnabled: Bool? = nil
        /// Epoch ms of the last write (informational — a session never expires on its own).
        var updatedAt: Double
    }

    /// Min seconds between position-only writes while playing (injectable for tests).
    var positionWriteInterval: TimeInterval = 5

    private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }
    private let writer = PlaybackSessionWriter()
    /// The in-memory truth of the current run's snapshot (nil = no active session).
    private var current: Snapshot?
    private var version = 0
    private var lastWriteAt: TimeInterval = 0

    /// NO disk read here — construction happens in `PocketDJApp.init()`, before the first
    /// frame (the visionOS first-frame lesson). The snapshot is READ later, by `load()`
    /// from RootView's launch task.
    init(fileURL: URL = PlaybackSessionStore.defaultURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-playback-session.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real session — and existing UI tests see no leftover deck). Mirrors
    /// `MixSessionStore.launchURL` / `PlayHistoryStore.launchURL`.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-playback-session.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: - Writes

    /// A STRUCTURAL change (play, index move, live-queue edit) — persists immediately.
    func save(_ snapshot: Snapshot, now: TimeInterval = Date().timeIntervalSince1970) {
        current = snapshot
        current?.updatedAt = now * 1000
        writeNow(at: now)
    }

    /// A position/play-state refresh for the CURRENT session. Throttled to one write per
    /// `positionWriteInterval` while playing; a pause/resume TRANSITION writes immediately
    /// (the position a restore resumes at must be the paused one, not up to 5 s stale).
    /// Steady paused state writes nothing (the position can't move). No-op when no session
    /// is active (`save`/`load-adopt` establish one).
    func updatePosition(ms: Int, isPlaying: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard var snap = current else { return }
        let wasPlaying = snap.isPlaying
        snap.positionMs = ms
        snap.isPlaying = isPlaying
        snap.updatedAt = now * 1000
        current = snap
        if isPlaying != wasPlaying {
            writeNow(at: now)
        } else if isPlaying, now - lastWriteAt >= positionWriteInterval {
            writeNow(at: now)
        }
    }

    /// End of the session (stop / natural end-of-set): forget it and delete the file — a
    /// finished set must not rehydrate on the next launch.
    func clear() {
        current = nil
        version += 1
        let v = version
        let url = fileURL
        let w = writer
        Task { await w.write(nil, version: v, to: url) }
    }

    // MARK: - Read

    /// The persisted snapshot, or nil. LENIENT: any read/decode failure, a schema-version
    /// mismatch, or an empty queue → nil — never throws, never blocks launch on repair.
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.schemaVersion == playbackSessionSchemaVersion,
              !snap.queue.isEmpty
        else { return nil }
        return snap
    }

    /// Force-persist now (scene → background). SYNCHRONOUS (encode + atomic write inline) so
    /// an OS suspension right after `.background` can't drop the latest position — then the
    /// writer watermark advances so an in-flight async save carrying an older snapshot can't
    /// regress what was just written (the `MixSessionStore.flush` doctrine).
    func flush(now: TimeInterval = Date().timeIntervalSince1970) {
        guard let current else { return }
        version += 1
        let v = version
        lastWriteAt = now
        var snap = current
        snap.updatedAt = now * 1000
        self.current = snap
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
        let w = writer
        Task { await w.markWritten(v) }
    }

    // MARK: - Test seam

    /// UI-test seam: when `PDJ_SEED_PLAYBACK_SESSION` is set, write a canned mid-set snapshot
    /// (3 rows, index 1, 42 s in, was playing) to the session file — so a UI test can launch
    /// "as if" the app was killed mid-set and assert the restored deck. Exercises the REAL
    /// load path (the file on disk is what restores). No-op outside the seam.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_PLAYBACK_SESSION"] != nil else { return }
        let snap = Snapshot(sessionId: "pses_fixture",
                            source: SourceRef(kind: "playlist", id: "pls_fixture", name: "Warmup"),
                            queue: [
                                Row(songId: "sng_1", title: "Neon", artist: "Aria", lengthMs: 200_000, repeatCount: nil),
                                Row(songId: "sng_2", title: "Pulse", artist: "Aria", lengthMs: 210_000, repeatCount: nil),
                                Row(songId: "sng_3", title: "Drift", artist: "Cass", lengthMs: 190_000, repeatCount: nil),
                            ],
                            index: 1, positionMs: 42_000, isPlaying: true,
                            updatedAt: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Internals

    /// Immediate, versioned write of the in-memory snapshot; the actual I/O is off-main.
    private func writeNow(at now: TimeInterval) {
        guard let current else { return }
        version += 1
        let v = version
        lastWriteAt = now
        guard let data = try? JSONEncoder().encode(current) else { return }
        let url = fileURL
        let w = writer
        Task { await w.write(data, version: v, to: url) }
    }
}
