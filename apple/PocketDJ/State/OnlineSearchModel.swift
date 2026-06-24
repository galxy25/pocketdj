import SwiftUI
import Observation

/// Drives online (OpenSearch) search: debounced query → SearchService → hits
/// mapped to BrowseItems (resolved against the loaded catalog when present, else
/// built from the hit). Kept out of BrowseState so the local filter/sort logic
/// stays pure + unit-testable.
///
/// Results are PAGED: the first page loads on a query/filter change; `loadMore()`
/// fetches the next `from = loadedCount` page and APPENDS as the user scrolls to
/// the bottom, until `loadedCount >= total` (`hasMore == false`).
@MainActor
@Observable
final class OnlineSearchModel {
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    var state: State = .idle
    var items: [BrowseItem] = []

    /// Total matches reported by OpenSearch (`hits.total.value`) for the current
    /// query+filters — shown in the header and used to derive `hasMore`.
    private(set) var total = 0
    /// True while a NEXT-page fetch is in flight (the FIRST page uses `state`).
    private(set) var isLoadingPage = false

    /// How many results we've loaded so far = the `from` offset of the next page.
    /// (Tracked separately from `items.count` so de-duping can't desync paging.)
    private(set) var loadedCount = 0

    /// One page; small enough to feel responsive while scrolling, large enough to
    /// keep round-trips down. Capped by OpenSearch's `from + size` 10k window.
    let pageSize: Int

    private let service: Searching
    private var seenIds = Set<String>()
    private var task: Task<Void, Never>?

    /// Context for the CURRENT query, captured so `loadMore()` can re-issue the
    /// same query at a higher offset without the view re-passing everything.
    private var current: (query: String, kind: ItemKind, clauses: [Clause],
                          sortKeys: [SortKey], creds: SigV4Creds, app: AppModel)?

    init(service: Searching = LiveSearchService(), pageSize: Int = 50) {
        self.service = service
        self.pageSize = pageSize
    }

    /// More pages remain when we've loaded fewer than the total AND we haven't hit
    /// OpenSearch's `from + size` result window (offset pagination tops out at 10k).
    var hasMore: Bool {
        loadedCount < total && loadedCount < SearchService.maxResultWindow
    }

    /// `clauses` is the SAME structured filter set the on-device pipeline uses;
    /// they're translated into OpenSearch query clauses (term/terms/range/must_not)
    /// so online results honor every filter, composed with the multi_match.
    ///
    /// Always RESETS (clears accumulated results + offset) — call this whenever the
    /// query text, kind, filters, OR SORT change so a fresh first page is loaded.
    /// `sortKeys` is carried into `current` so the server applies the SAME sort on
    /// every page (the client can't sort the partial result set — see Searching).
    func searchDebounced(query: String, kind: ItemKind, clauses: [Clause] = [],
                         sortKeys: [SortKey] = [], creds: SigV4Creds?, app: AppModel) {
        task?.cancel()
        reset()
        guard let creds else {
            state = .failed("Add OpenSearch credentials in Settings to search online.")
            return
        }
        current = (query, kind, clauses, sortKeys, creds, app)
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.loadFirstPage()
        }
    }

    /// Non-debounced reset + first-page load. Same effect as `searchDebounced`
    /// minus the 300 ms delay + cancellable Task — used by tests to drive paging
    /// deterministically against a stubbed `Searching`.
    func startSearch(query: String, kind: ItemKind, clauses: [Clause] = [],
                     sortKeys: [SortKey] = [], creds: SigV4Creds, app: AppModel) async {
        task?.cancel()
        reset()
        current = (query, kind, clauses, sortKeys, creds, app)
        await loadFirstPage()
    }

    func cancel() { task?.cancel(); task = nil; reset(); state = .idle }

    /// Clears accumulated results + paging cursor. Used on every new query/filter.
    private func reset() {
        items = []
        seenIds = []
        loadedCount = 0
        total = 0
        isLoadingPage = false
    }

    private func loadFirstPage() async {
        guard let ctx = current else { return }
        state = .loading
        do {
            let page = try await service.search(ctx.query, kind: ctx.kind, clauses: ctx.clauses,
                                                sortKeys: ctx.sortKeys, creds: ctx.creds,
                                                from: 0, size: pageSize)
            guard !Task.isCancelled else { return }
            total = page.total
            append(page.hits, app: ctx.app)
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            reset()
            state = .failed(error.localizedDescription)
        }
    }

    /// Fetch + APPEND the next page (`from = loadedCount`). Guarded so the view can
    /// call it freely from `.onAppear` of the last row — it no-ops when there's no
    /// more to load or a page is already in flight.
    func loadMore() async {
        guard hasMore, !isLoadingPage, state == .loaded, let ctx = current else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let from = loadedCount
        do {
            let page = try await service.search(ctx.query, kind: ctx.kind, clauses: ctx.clauses,
                                                sortKeys: ctx.sortKeys, creds: ctx.creds,
                                                from: from, size: pageSize)
            // The query/filters may have changed while paging (reset bumps offset to
            // 0) — drop a stale page rather than appending it to a fresh result set.
            guard from == loadedCount else { return }
            total = page.total
            append(page.hits, app: ctx.app)
        } catch {
            // Keep what we have; a transient page error shouldn't wipe loaded rows.
        }
    }

    /// Advance the offset by the page's RAW count (so `hasMore` stays correct even
    /// when de-dupe drops a row) and append the unseen, catalog-mapped items.
    private func append(_ hits: [SearchHit], app: AppModel) {
        loadedCount += hits.count
        for h in hits where seenIds.insert(h.id).inserted {
            if let item = map(h, app: app) { items.append(item) }
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
