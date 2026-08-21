import SwiftUI
import Observation

// ============================================================================
// MARK: - Queue builder (Now Playing ＋) — controller
// ============================================================================

/// Controller for the Now Playing panel's "queue builder": search the catalog
/// (on-device) or the Apple Music catalog (cloud, via the Discover machinery) and
/// accumulate songs into a DRAFT the user can see.
///
/// SEMANTICS — one accumulator, two exits (the shipped build's regime switch was a
/// dead end: with `sequencer.isRunning` true — which includes a PAUSED set and a
/// cold-launch session RESTORE — every ＋ went straight to the live queue, so the
/// draft stayed empty forever, the sheet showed no trace of the add, and Play,
/// gated on a non-empty draft, could never appear):
///   • EVERY ＋ lands in `draft`, running or not. The draft list IS the receipt.
///   • PLAY hands the draft to `CollectionsStore.playNow` (the reserved Now Playing
///     setlist, so history/recs/session plumbing all inherit) — which REPLACES what
///     is playing. Available whenever the draft is non-empty, full stop.
///   • ADD TO UP NEXT (`flushToQueue`) appends the draft to a RUNNING set's live
///     queue at the chosen position and clears it. Only meaningful while running.
/// So "play this now" and "queue this after" are each one tap, and neither hides.
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

    /// The accumulator EVERY add lands in — running or idle. Play feeds
    /// `consumeDraftForPlay()` into the playNow funnel (replacing playback);
    /// `flushToQueue` hands it to a running set's live queue. View-state only —
    /// never persisted, no schema.
    private(set) var draft: [SetlistPlayer.Item] = []

    /// Device-search lifecycle, so the sheet can tell "still computing" from "zero
    /// rows" (the shipped header read `On-device (0)` for both, and for a base that
    /// never bound). Cloud has the same three states on `discover.state`.
    enum DeviceState { case idle, searching, loaded }
    private(set) var deviceState: DeviceState = .idle

    /// The one-line receipt/diagnosis under the omni bars — "Added 3 to Up next",
    /// or the reason a Play refused (`playDraft` used to swallow the throw and do
    /// visibly nothing). Cleared by the next add/edit so it never goes stale.
    ///
    /// TYPED, not a bare string: the sheet draws a confirmation and a refusal
    /// differently (checkmark vs warning, accent vs danger). A `playDraft` failure
    /// rendered with a green checkmark is worse than no notice at all — it tells
    /// the user the thing that just refused actually worked.
    struct Notice: Equatable {
        enum Kind: Equatable { case confirmation, problem }
        var kind: Kind
        var text: String
    }
    private(set) var notice: Notice?

    func clearNotice() { notice = nil }

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
    ///
    /// The bind is done HERE, not in a sibling `.task`, so the base can never lose a
    /// race with the recompute (a `.task` and a `.task(id:)` declared side by side
    /// have no ordering guarantee; when the id-task won, `refreshExternal` computed
    /// against a nil base and — before the companion BrowseState fix — memoized the
    /// empty answer for the whole catalog revision, blanking device search for the
    /// rest of the session). `bindExternalBase` is idempotent, so re-binding on every
    /// recompute costs one closure allocation.
    ///
    /// `force` (the explicit-submit path) drops BrowseState's "already current" memo
    /// so an unchanged signature still recomputes.
    func refreshDevice(_ app: AppModel, force: Bool = false) async {
        bindExternalBase(app)
        if force { browse.invalidateDisplayKey() }
        deviceState = .searching
        await browse.refreshExternal(signature: deviceSignature(app),
                                     baseKey: deviceBaseKey(app))
        // A cancelled run is superseded by a newer one that has already flipped the
        // state back to `.searching` — never stamp `.loaded` on its behalf.
        if !Task.isCancelled { deviceState = .loaded }
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
    /// `immediate` = the explicit submit (return key / Search button): skip the 400 ms
    /// coalescing window entirely rather than restart it.
    func refreshCloud(rips: RipsStore, catalog: (any StreamingSearch)? = nil,
                      immediate: Bool = false) {
        discover.searchDebounced(songQuery, artist: artistQuery, rips: rips, catalog: catalog,
                                 debounce: immediate ? .zero : .milliseconds(400))
    }

    /// PLAY'S GATE — the draft alone, never `sequencer.isRunning`. Lives here (not
    /// as a view-local `!builder.draft.isEmpty`) so the rule that actually broke the
    /// shipped build is covered by a unit test rather than only by the eye.
    var canPlay: Bool { !draft.isEmpty }

    /// Is there anything to search for at all? (Both omni bars blank ⇒ device mode
    /// lists the whole catalog, cloud mode shows its hint.)
    var hasSearchTerm: Bool {
        DiscoverSearchModel.term(title: songQuery, artist: artistQuery) != nil
    }

    // MARK: Adds (one method, both regimes)

    /// Land items in the DRAFT at `pos` — running or not (see the type doc: the
    /// draft is the one accumulator, and the only thing the sheet can show the user
    /// as proof their ＋ landed). `slot` is injectable for determinism, SetlistPlayer's
    /// own test seam. The live queue is reached from the draft, via `flushToQueue`.
    func add(_ items: [SetlistPlayer.Item], at pos: AddPosition,
             slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        guard !items.isEmpty else { return }
        switch pos {
        case .bottom: draft.append(contentsOf: items)
        case .top:    draft.insert(contentsOf: items, at: 0)
        case .random:
            let i = slot(0...draft.count)
            draft.insert(contentsOf: items, at: min(max(i, 0), draft.count))
        }
        notice = nil
    }

    /// The SECOND exit: hand the whole draft to a RUNNING set's live queue at `pos`
    /// (the SetlistPlayer live-edit primitives — append / insert-after-current /
    /// Jukebox Surprise slot) and clear it. Returns how many items moved; 0 when
    /// nothing is running or the draft is empty (the primitives guard `isRunning`
    /// and would silently no-op, which is exactly the invisible add we're fixing).
    @discardableResult
    func flushToQueue(at pos: AddPosition, sequencer: SetlistPlayer,
                      slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Int {
        guard !draft.isEmpty else { return 0 }
        // The set can END between the render that offered this button and the tap.
        // Silently returning 0 is the very failure mode this whole change exists to
        // kill, so SAY the set ended — and point at Play, which still works.
        guard sequencer.isRunning else {
            notice = Notice(kind: .problem,
                            text: "Nothing is playing any more — hit Play to start these.")
            return 0
        }
        let items = draft
        switch pos {
        case .bottom: sequencer.appendToQueue(items)
        case .top:    sequencer.insertNextInQueue(items)
        case .random: sequencer.insertRandomInQueue(items, slot: slot)
        }
        draft.removeAll()
        notice = Notice(kind: .confirmation,
                        text: items.count == 1
                            ? "Added “\(items[0].title)” to Up next."
                            : "Added \(items.count) songs to Up next.")
        return items.count
    }

    /// Cloud add: provisional catalog citizenship FIRST (playNow drops ids absent
    /// from `songsById`, so the record must land before the item can enter the
    /// draft), then the draft insert, then the async library write +
    /// rip request. Returns the async half so tests (and any caller) can await it;
    /// nil when no adder is wired (the item still queues — it just won't rip).
    @discardableResult
    func addCloudHit(_ hit: RipsStore.DiscoverHit, at pos: AddPosition,
                     slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Task<Void, Never>? {
        cloudAdder?.recordProvisional(hit)
        // Re-resolve AFTER the record: when an indexed twin already claims this
        // recording's Apple Music id, `injectDiscoverAdd` supersedes the provisional
        // row instead of appending it — `amrec_X` never becomes a citizen, and
        // queueing it would make playNow silently drop the song (and the live-queue
        // projection find no stream). The adapter hands back the id that is actually
        // live in `songsById` (the claimed twin), so the user's OWN row queues.
        let id = cloudAdder?.resolvedSongId(hit) ?? hit.songId
        let item = SetlistPlayer.Item(id: id, title: hit.title,
                                      artist: hit.artist, lengthMs: hit.durationMs)
        add([item], at: pos, slot: slot)
        guard let adder = cloudAdder else { return nil }
        return Task { await adder.performAdd(hit) }
    }

    // MARK: Draft edits (the sheet's remove/reorder rows)

    func removeDraft(uids: Set<UUID>) {
        guard !uids.isEmpty else { return }
        draft.removeAll { uids.contains($0.uid) }
        notice = nil
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
        notice = nil
        return ids
    }

    /// Play the draft through the caller-supplied funnel (the view passes
    /// `IntentServices.playSongIds`). The draft is consumed ONLY on success: a
    /// throw (`vetoDuringOnboarding`, or `emptyCollection` when playNow drops every
    /// id) leaves the draft + queries intact, so a failed Play never silently loses
    /// the set the user built. Returns true when playback started (the view then
    /// dismisses the sheet); false = nothing played, sheet stays up for a retry.
    func playDraft(_ play: ([String]) async throws -> Void) async -> Bool {
        let ids = draft.map(\.id)
        guard !ids.isEmpty else { return false }
        notice = nil
        do {
            try await play(ids)
        } catch {
            // A refused Play used to do visibly NOTHING (the throw was swallowed and
            // the sheet simply stayed up). Say why — the intent errors are already
            // written as user-facing sentences.
            notice = Notice(kind: .problem, text: Self.playFailureMessage(error))
            return false
        }
        _ = consumeDraftForPlay()
        return true
    }

    /// The user-facing reason a Play refused. `PocketDJIntentError` carries a
    /// Siri-speakable sentence (onboarding veto, "…has no playable songs yet") —
    /// anything else falls back to its `localizedDescription`.
    nonisolated static func playFailureMessage(_ error: Error) -> String {
        if let intent = error as? PocketDJIntentError {
            return String(localized: intent.localizedStringResource)
        }
        return "Couldn’t start playback: \(error.localizedDescription)"
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
    /// The catalog id the queued item must carry — normally `hit.songId`, but the
    /// indexed TWIN's id when `recordProvisional`'s supersede yielded to a row the
    /// catalog already holds (same `appleMusicId`). Called after `recordProvisional`.
    func resolvedSongId(_ hit: RipsStore.DiscoverHit) -> String
}

extension QueueBuilderCloudAdding {
    /// Default: no re-resolution (test stubs and adapters without catalog access).
    func resolvedSongId(_ hit: RipsStore.DiscoverHit) -> String { hit.songId }
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

    /// The supersede blind spot: `recordProvisional` → `injectDiscoverAdd` yields to
    /// an indexed twin claiming the same `appleMusicId` (never a second row for one
    /// recording), so `hit.songId` can be dead on return. Queue the id that is live.
    func resolvedSongId(_ hit: RipsStore.DiscoverHit) -> String {
        guard let app, app.songsById[hit.songId] == nil,
              let claimed = app.songId(forAppleMusicId: hit.appleMusicId),
              app.songsById[claimed] != nil else { return hit.songId }
        return claimed
    }
}
