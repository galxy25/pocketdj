import SwiftUI
import Observation

// ============================================================================
// MARK: - Queue builder (Now Playing ＋) — controller
// ============================================================================

/// Controller for the Now Playing panel's "queue builder": search the catalog
/// (on-device) or the Apple Music catalog (cloud, via the Discover machinery) and
/// feed songs into the LIVE queue — or, with nothing playing, into a DRAFT list
/// that Play hands to the `CollectionsStore.playNow` funnel (the reserved Now
/// Playing setlist, so history/recs/session plumbing all inherit).
///
/// View-free by design (the BrowseState/DiscoverSearchModel split): the sheet
/// renders what this owns, and every derivation here is unit-testable.
///
/// DEVICE search runs through `BrowseState.refreshExternal` — the History lane —
/// NOT `refreshResults`: the shared `browseResultsCache` is a 6-entry LRU and a
/// second surface churning it would evict the Browser's memo (the reason the
/// panel's add-search also bypasses it). The host view drives the recompute with
/// `.task(id: deviceSignature(app))` after `bindExternalBase(app)`, exactly as
/// HistoryView does.
@MainActor
@Observable
final class QueueBuilderState {
    /// The builder's OWN mode — never `BrowseState.searchMode` (that is the
    /// Browser's persisted preference; flipping it here would clobber the Browser).
    /// `cloud` = the Discover machinery (MusicKit + rip-server `/search` merge):
    /// the full Apple Music catalog, which is what "add NEW songs" needs — the
    /// OpenSearch online toggle only indexes the user's own catalog.
    enum Mode: String { case device, cloud }

    /// Where an add lands, mapped 1:1 onto the SetlistPlayer live-edit primitives
    /// (append / insert-after-current / Jukebox Surprise random slot).
    enum AddPosition { case bottom, top, random }

    /// Device-mode filter/sort/query state. Own persistence key so the Browser's
    /// snapshot is never clobbered (the History-mode precedent); kind pinned .song.
    let browse: BrowseState
    /// Cloud-mode driver — the Browse ▸ Discover controller, reused whole (400 ms
    /// debounce, MusicKit + proxy merge, artist refine).
    let discover = DiscoverSearchModel()

    /// One-click device ⇄ cloud. Leaving cloud cancels the in-flight Discover task
    /// (a late publish must not repopulate a mode the user left); device state is
    /// deliberately left intact in BOTH directions. Persisted per device.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            if mode == .device { discover.cancel() }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    /// The bottom omni bars. `songQuery` IS the BrowseState query (folded-substring
    /// over name/artist/album keys); `artistQuery` is a READ-time refine layer in
    /// device mode (the searchKeys haystack is one joined string, so a second
    /// query-time term would fight the first) and Discover's refine field in cloud.
    var songQuery = "" { didSet { browse.query = songQuery } }
    var artistQuery = ""

    /// The no-set accumulator: with nothing running, adds land here and Play feeds
    /// `consumeDraftForPlay()` into the playNow funnel. View-state only — never
    /// persisted, no schema.
    private(set) var draft: [SetlistPlayer.Item] = []

    /// Cloud-add seam (library write + rip request) — set by the host view to the
    /// production adapter; tests stub it to pin the record-before-queue ordering.
    @ObservationIgnored var cloudAdder: (any QueueBuilderCloudAdding)?

    private let defaults: UserDefaults
    static let modeKey = "npBuilderMode"
    static let browseKey = "pdj.queuebuilder.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let b = BrowseState(defaults: defaults, persistenceKey: Self.browseKey,
                            defaultKind: .song)
        b.kind = .song   // pinned: the builder only queues songs (a snapshot can't drift it)
        browse = b
        mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .device
    }

    // MARK: Device search (the refreshExternal lane)

    /// Source the external base from the live catalog — an O(1) hand-off of the
    /// pre-built rows/keys, captured weak so the builder never retains the app.
    func bindExternalBase(_ app: AppModel) {
        browse.externalBase = { [weak app] in
            guard let app else { return ([], []) }
            return (app.browseItems(.song), app.searchKeys(.song))
        }
    }

    /// The `.task(id:)` recompute driver. `filterSortSignature()` is deliberately
    /// catalog-revision-free, so the revision is composed in here (the History
    /// idiom); `artistQuery` rides along so the read-time refine republishes too.
    func deviceSignature(_ app: AppModel) -> String {
        "\(app.catalogRevision)|\(artistQuery)|\(browse.filterSortSignature())"
    }

    /// Base cache key: rebuild the handed-off base only when the catalog moves.
    func deviceBaseKey(_ app: AppModel) -> String { "qb-\(app.catalogRevision)" }

    /// Run the debounced off-main filter/sort and publish to `browse.displayItems`.
    func refreshDevice(_ app: AppModel) async {
        await browse.refreshExternal(signature: deviceSignature(app),
                                     baseKey: deviceBaseKey(app))
    }

    /// What the device-mode list renders: the off-main-computed rows with the
    /// artist refine layered on at read time (cheap, like membership/favorites).
    var deviceResults: [BrowseItem] {
        Self.refineByArtist(browse.displayItems, artist: artistQuery)
    }

    /// Folded-substring artist narrowing (the DiscoverSearchModel.refine twin, with
    /// the searchKeys' case/diacritic folding so "Béla" matches "bela"). Empty
    /// artist = identity. Pure + nonisolated: safe off-main.
    nonisolated static func refineByArtist(_ items: [BrowseItem], artist: String) -> [BrowseItem] {
        let a = artist.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !a.isEmpty else { return items }
        return items.filter { item in
            guard case .string(let name) = Fields.value(item, "artist") else { return false }
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(a)
        }
    }

    // MARK: Cloud search (the Discover machinery)

    /// Kick the debounced Discover search for the current queries. `catalog` is the
    /// MusicKit lane (`streaming.providers` first `StreamingSearch`), exactly as
    /// BrowseView's triggerDiscover passes it.
    func refreshCloud(rips: RipsStore, catalog: (any StreamingSearch)? = nil) {
        discover.searchDebounced(songQuery, artist: artistQuery, rips: rips, catalog: catalog)
    }

    // MARK: Adds (one method, both regimes)

    /// Land items at `pos`. A RUNNING set gets the live-edit primitives (append /
    /// insert-next / Surprise random); idle mirrors their semantics onto `draft`
    /// (the primitives guard `isRunning` and would no-op). `slot` is injectable for
    /// determinism — SetlistPlayer's own test seam, extended to the draft regime.
    func add(_ items: [SetlistPlayer.Item], at pos: AddPosition, sequencer: SetlistPlayer,
             slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        guard !items.isEmpty else { return }
        if sequencer.isRunning {
            switch pos {
            case .bottom: sequencer.appendToQueue(items)
            case .top:    sequencer.insertNextInQueue(items)
            case .random: sequencer.insertRandomInQueue(items, slot: slot)
            }
        } else {
            switch pos {
            case .bottom: draft.append(contentsOf: items)
            case .top:    draft.insert(contentsOf: items, at: 0)
            case .random:
                let i = slot(0...draft.count)
                draft.insert(contentsOf: items, at: min(max(i, 0), draft.count))
            }
        }
    }

    /// Cloud add: provisional catalog citizenship FIRST (playNow drops ids absent
    /// from `songsById`, so the record must land before the item can enter a queue
    /// or the draft), then the queue/draft insert, then the async library write +
    /// rip request. Returns the async half so tests (and any caller) can await it;
    /// nil when no adder is wired (the item still queues — it just won't rip).
    @discardableResult
    func addCloudHit(_ hit: RipsStore.DiscoverHit, at pos: AddPosition,
                     sequencer: SetlistPlayer,
                     slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Task<Void, Never>? {
        cloudAdder?.recordProvisional(hit)
        let item = SetlistPlayer.Item(id: hit.songId, title: hit.title,
                                      artist: hit.artist, lengthMs: hit.durationMs)
        add([item], at: pos, sequencer: sequencer, slot: slot)
        guard let adder = cloudAdder else { return nil }
        return Task { await adder.performAdd(hit) }
    }

    // MARK: Draft edits (the sheet's remove/reorder rows)

    func removeDraft(uids: Set<UUID>) {
        guard !uids.isEmpty else { return }
        draft.removeAll { uids.contains($0.uid) }
    }

    func moveDraft(fromOffsets: IndexSet, toOffset: Int) {
        let src = IndexSet(fromOffsets.filter(draft.indices.contains))
        guard !src.isEmpty else { return }
        draft.move(fromOffsets: src, toOffset: max(0, min(toOffset, draft.count)))
    }

    // MARK: Play (draft → the playNow funnel)

    /// Hand the draft to the caller as playNow input (ids in draft order) and reset
    /// the builder. The view feeds these to `IntentServices.playSongIds(_:name:source:)`
    /// — the reserved Now Playing setlist — so history/recs/session all inherit.
    func consumeDraftForPlay() -> [String] {
        let ids = draft.map(\.id)
        draft.removeAll()
        songQuery = ""
        artistQuery = ""
        return ids
    }
}

// ============================================================================
// MARK: - Cloud add seam
// ============================================================================

/// What "＋ in cloud mode" does BESIDES queueing. Split sync/async because the
/// ordering is load-bearing: `recordProvisional` must complete before the item
/// enters a queue (catalog citizenship gates playNow); `performAdd` runs after.
@MainActor
protocol QueueBuilderCloudAdding: AnyObject {
    /// Synchronous catalog citizenship — the `DiscoverRow.addToCatalog` move:
    /// idempotent DiscoverAddsStore entry → `onAdded` → `AppModel.injectDiscoverAdd`,
    /// so the `amrec_` id is in `songsById` on return.
    func recordProvisional(_ hit: RipsStore.DiscoverHit)
    /// The full add: Apple Music library write (truthful outcome) + rip request —
    /// `RipsStore.discoverAdd`, NOT the recognizer's force-rip path.
    func performAdd(_ hit: RipsStore.DiscoverHit) async
}

/// Production adapter over the canonical Discover add flow. Record-first means
/// `discoverAdd`'s own (richer) record is skipped by the store's idempotency —
/// identical to the shipped `DiscoverRow.enqueue` behavior, accepted.
@MainActor
final class DiscoverQueueBuilderCloudAdder: QueueBuilderCloudAdding {
    private weak var app: AppModel?
    private let rips: RipsStore
    private let library: (any MusicLibraryContributor)?

    init(app: AppModel, rips: RipsStore, library: (any MusicLibraryContributor)?) {
        self.app = app
        self.rips = rips
        self.library = library
    }

    func recordProvisional(_ hit: RipsStore.DiscoverHit) {
        // Already a citizen (any source, including a prior add) ⇒ nothing to record.
        guard app?.songsById[hit.songId] == nil else { return }
        rips.discoverAdds?.add(songId: hit.songId, appleMusicId: hit.appleMusicId,
                               title: hit.title, artist: hit.artist, album: hit.album,
                               artworkUrl: hit.artworkUrl ?? hit.albumArtworkUrl,
                               durationMs: hit.durationMs,
                               albumAppleMusicId: hit.albumAppleMusicId,
                               albumArtworkUrl: hit.albumArtworkUrl,
                               trackNumber: hit.trackNumber, discNumber: hit.discNumber,
                               year: hit.year, explicit: hit.explicit)
    }

    func performAdd(_ hit: RipsStore.DiscoverHit) async {
        await rips.discoverAdd(hit, library: library)
    }
}
