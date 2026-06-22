import Foundation
import Observation

/// App-side BURN (Feature 2): a SERIAL, one-by-one download queue that persists each
/// song's durable mp3 PLUS a human-readable `.txt` metadata sidecar into app-managed
/// storage, recording each item in a versioned local index — the machine-readable
/// source of truth a FUTURE offline player / live-mixer will enumerate.
///
/// Offline playback and live mixing are explicitly NOT implemented here; this only
/// establishes the download queue + local persistence + sidecar layer they consume.
///
/// Design notes (resolving the reviewer issues baked into the spec):
///   • Files are keyed by songId (digital → `<songId>.mp3`) / albumId (analog →
///     `<albumId>.mp3`, ONE shared file per album), so no Artist-Title collisions and
///     no N duplicate whole-album downloads.
///   • Burn NEVER blocks on the 30-min rip-on-demand path — it downloads ONLY songs
///     already in the manifest (`RipsStore.downloadDataIfCached`); not-yet-ripped songs
///     are reported and optionally enqueued via `RipsStore.ripCollection` for a later pass.
///   • The burn INDEX (pocketdj-burns.json) carries the analyzed bpm/key/camelot/
///     durationMs/startMs actually used (preferring the ManifestEntry over the catalog),
///     so a consumer reads it directly instead of parsing the prose `.txt`.
///   • Mirrors CollectionsStore/EditsStore durable-JSON persistence (atomic save,
///     decode-on-init, PDJ_USE_FIXTURE test seam).
@MainActor
@Observable
final class BurnStore {
    /// Per-item lifecycle state.
    enum State: String, Codable { case queued, downloading, ready, error }

    /// One burned (or attempted) track. The MACHINE-READABLE record a future offline
    /// player / live-mixer reads — it carries the analyzed values + the analog seek
    /// offset, so consumers never parse the prose sidecar.
    struct BurnItem: Codable, Identifiable, Equatable {
        var songId: String
        var title: String
        var artist: String
        /// `<songId>.mp3` (digital) or `<albumId>.mp3` (analog, shared across the album).
        var audioFileName: String
        /// `<songId>.txt`.
        var sidecarFileName: String
        /// "analog" | "digital".
        var source: String
        var bpm: Double?
        var musicalKey: String?
        var camelot: String?
        var durationMs: Int?
        /// Analog: the seek offset within the shared album mp3 (nil for digital).
        var startMs: Int?
        var bytes: Int
        /// From the ManifestEntry (when present) — staleness check vs. `downloadedAt`.
        var rippedAt: Double?
        var downloadedAt: Double
        var state: State
        var error: String?

        var id: String { songId }
    }

    /// The persisted, versioned index document.
    struct Document: Codable {
        var schemaVersion: Int = burnSchemaVersion
        var items: [BurnItem] = []
    }

    /// Bulk progress for the collection UI ({done,total,label}); nil when idle.
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var label: String
    }

    /// The outcome of a `burn(...)` run, for the partial-success summary.
    struct BurnResult: Equatable {
        var burned = 0          // newly downloaded + persisted (or already ready)
        var notRipped = 0       // skipped — not in the manifest yet
        var failed = 0          // per-item download/write errors
        var total = 0
        var outOfSpace = false  // disk filled — remaining items aborted
    }

    // MARK: Observed state

    private(set) var items: [String: BurnItem] = [:]
    /// Drives the collection screen's progress UI; nil when no burn is running.
    private(set) var progress: Progress?

    private let fileURL: URL
    /// Catalog lookup wired at launch (mirrors CollectionsStore.app) so the sidecar can
    /// resolve the IndexSong / IndexAlbum for a songId.
    var lookup: ((String) -> (song: IndexSong?, album: IndexAlbum?))?

    private let rips: RipsStore

    init(rips: RipsStore, fileURL: URL = BurnStore.defaultURL()) {
        self.rips = rips
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            items = Dictionary(doc.items.map { ($0.songId, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-burns.json")
    }

    /// UI tests get an isolated, fresh burn index (mirrors CollectionsStore.launchURL).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-burns.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var now: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Future-consumer seam (designed-for, NOT used here)

    /// The persisted audio file URL for a ready item — ONLY when the file still exists
    /// on disk (nil if iOS purged it). A future offline player feeds this (+ `startMs`
    /// for analog) into `PlayerEngine.load`; this store does NOT play anything.
    func localURL(forSong songId: String) -> URL? {
        guard let item = items[songId], item.state == .ready,
              let dir = try? RipsStore.burnsDirectory() else { return nil }
        let url = dir.appendingPathComponent(item.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Total bytes burned to disk (eviction-ready: a future cap policy reads this).
    var totalBytes: Int { items.values.filter { $0.state == .ready }.reduce(0) { $0 + $1.bytes } }

    /// Remove a burned item + its files (eviction-ready; not wired to any UI yet).
    func remove(_ songId: String) {
        if let item = items[songId], let dir = try? RipsStore.burnsDirectory() {
            // The analog album mp3 is shared — only delete it if no other ready item uses it.
            let shared = items.values.contains { $0.songId != songId && $0.audioFileName == item.audioFileName }
            if !shared { try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.audioFileName)) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.sidecarFileName))
        }
        items[songId] = nil
        save()
    }

    /// Prune index entries whose audio file vanished (iOS purges Application Support
    /// under storage pressure without touching the index). Call at launch.
    func reconcileOnLaunch() {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        var changed = false
        for (songId, item) in items where item.state == .ready {
            let url = dir.appendingPathComponent(item.audioFileName)
            if !FileManager.default.fileExists(atPath: url.path) { items[songId] = nil; changed = true }
        }
        if changed { save() }
    }

    // MARK: The serial download queue

    /// BURN a collection's songs ONE BY ONE: download each already-ripped song's durable
    /// mp3 + write its `.txt` sidecar, persisting both into app-managed storage and
    /// recording the result in the index. NEVER blocks on a live rip (skips not-yet-ripped
    /// songs). Per-item try/catch → partial success; disk-full aborts the remainder.
    /// Empty input is a no-op.
    @discardableResult
    func burn(_ songs: [(id: String, title: String, artist: String)]) async -> BurnResult {
        let unique = orderedUnique(songs)
        var result = BurnResult(total: unique.count)
        guard !unique.isEmpty else { return result }

        let dir: URL
        do { dir = try RipsStore.burnsDirectory() }
        catch { result.failed = unique.count; return result }

        var done = 0
        for song in unique {
            progress = Progress(done: done, total: unique.count, label: "\(song.artist) — \(song.title)")
            defer { done += 1 }

            // (1) Idempotency: already burned, file present, right size, not stale → skip.
            if let existing = items[song.id], existing.state == .ready,
               isFresh(existing, dir: dir, rippedAt: rips.manifest[song.id]?.rippedAt) {
                result.burned += 1
                continue
            }

            // (2) Not-ripped short-circuit — Burn never blocks on the 30-min ensureURL.
            guard rips.cachedURL(song.id) != nil else {
                let why = rips.hasServer ? "not ripped — Rip first" : "not ripped (no rip server)"
                items[song.id] = errorItem(song, message: why)
                result.notRipped += 1
                continue
            }

            items[song.id]?.state = .downloading

            do {
                guard let (data, entry) = try await rips.downloadDataIfCached(song) else {
                    // Manifest changed out from under us mid-run — treat as not ripped.
                    items[song.id] = errorItem(song, message: "not ripped — Rip first")
                    result.notRipped += 1
                    continue
                }

                let (audioName, sidecarName) = fileNames(for: song.id, entry: entry)
                let audioURL = dir.appendingPathComponent(audioName)

                // Analog: the whole-album mp3 is stored ONCE and shared across the album's
                // songs — don't re-download/re-write it if a sibling already wrote it.
                let analogShared = entry.source == "analog" && FileManager.default.fileExists(atPath: audioURL.path)
                if !analogShared {
                    try data.write(to: audioURL, options: .atomic)
                }

                let (s, a) = lookup?(song.id) ?? (nil, nil)
                let sidecar = Self.buildSidecar(songId: song.id, fallback: song, song: s, album: a, entry: entry)
                try Data(sidecar.utf8).write(to: dir.appendingPathComponent(sidecarName), options: .atomic)

                items[song.id] = BurnItem(
                    songId: song.id, title: song.title, artist: song.artist,
                    audioFileName: audioName, sidecarFileName: sidecarName,
                    source: entry.source ?? "digital",
                    bpm: entry.bpm, musicalKey: entry.musicalKey, camelot: entry.camelot,
                    durationMs: entry.durationMs,
                    startMs: entry.source == "analog" ? entry.startMs : nil,
                    bytes: data.count, rippedAt: entry.rippedAt, downloadedAt: now,
                    state: .ready, error: nil)
                result.burned += 1
            } catch let err as NSError where err.code == NSFileWriteOutOfSpaceError {
                // Disk full — every remaining item would fail too. Abort the rest.
                items[song.id] = errorItem(song, message: "out of space")
                result.outOfSpace = true
                result.failed += 1
                break
            } catch {
                items[song.id] = errorItem(song, message: error.localizedDescription)
                result.failed += 1
            }
        }

        save()
        progress = nil
        return result
    }

    // MARK: Helpers

    /// A ready burn is fresh when its audio file exists, is the recorded size (catches a
    /// zero-byte / partial prior write), AND the source rip hasn't been re-ripped since we
    /// downloaded it. `rippedAt` is the manifest entry's epoch-ms rip completion time:
    /// a burn is STALE (=> re-download) when that is newer than the burn's `downloadedAt`.
    /// Backward-compat: when `rippedAt` is nil (older manifest entries / older burns) the
    /// staleness-by-time signal is skipped and only the size check applies.
    private func isFresh(_ item: BurnItem, dir: URL, rippedAt: Double?) -> Bool {
        let url = dir.appendingPathComponent(item.audioFileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size == item.bytes else { return false }
        // Re-ripped after we last burned it → stale (skipped when rippedAt is unknown).
        if let rippedAt, rippedAt > item.downloadedAt { return false }
        return true
    }

    private func fileNames(for songId: String, entry: RipsStore.ManifestEntry) -> (audio: String, sidecar: String) {
        // Reuse the manifest key's basename so analog songs share `<albumId>.mp3` and
        // digital songs get `<songId>.mp3` — exactly the server's S3 key scheme.
        let audio = (entry.key as NSString).lastPathComponent
        return (audio.isEmpty ? "\(songId).mp3" : audio, "\(songId).txt")
    }

    private func errorItem(_ song: (id: String, title: String, artist: String), message: String) -> BurnItem {
        BurnItem(songId: song.id, title: song.title, artist: song.artist,
                 audioFileName: "", sidecarFileName: "", source: "digital",
                 bpm: nil, musicalKey: nil, camelot: nil, durationMs: nil, startMs: nil,
                 bytes: 0, rippedAt: nil, downloadedAt: now, state: .error, error: message)
    }

    /// Stable de-dupe preserving first-seen order (don't double-download a repeated song).
    private func orderedUnique(_ songs: [(id: String, title: String, artist: String)]) -> [(id: String, title: String, artist: String)] {
        var seen = Set<String>(); var out: [(id: String, title: String, artist: String)] = []
        for s in songs where !s.id.isEmpty && seen.insert(s.id).inserted { out.append(s) }
        return out
    }

    private func save() {
        let doc = Document(items: items.values.sorted { $0.downloadedAt < $1.downloadedAt })
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Sidecar (human-readable companion; the INDEX is the machine contract)

    /// The `.txt` sidecar — mirrors burn-setlist.mjs `buildSidecar` HEADER ORDER
    /// (BPM · Key+Camelot · Sentiment · Album) as a HUMAN companion. Prefers the
    /// ManifestEntry analyzed bpm/musicalKey/camelot over catalog values (as
    /// SongRowView.effBpm/effKey/effCamelot does). The Raw JSON embeds the entry so the
    /// prose header and JSON agree. Omits the burn-setlist "Segment" block (no pointer
    /// offsets on IndexSong — the analog seek offset lives in the burn INDEX `startMs`).
    nonisolated static func buildSidecar(songId: String,
                                         fallback: (id: String, title: String, artist: String),
                                         song: IndexSong?,
                                         album: IndexAlbum?,
                                         entry: RipsStore.ManifestEntry?) -> String {
        let artist = song?.artist ?? fallback.artist
        let title = song?.name ?? fallback.title
        let bpm = entry?.bpm ?? song?.bpm
        let key = entry?.musicalKey ?? song?.key
        let camelot = entry?.camelot ?? song?.camelot
        let sentiment = (song?.sentimentKeywords ?? []).joined(separator: ", ")
        let albumName = album?.name

        func dash(_ s: String?) -> String { (s?.isEmpty == false) ? s! : "—" }
        func num(_ n: Double?) -> String { n.map { String($0) } ?? "—" }

        var L: [String] = []
        L.append("\(artist) — \(title)")
        L.append(String(repeating: "=", count: 60))
        L.append("")
        L.append("BPM:        \(num(bpm))")
        L.append("Key:        \(dash(key))  (Camelot \(dash(camelot)))")
        L.append("Sentiment:  \(sentiment.isEmpty ? "—" : sentiment)")
        L.append("Album:      \(dash(albumName))")
        L.append("")
        L.append("-- Song metadata --")
        if let song {
            for (k, v) in songFields(song) { L.append("  \(k): \(v)") }
        } else {
            L.append("  (song not found in index)")
        }
        L.append("")
        L.append("-- Album metadata --")
        if let album {
            for (k, v) in albumFields(album) { L.append("  \(k): \(v)") }
        } else {
            L.append("  (album not found in index)")
        }
        L.append("")
        L.append("-- Raw JSON --")
        L.append(rawJSON(song: song, album: album, entry: entry))
        L.append("")
        return L.joined(separator: "\n")
    }

    private nonisolated static func songFields(_ s: IndexSong) -> [(String, String)] {
        func d(_ v: String?) -> String { (v?.isEmpty == false) ? v! : "—" }
        return [
            ("id", s.id),
            ("artist", d(s.artist)),
            ("name", d(s.name)),
            ("albumId", d(s.albumId)),
            ("trackNumber", s.trackNumber.map(String.init) ?? "—"),
            ("year", s.year.map(String.init) ?? "—"),
            ("sentimentKeywords", (s.sentimentKeywords ?? []).joined(separator: ", ").ifEmpty("—")),
            ("explicit", s.explicit.map { String($0) } ?? "—"),
            ("bpm", s.bpm.map { String($0) } ?? "—"),
            ("key", d(s.key)),
            ("camelot", d(s.camelot)),
            ("length", s.length.map(String.init) ?? "—"),
            ("fileType", d(s.fileType)),
            ("appleMusicId", d(s.appleMusicId)),
        ]
    }

    private nonisolated static func albumFields(_ a: IndexAlbum) -> [(String, String)] {
        func d(_ v: String?) -> String { (v?.isEmpty == false) ? v! : "—" }
        return [
            ("id", a.id),
            ("artist", d(a.artist)),
            ("name", d(a.name)),
            ("genre", d(a.genre)),
            ("year", a.year.map(String.init) ?? "—"),
            ("country", d(a.country)),
            ("fileType", d(a.fileType)),
            ("trackList", "[\(a.trackList.count) entries]"),
            ("audioTracks", "[\((a.audioTracks ?? []).count) entries]"),
        ]
    }

    /// The Raw JSON block — {song, album, manifestEntry} so the prose header (which
    /// prefers analyzed values) and the JSON agree. Built field-by-field because the
    /// catalog models are Decodable-only (no `Encodable` to round-trip through).
    private nonisolated static func rawJSON(song: IndexSong?, album: IndexAlbum?, entry: RipsStore.ManifestEntry?) -> String {
        var obj: [String: Any] = [:]
        if let song { obj["song"] = songJSON(song) }
        if let album { obj["album"] = albumJSON(album) }
        if let entry { obj["manifestEntry"] = entryJSON(entry) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private nonisolated static func songJSON(_ s: IndexSong) -> [String: Any] {
        var o: [String: Any] = ["id": s.id, "artist": s.artist, "name": s.name]
        o["albumId"] = s.albumId; o["trackNumber"] = s.trackNumber; o["year"] = s.year
        o["sentimentKeywords"] = s.sentimentKeywords; o["explicit"] = s.explicit
        o["bpm"] = s.bpm; o["key"] = s.key; o["camelot"] = s.camelot; o["length"] = s.length
        o["fileType"] = s.fileType; o["lyricsStatus"] = s.lyricsStatus; o["appleMusicId"] = s.appleMusicId
        return o.compactMapValues { $0 }
    }

    private nonisolated static func albumJSON(_ a: IndexAlbum) -> [String: Any] {
        var o: [String: Any] = ["id": a.id, "artist": a.artist, "name": a.name,
                                "trackList": a.trackList, "trackCount": a.trackList.count]
        o["genre"] = a.genre; o["year"] = a.year; o["country"] = a.country; o["fileType"] = a.fileType
        o["audioDurationSec"] = a.audioDurationSec; o["audioTrackCount"] = (a.audioTracks ?? []).count
        return o.compactMapValues { $0 }
    }

    private nonisolated static func entryJSON(_ e: RipsStore.ManifestEntry) -> [String: Any] {
        var o: [String: Any] = ["key": e.key]
        o["ext"] = e.ext; o["source"] = e.source; o["startMs"] = e.startMs; o["durationMs"] = e.durationMs
        o["bpm"] = e.bpm; o["musicalKey"] = e.musicalKey; o["camelot"] = e.camelot
        o["waveform"] = e.waveform; o["analyzed"] = e.analyzed
        return o.compactMapValues { $0 }
    }
}

let burnSchemaVersion = 1

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
