import Foundation
import Observation

/// PROVISIONAL catalog entries for Discover adds — the EVENTUAL-CONSISTENCY half of
/// "＋ Add" (Levi 2026-07-18): the tap must make the song a first-class catalog citizen
/// IMMEDIATELY (browsable, addable to collections, playable/burnable/stemmable off the
/// server's queued `amrec_` capture), while the nightly Apple Music indexer stays the
/// source of truth — once it lands the track as a real library entry, the INDEXED
/// version supersedes the provisional one and collection references are remapped onto
/// it (`AppModel.applySupersede` → `CollectionsStore.remapSongIds`).
///
/// Persists to Application Support `pocketdj-discover-adds.json` (the PlayStatsStore
/// durable-JSON pattern: atomic save, decode-on-init, PDJ_USE_FIXTURE seam) and syncs
/// across the user's devices through CloudSyncService — an add on the iPhone shows up
/// in the iPad's catalog on its next launch pull.
@MainActor
@Observable
final class DiscoverAddsStore {

    /// The synthetic source's name (song source tags + the Browse source filter).
    nonisolated static let sourceName = "Discover"

    struct Entry: Codable, Equatable, Identifiable {
        /// The ad-hoc rip id (`amrec_<storeId>`) — already the id the rips manifest,
        /// stream path, and burn/stem flows key on.
        var songId: String
        /// Apple Music store id — the SUPERSEDE join key against indexed songs.
        var appleMusicId: String
        var title: String
        var artist: String
        var album: String?
        var artworkUrl: String?
        var durationMs: Int?
        var addedAtMs: Double
        var id: String { songId }
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var entries: [Entry] = []
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }
    /// Fired for each NEW entry (local add or cloud pull) — the app wires this to
    /// `AppModel.injectDiscoverAdd` so the live catalog updates without a full reload.
    @ObservationIgnored var onAdded: ((IndexSong) -> Void)?

    init(fileURL: URL = DiscoverAddsStore.defaultURL()) {
        self.fileURL = fileURL
        entries = Self.decode(fileURL)
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-discover-adds.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ProfileStore.launchURL idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-discover-adds.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decode(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return doc.entries
    }

    /// Record an add (idempotent per songId) and hand the injected catalog row to the app.
    func add(songId: String, appleMusicId: String, title: String, artist: String,
             album: String? = nil, artworkUrl: String? = nil, durationMs: Int? = nil) {
        guard !entries.contains(where: { $0.songId == songId }) else { return }
        let entry = Entry(songId: songId, appleMusicId: appleMusicId, title: title, artist: artist,
                          album: album, artworkUrl: artworkUrl, durationMs: durationMs,
                          addedAtMs: Date().timeIntervalSince1970 * 1000)
        entries.append(entry)
        save()
        onAdded?(Self.indexSong(entry))
    }

    /// Drop superseded entries (their indexed replacements own the ids now).
    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        entries.removeAll { gone.contains($0.songId) }
        save()
    }

    /// Empty the provisional catalog: reset in-memory state and remove the persisted
    /// file (swallowing file-not-found like the rest of the store).
    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Re-decode after CloudSyncService pulled a newer copy, surfacing any NEW entries
    /// through `onAdded` so the live catalog follows the pull.
    func reloadFromDisk() {
        let before = Set(entries.map(\.songId))
        entries = Self.decode(fileURL)
        for e in entries where !before.contains(e.songId) {
            onAdded?(Self.indexSong(e))
        }
    }

    // MARK: - Catalog synthesis (pure)

    /// Entry → catalog row. `IndexSong` is Decodable-only, so this builds via JSON
    /// (the `IndexSong.minimal` idiom) with the fields Discover knows.
    nonisolated static func indexSong(_ e: Entry) -> IndexSong {
        var obj: [String: Any] = ["id": e.songId, "name": e.title, "artist": e.artist,
                                  "appleMusicId": e.appleMusicId]
        if let ms = e.durationMs { obj["length"] = ms }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    /// The synthetic SOURCE the multi-source catalog merge consumes. No albums —
    /// provisional adds are singles until the indexer lands the real album entry.
    nonisolated static func syntheticIndex(_ entries: [Entry]) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: "discover-adds", generatedAt: nil,
                                     sourceName: sourceName, counts: nil),
                  albums: [], songs: entries.map(indexSong), playlists: nil)
    }

    /// The SUPERSEDE split (pure): entries whose Apple Music id is claimed by an
    /// INDEXED song yield to it — returns the survivors plus the (provisional →
    /// indexed) id pairs the collections remap applies.
    nonisolated static func split(_ entries: [Entry], indexedByAppleMusicId: [String: String])
        -> (keep: [Entry], superseded: [(from: String, to: String)]) {
        var keep: [Entry] = []
        var superseded: [(from: String, to: String)] = []
        for e in entries {
            if let indexedId = indexedByAppleMusicId[e.appleMusicId], indexedId != e.songId {
                superseded.append((from: e.songId, to: indexedId))
            } else {
                keep.append(e)
            }
        }
        return (keep, superseded)
    }

    private func save() {
        let doc = Document(entries: entries)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
