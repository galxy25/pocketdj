import Foundation

/// Builds the PUBLIC-mode "Apple Music" source ON DEVICE: enumerates the signed-in user's Apple
/// Music LIBRARY via MusicKit (songs + their playlists) and maps it into
/// `AppleMusicLibraryStore` entries — the device-token twin of the private catalog's Library.xml
/// indexer, requiring no server at all.
///
/// INCREMENTAL BY DESIGN: the library is sorted by `libraryAddedDate` descending and the walk
/// stops at the store's high-water mark, so the foreground refresh is a handful of rows, not the
/// whole library. A first run (mark nil) walks everything — seconds for a typical library;
/// minutes for a 90k-song one, which is why runs are explicit (login / Get verb / foreground)
/// and never block UI.
enum AppleMusicLibraryIndexer {

    struct Result {
        var songs: [AppleMusicLibraryStore.SongEntry]
        var albums: [AppleMusicLibraryStore.AlbumEntry]
        var playlists: [AppleMusicLibraryStore.PlaylistEntry]
        var maxAddedMs: Double?
    }

    /// Deterministic album id from the grouping key — stable across runs AND devices (the
    /// cloud-synced doc must not re-mint ids per device). FNV-1a, hex.
    nonisolated static func albumId(title: String, artist: String) -> String {
        let key = "\(title.lowercased())|\(artist.lowercased())"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "amlib_alb_" + String(format: "%016llx", hash)
    }

    /// Group songs into album entries (pure, testable).
    nonisolated static func groupAlbums(_ songs: [AppleMusicLibraryStore.SongEntry])
        -> [AppleMusicLibraryStore.AlbumEntry] {
        var byId: [String: AppleMusicLibraryStore.AlbumEntry] = [:]
        var order: [String] = []
        for song in songs {
            guard let albumTitle = song.album, !albumTitle.isEmpty, let albumId = song.albumId else { continue }
            if var entry = byId[albumId] {
                entry.trackIds.append(song.songId)
                if entry.artworkUrl == nil { entry.artworkUrl = song.artworkUrl }
                if entry.year == nil { entry.year = song.year }
                byId[albumId] = entry
            } else {
                byId[albumId] = .init(albumId: albumId, title: albumTitle, artist: song.artist,
                                      artworkUrl: song.artworkUrl, year: song.year,
                                      genre: song.genre, trackIds: [song.songId])
                order.append(albumId)
            }
        }
        // In-album track order: by trackNumber where known (the library enumeration is
        // added-order, which would scramble albums — the Library.xml indexer's lesson).
        var result: [AppleMusicLibraryStore.AlbumEntry] = []
        var songById: [String: AppleMusicLibraryStore.SongEntry] = [:]
        for s in songs { songById[s.songId] = s }
        for id in order {
            var entry = byId[id]!
            entry.trackIds.sort { (songById[$0]?.trackNumber ?? Int.max) < (songById[$1]?.trackNumber ?? Int.max) }
            result.append(entry)
        }
        return result
    }
}

#if canImport(MusicKit)
import MusicKit

extension AppleMusicLibraryIndexer {

    /// Can this build + device index the library right now? (Feature flag + user authorization —
    /// the SAME gates streaming playback uses; sim can't authorize, so this is device-real.)
    static var isAvailable: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    /// Walk the user's library. `since` = the store's high-water mark (epoch ms): only songs
    /// added AFTER it are returned (playlists are always re-read in full — they're small and
    /// can reorder). nil = full walk.
    static func index(since: Double?) async throws -> Result {
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.sort(by: \.libraryAddedDate, ascending: false)
        let response = try await request.response()

        var songs: [AppleMusicLibraryStore.SongEntry] = []
        var maxAddedMs: Double? = since
        var batch: MusicItemCollection<MusicKit.Song>? = response.items
        outer: while let current = batch, !current.isEmpty {
            for song in current {
                let addedMs = (song.libraryAddedDate ?? .distantPast).timeIntervalSince1970 * 1000
                // Sorted descending ⇒ the first row at/below the mark ends the incremental walk.
                if let since, addedMs <= since { break outer }
                songs.append(entry(for: song, addedMs: addedMs))
                if addedMs > (maxAddedMs ?? 0) { maxAddedMs = addedMs }
            }
            batch = current.hasNextBatch ? try await current.nextBatch() : nil
        }

        let playlists = try await libraryPlaylists()
        return Result(songs: songs, albums: groupAlbums(songs), playlists: playlists,
                      maxAddedMs: maxAddedMs)
    }

    private static func entry(for song: MusicKit.Song, addedMs: Double) -> AppleMusicLibraryStore.SongEntry {
        let libraryId = song.id.rawValue
        let albumTitle = song.albumTitle
        var year: Int?
        if let release = song.releaseDate {
            year = Calendar(identifier: .gregorian).component(.year, from: release)
        }
        return .init(
            songId: AppleMusicLibraryStore.songIdPrefix + libraryId,
            libraryId: libraryId,
            appleMusicId: catalogId(of: song),
            title: song.title,
            artist: song.artistName,
            album: albumTitle,
            albumId: albumTitle.flatMap { $0.isEmpty ? nil : albumId(title: $0, artist: song.artistName) },
            artworkUrl: song.artwork?.url(width: 600, height: 600)?.absoluteString,
            durationMs: song.duration.map { Int($0 * 1000) },
            trackNumber: song.trackNumber,
            year: year,
            genre: song.genreNames.first,
            addedAtMs: addedMs)
    }

    /// The catalog store id for a LIBRARY song — `id.rawValue` is the library id (`i.…`), NOT a
    /// catalog id; the catalog id only rides the opaque `playParameters` blob (the
    /// `PlaylistWriteBack.catalogIds(of:)` technique).
    private static func catalogId(of song: MusicKit.Song) -> String? {
        guard let params = song.playParameters,
              let data = try? JSONEncoder().encode(params),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["catalogId", "catalogID"] {
            if let value = obj[key] { return "\(value)" }
        }
        // "id" is the catalog id ONLY when the params aren't library-scoped.
        if (obj["isLibrary"] as? Bool) != true, let value = obj["id"] { return "\(value)" }
        return nil
    }

    /// The user's own library playlists, mirrored (Apple's smart/system lists are excluded by
    /// MusicKit's library enumeration itself where possible; empty mirrors are kept — an empty
    /// playlist is still the user's playlist).
    private static func libraryPlaylists() async throws -> [AppleMusicLibraryStore.PlaylistEntry] {
        let request = MusicLibraryRequest<MusicKit.Playlist>()
        let response = try await request.response()
        var result: [AppleMusicLibraryStore.PlaylistEntry] = []
        var batch: MusicItemCollection<MusicKit.Playlist>? = response.items
        while let current = batch, !current.isEmpty {
            for playlist in current {
                let detailed = try? await playlist.with([.tracks])
                let ids = (detailed?.tracks ?? []).map { AppleMusicLibraryStore.songIdPrefix + $0.id.rawValue }
                result.append(.init(id: "amlibpl_" + playlist.id.rawValue,
                                    name: playlist.name,
                                    songIds: ids))
            }
            batch = current.hasNextBatch ? try await current.nextBatch() : nil
        }
        return result
    }
}
#else
extension AppleMusicLibraryIndexer {
    static var isAvailable: Bool { false }
    static func index(since: Double?) async throws -> Result {
        Result(songs: [], albums: [], playlists: [], maxAddedMs: since)
    }
}
#endif
