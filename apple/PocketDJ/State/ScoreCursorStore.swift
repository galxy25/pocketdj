import Foundation

// MARK: - ScoreCursorStore — where each saved instrumental's score cursor was last left
//
// The score's playback cursor (Studio ▸ Instruments ▸ a saved instrumental) used to be WIPED every
// time a score appeared. That was not laziness: `InstrumentEngine` has ONE replay clock, so a
// position parked by replaying take A would have highlighted take B's score if it survived the
// navigation. Clearing it was the cheap way to keep one take's playback off another take's page.
//
// This is the honest fix — remember the position KEYED BY TAKE. Opening a score restores THAT
// take's cursor and nothing else; a take that has never been replayed still opens clean, so the
// cross-take bleed the clear was defending against cannot happen either way.
//
// DURABLE, not session-scoped: "stay where it was last played" reads the same to a user whether
// they navigated away or quit the app, and a cursor that survives one but not the other would
// register as the bug half-fixed. The cost is a few dozen bytes per instrumental in a sibling of
// the studio document (`pocketdj-studio.cursors.json`) — the `CollectionStatsCache` shape: a small
// Codable map, decode-on-init, atomic write, `PDJ_USE_FIXTURE` covered through the studio doc's
// own launch seam.
//
// DEVICE-LOCAL. It is deliberately NOT registered with CloudSyncService: only the media-free cue
// mirror syncs out of the Studio document (see `StudioStore.cueSyncFileURL`), and a viewing
// position is per-device by nature — the Mac's cursor has no business moving on the phone.
@MainActor
final class ScoreCursorStore {

    /// One take's parked cursor. `updatedAt` exists for the cap eviction below — the oldest marks
    /// go first, so a library with thousands of instrumentals can't grow this file without bound.
    struct Mark: Codable, Equatable {
        /// Score-clock ms (0 ms = beat 1, the quantizer's anchor — the same clock
        /// `InstrumentEngine.replayPositionMs()` reports).
        var ms: Int
        /// Epoch ms this mark was last written.
        var updatedAt: Double
    }

    /// The persisted document (versioned like every other durable-JSON store here).
    struct Document: Codable {
        var schemaVersion: Int = scoreCursorSchemaVersion
        var marks: [String: Mark] = [:]
    }

    /// Most takes kept. Well past any real instrumentals library, and a hard bound on a file that
    /// is otherwise written on every seek.
    nonisolated static let capacity = 500
    /// Upper clamp on a stored position (24 h — `InstrumentEngine`'s own replay-clock ceiling), so
    /// a corrupt document can never hand a wild ms back to the transport.
    nonisolated static let maxMs = 86_400_000

    private var marks: [String: Mark] = [:]
    private let fileURL: URL

    init(fileURL: URL = ScoreCursorStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            marks = doc.marks
        }
    }

    /// The cursor file for a given studio-document URL (`pocketdj-studio.json` →
    /// `…-studio.cursors.json`) — derived exactly like the cue mirror, so the studio store's
    /// `launchURL()` fixture seam covers this file too.
    nonisolated static func url(forStudio studioURL: URL) -> URL {
        studioURL.deletingPathExtension().appendingPathExtension("cursors.json")
    }

    nonisolated static func defaultURL() -> URL { url(forStudio: StudioStore.defaultURL()) }

    // MARK: Read / write

    /// Where this take's cursor was last left (score-clock ms), or nil if it has never been
    /// replayed — which the score renders as "nothing played": cursor parked at the start, no
    /// highlight. A DIFFERENT take's mark is never consulted; that is the whole point.
    func position(_ takeId: String) -> Int? {
        guard let m = marks[takeId] else { return nil }
        return max(0, min(m.ms, Self.maxMs))
    }

    /// Remember (or, with `nil`, forget) a take's cursor. Writing through immediately: the marks
    /// are tiny, the write points are user-paced (a tap-seek, a replay ending, leaving the screen),
    /// and a debounce would just be a way to lose the last one to a force-quit. (The disk write
    /// itself is off the main thread — see `save()` — so a burst of taps never does file I/O
    /// inside the gesture handler.)
    ///
    /// A write that doesn't MOVE the cursor is dropped entirely — compared on `ms`, not on the
    /// whole mark, because `updatedAt` always differs and would re-encode + rewrite the file every
    /// time a score is merely opened and closed. The mark keeps its original `updatedAt`, so the
    /// capacity eviction below ranks takes by when their position last CHANGED.
    func setPosition(_ ms: Int?, for takeId: String,
                     at now: Double = Date().timeIntervalSince1970 * 1000) {
        guard !takeId.isEmpty else { return }
        guard let ms else { remove(takeId); return }
        let clamped = max(0, min(ms, Self.maxMs))
        guard marks[takeId]?.ms != clamped else { return }
        marks[takeId] = Mark(ms: clamped, updatedAt: now)
        marks = Self.pruned(marks, capacity: Self.capacity)
        save()
    }

    /// Drop a take's mark (it was deleted, or it has never really been played).
    func remove(_ takeId: String) {
        guard marks.removeValue(forKey: takeId) != nil else { return }
        save()
    }

    /// Drop marks for takes that no longer exist — called by `StudioStore.init` once the studio
    /// document has decoded, so a take removed by any path (not just `deleteTake`) can't leave a
    /// mark behind for an id that will never be asked for again.
    func prune(keeping takeIds: Set<String>) {
        let before = marks.count
        marks = marks.filter { takeIds.contains($0.key) }
        if marks.count != before { save() }
    }

    /// TEST/teardown seam: block until every queued write has landed on disk. Production never
    /// needs it — the queue is serial and each write is atomic, so the file is always either the
    /// previous or the next state — but a test that re-reads the file right after writing does.
    func flush() { Self.io.sync {} }

    /// Keep the `capacity` most recently written marks. Pure + static so the eviction order is
    /// testable without touching the disk.
    nonisolated static func pruned(_ marks: [String: Mark], capacity: Int) -> [String: Mark] {
        guard capacity > 0 else { return [:] }
        guard marks.count > capacity else { return marks }
        // Newest first; ties break on the id so the eviction is deterministic.
        let keep = marks.sorted {
            $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key
                                                     : $0.value.updatedAt > $1.value.updatedAt
        }.prefix(capacity)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// SERIAL, off the main thread. Every write point here is a UI gesture (a tap-to-seek, leaving
    /// a score), and an atomic write is file I/O — temp file, rename — which has no business
    /// blocking a gesture handler. One serial queue keeps the writes in order, and each is atomic,
    /// so a reader only ever sees a whole document. Only the encoded BYTES cross the boundary,
    /// never `self`.
    private static let io = DispatchQueue(label: "com.pocketdj.score-cursors", qos: .utility)

    private func save() {
        guard let data = try? JSONEncoder().encode(Document(marks: marks)) else { return }
        let url = fileURL
        Self.io.async { try? data.write(to: url, options: .atomic) }
    }
}

let scoreCursorSchemaVersion = 1
