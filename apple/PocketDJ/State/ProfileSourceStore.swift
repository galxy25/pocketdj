import Foundation
import Observation

/// The per-profile "PocketDJ" DATA SOURCE — the user's own on-device custom audio (Sampler
/// samples + Demuxer results) as FIRST-CLASS catalog citizens: browsable, addable to
/// collections, cue-able, mixable, and playable in Now Playing exactly like a catalog song.
/// The cross-DEVICE half is metadata-only: this document syncs through CloudSyncService
/// (its OWN doc key "profile-source"), while the actual AUDIO stays device-local (a durable
/// Studio-style store — Stage 3) and the Browser hides an item whose asset isn't on THIS
/// device (Stage 6). See [[profile-custom-audio-source-program]].
///
/// SOURCE NAME (the one real deviation from ImportedSongsStore, whose name is a fixed
/// "Imported"): the source DISPLAY name is the user's PROFILE name — `AppModel`'s catalog
/// tagging keys on `Manifest.sourceName`, so the profile name IS both the Browse source-filter
/// label and the per-song source tag. It is mirrored in from `ProfileStore.onNameApplied`
/// (default "Pocket DJ" when the profile is unnamed); a rename re-tags on the next catalog
/// rebuild. Each item's ARTIST is likewise the profile name — DERIVED at synthesis time, never
/// stored, so a rename updates every row for free.
///
/// AUTO-FILING: every entry carries a `kind` (sample | demux) that routes it into one of two
/// DEFAULT albums — "Pocket DJ Samples" / "Pocket DJ Demuxes" — SYNTHESIZED here (stable ids,
/// artist = profile name), never persisted, so they always exist as filing destinations even
/// when empty and always carry the current profile name.
///
/// Persists to Application Support `pocketdj-profile-source.json` (the ImportedSongsStore /
/// PlayStatsStore durable-JSON pattern). New OPTIONAL fields only, per the schema doctrine.
@MainActor
@Observable
final class ProfileSourceStore {

    /// Fallback source/artist name when the profile is unnamed.
    nonisolated static let defaultName = "Pocket DJ"
    /// Stable ids + names of the two default albums (synthesized, never persisted).
    nonisolated static let samplesAlbumId = "pdjalb_samples"
    nonisolated static let demuxesAlbumId = "pdjalb_demuxes"
    nonisolated static let samplesAlbumName = "Pocket DJ Samples"
    nonisolated static let demuxesAlbumName = "Pocket DJ Demuxes"

    /// Which default album an entry files into.
    enum Kind: String, Codable, Sendable { case sample, demux
        var albumId: String { self == .sample ? samplesAlbumId : demuxesAlbumId }
        var albumName: String { self == .sample ? samplesAlbumName : demuxesAlbumName }
    }

    /// One custom-audio item. METADATA ONLY (this half syncs); the audio + optional stems live
    /// device-local under `fileName` in the durable Studio-style store (Stage 3). Artist + album
    /// are DERIVED (profile name / `kind`) — never stored, so a rename/refile is free.
    struct SongEntry: Codable, Equatable, Identifiable, Sendable {
        var songId: String            // "pdj_…" — fresh per item, never a source song's id
        var title: String
        var kind: Kind
        var fileName: String          // device-local durable audio identity (Stage 3 resolves)
        var durationMs: Int?
        var bpm: Double?
        var key: String?
        var camelot: String?
        var addedAtMs: Double
        var id: String { songId }
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var songs: [SongEntry] = []
    }

    private(set) var songs: [SongEntry] = []
    /// The current profile name (source + artist display). Mirrored from ProfileStore; empty ⇒
    /// `defaultName`. `sourceName` is what the catalog tags/filters on.
    var profileName: String = ProfileSourceStore.defaultName {
        didSet { if profileName != oldValue { onNameChanged?() } }
    }
    var sourceName: String {
        let t = profileName.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? Self.defaultName : t
    }

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }
    /// Fired with each batch of NEW entries (local save or cloud pull) — the app wires this to
    /// `AppModel.injectProfileItem` so the live catalog updates without a reload. Carries the
    /// (rebuilt) default albums too, since an item add grows an album's trackList.
    @ObservationIgnored var onAdded: ((_ songs: [IndexSong], _ albums: [IndexAlbum]) -> Void)?
    /// Fired when the profile name changes — the app rebuilds the catalog so the source tag +
    /// item artists re-render under the new name (wired in PocketDJApp).
    @ObservationIgnored var onNameChanged: (() -> Void)?

    init(fileURL: URL = ProfileSourceStore.defaultURL()) {
        self.fileURL = fileURL
        songs = Self.decode(fileURL).songs
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-profile-source.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ImportedSongsStore idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-profile-source.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decode(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }

    // MARK: - Mutations

    /// Record custom-audio items (idempotent per id) and hand the NEW rows to the live catalog
    /// in one shot, along with the (rebuilt) default albums so their trackLists grow.
    func add(_ newSongs: [SongEntry]) {
        let known = Set(songs.map(\.songId))
        let fresh = newSongs.filter { !known.contains($0.songId) }
        guard !fresh.isEmpty else { return }
        songs.append(contentsOf: fresh)
        save()
        onAdded?(fresh.map { Self.indexSong($0, profileName: sourceName) }, defaultAlbums())
    }

    /// Drop items by id (e.g. the durable asset was deleted). Idempotent.
    func remove(songIds ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        let before = songs.count
        songs.removeAll { gone.contains($0.songId) }
        if songs.count != before { save() }
    }

    /// Wipe every entry and delete the on-disk document (the ImportedSongsStore.clear contract).
    func clear() {
        songs = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Re-decode after CloudSyncService pulled a newer copy, surfacing NEW entries through
    /// `onAdded` so the live catalog follows the pull.
    func reloadFromDisk() {
        let before = Set(songs.map(\.songId))
        songs = Self.decode(fileURL).songs
        let fresh = songs.filter { !before.contains($0.songId) }
        if !fresh.isEmpty {
            onAdded?(fresh.map { Self.indexSong($0, profileName: sourceName) }, defaultAlbums())
        }
    }

    // MARK: - Catalog synthesis

    /// Entry → catalog row (`IndexSong` is Decodable-only — the `IndexSong.minimal` idiom).
    /// Artist + albumId are DERIVED here (profile name / `kind`), never stored.
    nonisolated static func indexSong(_ e: SongEntry, profileName: String) -> IndexSong {
        var obj: [String: Any] = ["id": e.songId, "name": e.title, "artist": profileName,
                                  "albumId": e.kind.albumId]
        if let v = e.durationMs { obj["length"] = v }
        if let v = e.bpm { obj["bpm"] = v }
        if let v = e.key { obj["key"] = v }
        if let v = e.camelot { obj["camelot"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    /// A default album (samples/demuxes) → catalog album. Artist = profile name; trackList = the
    /// ids of the entries of that kind (in add order).
    nonisolated static func indexAlbum(kind: Kind, trackIds: [String], profileName: String) -> IndexAlbum {
        let obj: [String: Any] = ["id": kind.albumId, "name": kind.albumName,
                                  "artist": profileName, "trackList": trackIds]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }

    /// The two default albums built from `songs` + `profileName` (samples/demuxes trackLists in
    /// add order). Static so the off-main catalog build can call it with arrays read on @MainActor.
    nonisolated static func defaultAlbums(songs: [SongEntry], profileName: String) -> [IndexAlbum] {
        let sampleIds = songs.filter { $0.kind == .sample }.map(\.songId)
        let demuxIds = songs.filter { $0.kind == .demux }.map(\.songId)
        return [indexAlbum(kind: .sample, trackIds: sampleIds, profileName: profileName),
                indexAlbum(kind: .demux, trackIds: demuxIds, profileName: profileName)]
    }

    /// The synthetic SOURCE the multi-source catalog merge consumes — appended AFTER every real
    /// source (like Imported), tagged with the profile name (`Manifest.sourceName`). Always
    /// carries BOTH default albums so they exist as filing destinations even when empty. Static
    /// (the `ImportedSongsStore.syntheticIndex` idiom) so `AppModel.withProvisionalSources` can
    /// build it inside the off-main `Task.detached` from the (songs, profileName) read on main.
    nonisolated static func syntheticIndex(songs: [SongEntry], profileName: String) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: "profile-source", generatedAt: nil,
                                     sourceName: profileName, counts: nil),
                  albums: defaultAlbums(songs: songs, profileName: profileName),
                  songs: songs.map { indexSong($0, profileName: profileName) },
                  playlists: nil)
    }

    /// Instance conveniences for the LIVE paths (current `songs` + `sourceName`).
    func defaultAlbums() -> [IndexAlbum] { Self.defaultAlbums(songs: songs, profileName: sourceName) }
    func syntheticIndex() -> IndexJSON { Self.syntheticIndex(songs: songs, profileName: sourceName) }

    private func save() {
        let doc = Document(songs: songs)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
