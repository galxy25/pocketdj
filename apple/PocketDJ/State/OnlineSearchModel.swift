import SwiftUI
import Observation

/// Drives online (OpenSearch) search: debounced query → SearchService → hits
/// mapped to BrowseItems (resolved against the loaded catalog when present, else
/// built from the hit). Kept out of BrowseState so the local filter/sort logic
/// stays pure + unit-testable.
@MainActor
@Observable
final class OnlineSearchModel {
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    var state: State = .idle
    var items: [BrowseItem] = []

    private var task: Task<Void, Never>?

    /// `clauses` is the SAME structured filter set the on-device pipeline uses;
    /// they're translated into OpenSearch query clauses (term/terms/range/must_not)
    /// so online results honor every filter, composed with the multi_match.
    func searchDebounced(query: String, kind: ItemKind, clauses: [Clause] = [],
                         creds: SigV4Creds?, app: AppModel) {
        task?.cancel()
        guard let creds else {
            state = .failed("Add OpenSearch credentials in Settings to search online.")
            items = []
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.run(query: query, kind: kind, clauses: clauses, creds: creds, app: app)
        }
    }

    func cancel() { task?.cancel(); task = nil; state = .idle }

    private func run(query: String, kind: ItemKind, clauses: [Clause],
                     creds: SigV4Creds, app: AppModel) async {
        state = .loading
        do {
            let hits = try await SearchService.search(query, kind: kind, clauses: clauses, creds: creds)
            guard !Task.isCancelled else { return }
            items = hits.compactMap { map($0, app: app) }
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            state = .failed(error.localizedDescription)
        }
    }

    /// Prefer the full catalog item (cover art, etc.); fall back to the hit's fields.
    private func map(_ h: SearchHit, app: AppModel) -> BrowseItem? {
        if h.type == "album" {
            let src = app.source(ofAlbum: h.id) ?? h.source
            if let album = app.albumsById[h.id] { return .album(album, source: src) }
            return .album(IndexAlbum(id: h.id, artist: h.artist ?? "", name: h.title ?? "",
                                     coverArt: nil, coverArtSources: nil, genre: h.genre,
                                     year: h.year, country: nil, trackList: [], fileType: nil,
                                     audioTracks: nil, audioDurationSec: nil), source: src)
        } else {
            let src = app.source(ofSong: h.id) ?? h.source
            if let song = app.songsById[h.id] {
                return .song(song, albumName: app.albumName(forSong: song), source: src)
            }
            let song = IndexSong(id: h.id, albumId: h.albumId, artist: h.artist ?? "", name: h.title ?? "",
                                 trackNumber: h.trackNumber, year: h.year, sentimentKeywords: nil,
                                 explicit: h.explicit, bpm: h.bpm, key: h.key, camelot: h.camelot,
                                 length: nil, fileType: nil, lyricsStatus: nil, appleMusicId: nil)
            return .song(song, albumName: h.album ?? "", source: src)
        }
    }
}
