import SwiftUI

/// History mode — a scrollable timeline of what you've done: every song you've played (in whichever
/// Mix / Playlist / Pocket / Set list / Browser it happened in) AND every collection change (adding
/// a song, hearting/unhearting, removing), with the Browser's filter + sort controls on the plays.
/// Opened from anywhere with ⌘H.
///
/// THREE tabs (Levi 2026-08-10 — "playback, for you, collection tabs only"):
///  • **Playback** (default) — song PLAYS from the append-only `PlayHistoryStore`, driven through the
///    Browser's own filter/sort/paged machinery (see `BrowseState.refreshExternal`, off the main actor).
///  • **For You** — the cached recommendation tiles, only while the rec engine is on.
///  • **Collection** — collection ACTIVITY (add / heart / unheart / remove) from `CollectionActivityStore`.
///
/// The tab control shows EVERY available tab with the current one filled in. It used to show only the
/// views you were NOT in, which was a workable trick for a fixed trio but degenerates to a single
/// full-width button once the fourth ("Unified") view is gone and the engine is off.
///
/// **Unified is REMOVED** (2026-08-10). It interleaved the two streams newest-first, filtered by the
/// search query only. What that view — and only that view — could show is a play and a collection
/// change ADJACENT IN TIME ("I hearted this right after playing it"); each stream on its own survives
/// intact in Playback and Collection. Its one exclusive ACTION, the "Rewind to here" row menu, moved
/// onto the Playback rows, which carry the same `PlayRef.eventId` it needs.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayHistoryStore.self) private var history
    @Environment(CollectionActivityStore.self) private var activity
    @Environment(CollectionsStore.self) private var collections
    @Environment(SettingsStore.self) private var settings
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(IntentServices.self) private var intents
    /// Optional like `AddToCollectionView`/`AppleMusicSettingsView`: always injected by the app, but a
    /// preview/test host that renders History standalone should degrade to "no backfill", not trap.
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?
    /// The SHARED per-window multi-select (RootView-owned) — the same model Browse and the
    /// collection details use. History used to run its own private `Set<String>`, which meant
    /// two selection systems in one app: no ⌘-click/⇧-click ranges, no ⌥-click toggle, no
    /// selection bar, and no Copy / Add to…. It's now one model, scoped to `selectionScope`
    /// so arming Select here can never intercept taps in Browse.
    @Environment(RowSelection.self) private var rowSelection
    @Binding var path: NavigationPath

    /// Declaration order IS tab order: Playback, For You, Collection (the owner's own ordering).
    enum HistoryTab: String, CaseIterable {
        case playback = "Playback"
        case forYou = "For You"
        case collection = "Collection"
        var symbol: String {
            switch self {
            case .playback:   return "play.circle.fill"
            case .collection: return "rectangle.stack.fill"
            case .forYou:     return "sparkles"
            }
        }
        /// Accessibility-id token: identical to the lowercased rawValue for the two
        /// single-word tabs (no test churn); "For You" becomes "for-you".
        var a11y: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "-") }
    }
    /// Playback is the landing tab. Nothing persists this — History's tab is per-appearance
    /// `@State`, so removing Unified strands no stored value and needs no migration. (The one
    /// stored "where was I" seam in this app is `SettingsStore.lastSection`, which names the app
    /// SECTION — "History" — never a tab inside it.)
    @State private var tab: HistoryTab = .playback
    /// Which stream the COLLECTION tab is showing (F8). `.activity` is the default and is the view
    /// this tab has always had; `.songs` / `.albums` are the One True Timeline.
    ///
    /// EPHEMERAL `@State`, deliberately — exactly like `tab` above. Persisting it would mean the
    /// Collection tab could open on the timeline, and the owner's requirement is that the default
    /// screen is unchanged. Nothing to migrate, nothing to strand.
    @State private var collectionGrain: TimelineGrain = .activity
    /// The History row a rewind is pending on — nil unless the confirmation is up.
    @State private var rewindTarget: PlayHistoryStore.PlayEvent?
    /// THE For You REFRESH. Bumped by the tab menu's Refresh and nothing else — For You is CACHED
    /// (owner's rule), so this is the only thing in the app that re-ranks it. Lives here rather
    /// than inside the grid because the owner asked for the control to be "in the menu", and this
    /// screen owns the toolbar.
    @State private var forYouRefreshToken = 0

    /// History's own filter/sort state — distinct persistence key so it never clobbers the
    /// Browser's, defaulting to most-recently-played first.
    @State private var browse: BrowseState = {
        let b = BrowseState(persistenceKey: "pdj.history.v1", historyMode: true)
        if b.sortKeys.isEmpty { b.sortKeys = [SortKey(field: "lastPlayedAt", dir: .desc)] }
        return b
    }()
    @State private var groupBySong = false
    @State private var showFilter = false
    @State private var showSort = false
    /// History's `.searchable` field has focus ⇒ ⌘A belongs to the FIELD, not to select-all
    /// (mirrors BrowseView; RootView's ⌘A shadow is gated on `RowSelection.textEntryFocused`).
    @FocusState private var searchFocused: Bool
    /// Result of a manual write-back backfill (the "send my adds to Apple Music" toolbar action),
    /// shown in a one-off alert. nil ⇒ no alert.
    @State private var backfillMessage: String?
    /// On-device incremental rendering budget — History can grow to tens of thousands of
    /// events, so (exactly like the Browser) only a growing PREFIX of the filtered+sorted rows
    /// is handed to ForEach; it grows as the last visible row appears. Paired with the
    /// `recomputeSignature` it was grown against so a filter/sort/mode change restarts paging.
    @State private var visibleCount = BrowsePaging.pageSize
    @State private var visibleKey = ""

    /// Recompute signature: the CATALOG revision (rows resolve title/album/artwork from the live
    /// catalog, so a load/edit while History is on screen must re-fire), the event-log revision,
    /// the mode toggle, and the filter/sort inputs. Any change re-runs `refreshExternal`
    /// (auto-cancelling the prior run) AND restarts paging.
    private var recomputeSignature: String {
        "\(app.catalogRevision)-\(history.revision)-\(groupBySong)-\(browse.filterSortSignature())"
    }

    /// Identifies the BASE rows (catalog + event log + mode) independent of the filter/sort/query,
    /// so `refreshExternal` rebuilds the expensive per-event base only when it actually changes and
    /// reuses it across query/filter/sort edits.
    private var baseKey: String { "\(app.catalogRevision)-\(history.revision)-\(groupBySong)" }

    /// Paging key = what makes the RESULT SET different (mode, filters/sort, event log, and the
    /// row count). Deliberately EXCLUDES app.catalogRevision: a catalog load bumps the recompute
    /// signature (rows re-resolve metadata) but must NOT strand a scrolled-in budget back at page
    /// one every time the catalog churns. The count catches a catalog load that changes which rows
    /// pass a catalog-derived filter.
    private var pagingKey: String {
        "\(history.revision)-\(groupBySong)-\(browse.filterSortSignature())-\(browse.displayItems.count)"
    }

    /// The render budget for the CURRENT result set: the grown `visibleCount` only while it still
    /// refers to the current paging key; otherwise one page. Derived (not reset in an onChange) so
    /// a filter/sort/mode switch never renders the previous set's large prefix.
    private var liveVisible: Int { visibleKey == pagingKey ? visibleCount : BrowsePaging.pageSize }

    var body: some View {
        content
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $browse.query, prompt: "Search title or artist")
            .searchFocused($searchFocused)
            .toolbar { toolbar }
            .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app, collections: collections) }
            .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
            // History's sheets offer the same song field set, "Plays" included — feed it too.
            .playCountsFeed(browse)
            .alert("Apple Music", isPresented: Binding(
                get: { backfillMessage != nil }, set: { if !$0 { backfillMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(backfillMessage ?? "") }
            .confirmationDialog("Rewind playback?", isPresented: Binding(
                get: { rewindTarget != nil }, set: { if !$0 { rewindTarget = nil } }),
                presenting: rewindTarget) { target in
                Button("Rewind to here") {
                    let t = target
                    rewindTarget = nil
                    performRewind(t)
                }
                Button("Cancel", role: .cancel) { rewindTarget = nil }
            } message: { _ in
                Text(rewindReplacesLiveSet
                     ? "This replaces what’s playing now and starts the set again from that song."
                     : "This starts the set again from that song.")
            }
            .background { shortcuts }
            .onChange(of: browse.query) { browse.persist() }
            .onChange(of: browse.clauses) { browse.persist() }
            .onChange(of: browse.sortKeys) { browse.persist() }
            .task(id: recomputeSignature) {
                browse.externalBase = buildItems
                await browse.refreshExternal(signature: recomputeSignature, baseKey: baseKey)
            }
            .modifier(HistorySelectionWiring(scope: Self.selectionScope,
                                             active: tab == .playback,
                                             pagingKey: pagingKey,
                                             allIds: { displayedSongIds },
                                             payload: { selectionPayload() },
                                             searchFocused: searchFocused))
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            tabBar
            switch tab {
            case .playback:
                // The Timeline/By-song mode picker is GONE (Levi 2026-07-18: the two reads
                // were indistinguishable in practice) — Playback is always the timeline. The
                // groupBySong plumbing stays (false forever) so the grouped engine remains
                // one flag away if a future view wants it.
                if browse.displayItems.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            case .collection:
                collectionContent
            case .forYou:
                ForYouTilesView(path: $path, refreshToken: forYouRefreshToken)
            }
        }
        // Match every other tab's dark-blue canvas (the Lists are made transparent via
        // .scrollContentBackground(.hidden), so this shows through instead of the system black).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        // Lives HERE (not on the body chain — that chain is at the type-checker's budget):
        // the engine turned off while For You was showing → fall back to Playback. Without this
        // the tab bar would drop For You while the CONTENT stayed on it: a tab you cannot leave
        // and cannot see selected.
        .onChange(of: settings.recEngineEnabled) {
            if !settings.recEngineEnabled && tab == .forYou { tab = .playback }
        }
    }

    // MARK: - Tab control (every available tab; the current one is filled)

    /// The recommendation-engine fixture seam — mirrors `RecommendationService.fixtureOn` so a
    /// UI test can light the For You tab without the Settings toggle.
    private var recFixtureOn: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PDJ_REC_FIXTURE"] == "1" && env["PDJ_USE_FIXTURE"] != nil
    }

    /// The tabs on offer, in declaration order. For You joins only while the recommendation engine
    /// is on (or its UI-test fixture seam) — with the engine off the pair is Playback | Collection.
    private var visibleTabs: [HistoryTab] {
        (settings.recEngineEnabled || recFixtureOn)
            ? HistoryTab.allCases
            : HistoryTab.allCases.filter { $0 != .forYou }
    }

    /// Custom button row (not a segmented `Picker`) so it renders prominently and identically on
    /// iOS, macOS, and visionOS. EVERY available tab is shown and the current one is filled —
    /// the old control showed only the views you were NOT in, which with Unified gone and the
    /// engine off would leave a lone full-width button standing in for a tab bar.
    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(visibleTabs, id: \.self) { t in
                let isCurrent = t == tab
                Button {
                    guard t != tab else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold))
                        Text(t.rawValue).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fg)
                // bgOverlay (not bgRaised) + a stronger accent stroke so the control stands out
                // against the dark-blue Theme.bg canvas (bgRaised is nearly bg — too low-contrast).
                // The SELECTED tab fills with the accent instead, so which view you're in reads at
                // a glance now that the current tab is on screen rather than hidden.
                .background(isCurrent ? Theme.accent.opacity(0.30) : Theme.bgOverlay,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(isCurrent ? 0.95 : 0.45),
                                lineWidth: isCurrent ? 2 : 1)
                )
                .accessibilityIdentifier("history-tab-\(t.a11y)")
                // The one signal a test (or VoiceOver) can read for "which tab am I on" now that
                // every tab is always present.
                .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        // NB: no container accessibilityIdentifier here — a parent id absorbs the child buttons'
        // identifiers and makes `history-tab-<mode>` unqueryable in XCUITest.
    }

    // MARK: - Collection tab: the ONE TRUE TIMELINE (F8)

    /// The Collection tab. `.activity` — the feed of adds / hearts / unhearts / removes this tab has
    /// always been — is the DEFAULT and is what opens; the owner was explicit that "by default it
    /// just shows its current view of the most recent additions to your collection and favoriting".
    /// The grain picker is the one new thing on that default screen, and moving it off Activity
    /// swaps in `CollectionTimelineView`: the whole catalog on an add-date axis.
    @ViewBuilder private var collectionContent: some View {
        VStack(spacing: 0) {
            grainPicker
            if collectionGrain == .activity {
                activityContent
            } else {
                CollectionTimelineView(path: $path, grain: collectionGrain, query: browse.query)
            }
        }
    }

    /// Activity | Songs | Albums. A plain segmented `Picker` (not the hand-rolled button row the
    /// TAB bar uses): this is a mode switch inside one view, and the system control reads correctly
    /// as such on all three platforms.
    ///
    /// `Text`, not `Label`: a segmented Picker collapses a `Label` toward its icon when space is
    /// tight, which on iPhone would leave three unlabelled glyphs — and would take the segment's
    /// accessibility label with it, so `app.segment("Songs")` (the ONE cross-platform way this repo
    /// drives a segmented picker) could not find it.
    private var grainPicker: some View {
        Picker("View", selection: $collectionGrain) {
            ForEach(TimelineGrain.allCases) { g in Text(g.label).tag(g) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.bottom, 8)
        .accessibilityIdentifier("collection-grain")
    }

    // MARK: - Collection activity timeline (F11)

    /// Activity events, NEWEST FIRST (the log is append-only oldest→newest), filtered by the search
    /// query. Its own simple list — distinct rows per kind, an SF Symbol + relative time, tap → the
    /// item where the id resolves to a catalog song.
    @ViewBuilder private var activityContent: some View {
        let q = browse.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let events = q.isEmpty
            ? Array(activity.events.reversed())
            : activity.events.reversed().filter { activitySearchKey($0).contains(q) }
        if events.isEmpty {
            activityEmptyState
        } else {
            List {
                ForEach(events) { event in
                    activityRow(event)
                        .contentShape(Rectangle())
                        .onTapGesture { openActivityItem(event) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func activityRow(_ e: CollectionActivityStore.ActivityEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(e.kind == .heart ? Theme.accent : Theme.accent2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(activityHeadline(e)).font(.callout).foregroundStyle(Theme.fg).lineLimit(2)
                if let artist = displayArtist(e) {
                    Text(artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Self.relative(e.at)).font(.caption2).foregroundStyle(Theme.fgDim)
                    // Nothing names this item — show the raw id so the row stays traceable
                    // (and searchable) instead of reading as an anonymous "unknown item".
                    if isUnresolved(e) {
                        Text(e.itemId)
                            .font(.caption2.monospaced()).foregroundStyle(Theme.fgDim)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("activity-row-id")
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("activity-row")
    }

    /// "Added <item> to <collection>" / "Hearted <item>" / "Removed heart from <item>" /
    /// "Removed <item> from <collection>", from the event's snapshots. An item nothing can name
    /// reads "an unknown item"; the raw id is shown beneath the row instead (see `isUnresolved`).
    private func activityHeadline(_ e: CollectionActivityStore.ActivityEvent) -> String {
        let item = displayTitle(e)
        let coll = e.collectionName ?? "a collection"
        switch e.kind {
        case .add:           return "Added \(item) to \(coll)"
        case .heart:         return "Hearted \(item)"
        case .unheart:       return "Removed heart from \(item)"
        case .remove:        return "Removed \(item) from \(coll)"
        case .catalogAdd:    return "Added \(item) to your library"
        case .catalogRemove: return "Removed \(item) from your library"
        }
    }

    /// Search key. Includes the ARTIST, and the raw ITEM ID **only for unresolved rows**: the id
    /// used to be the visible title of such a row, so searching by it kept working by accident.
    /// Now that those rows read "an unknown item", the id has to be carried explicitly or id search
    /// silently breaks — but carrying it for EVERY row would let a namespace prefix ("sng", "am"
    /// on the way to "Amy") match the whole log, which would turn any such query into a full
    /// activity dump.
    private func activitySearchKey(_ e: CollectionActivityStore.ActivityEvent) -> String {
        [displayTitle(e), displayArtist(e) ?? "", e.collectionName ?? "",
         isUnresolved(e) ? e.itemId : ""]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Prefer the LIVE catalog title (fresh renames), fall back to the event's record-time snapshot.
    /// A row with NEITHER is one whose item this device's catalog can't resolve — an Apple Music
    /// song that was never indexed here, or one whose source was toggled off. It reads as an unknown
    /// item and the row shows the raw id beneath (see `isUnresolved`) rather than AS the title.
    private func displayTitle(_ e: CollectionActivityStore.ActivityEvent) -> String {
        if let s = app.songsById[e.itemId] { return "“\(s.name)”" }
        if let a = app.albumsById[e.itemId] { return "“\(a.name)”" }
        if let t = e.itemTitle, !t.isEmpty { return "“\(t)”" }
        return "an unknown item"
    }

    /// The artist line — live catalog first, then the record-time snapshot. nil for rows that have
    /// no artist by nature (a nested pocket, a studio item) or legacy rows recorded before the
    /// snapshot existed.
    private func displayArtist(_ e: CollectionActivityStore.ActivityEvent) -> String? {
        if let s = app.songsById[e.itemId] { return s.artist }
        if let a = app.albumsById[e.itemId] { return a.artist }
        if let a = e.itemArtist, !a.isEmpty { return a }
        return nil
    }

    /// Nothing but the raw id identifies this row (no live catalog item, no title snapshot).
    private func isUnresolved(_ e: CollectionActivityStore.ActivityEvent) -> Bool {
        app.songsById[e.itemId] == nil && app.albumsById[e.itemId] == nil
            && (e.itemTitle?.isEmpty ?? true)
    }

    /// Open what an activity row points at. Songs and albums both have destinations, and a nested
    /// POCKET row (from `addPocketRef`) resolves to its pocket. Anything else — a studio item, an
    /// id this catalog can't resolve — stays inert rather than pushing a synthesized stub: a
    /// SongDetailView built from a bare id fires a live MusicKit catalog search off an empty
    /// name/artist.
    private func openActivityItem(_ e: CollectionActivityStore.ActivityEvent) {
        if let song = app.songsById[e.itemId] { path.append(song); return }
        if let album = app.albumsById[e.itemId] { path.append(album); return }
        if let pocket = collections.pocket(e.itemId) { path.append(pocket) }
    }

    private var activityEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text("No collection activity yet").font(.headline).foregroundStyle(Theme.fg)
            Text("Adding a song to a playlist or pocket, hearting a song, or removing one shows up here.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("activity-empty")
    }

    // MARK: - Playback (plays) timeline

    /// The paged list: renders only the current `liveVisible` prefix of the full result set and
    /// grows the budget as the last rendered row scrolls into view.
    private var historyList: some View {
        let items = browse.displayItems
        let page = BrowsePaging.page(items, visible: liveVisible)
        return List {
            ForEach(page) { item in
                if case .song(let song, _, _, _, let play) = item, let play {
                    row(song: song, play: play)
                        // The SHARED gestures: plain tap opens the song, ⌘/⇧-click extends a
                        // range, ⌥-click toggles, Select mode toggles on plain taps — and the
                        // row becomes a drag source. The range universe is the DEDUPED displayed
                        // order: a song can appear on many rows (one per play), so the id space
                        // has to collapse to one entry per song or a range would be ambiguous.
                        .selectableSongRow(id: song.id, scope: Self.selectionScope,
                                           orderedIds: { displayedSongIds },
                                           payload: { dragPayload(for: song) },
                                           onOpen: { path.append(song) })
                        .onAppear { onRowAppear(item, rendered: page, fullCount: items.count) }
                        .contextMenu { rowMenu(song, eventId: play.eventId) }
                        // `.contain` (never a bare identifier on a tap-gesture row — the
                        // Browse lesson): the row stays a CONTAINER so its own id is
                        // queryable AND the title/artist/context labels keep theirs.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("history-row-\(song.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // count · Select all · Add to ▸ · Copy · ✕ — the same bar Browse and the collection
        // details ride, scoped to History so it only shows for a History selection.
        .safeAreaInset(edge: .top, spacing: 0) { SelectionBar(scope: Self.selectionScope) }
    }

    /// Row context menu: **Rewind to here**, Select (the touch entry point into multi-select),
    /// Copy (whole selection when the row is part of it), Share.
    ///
    /// Rewind used to live ONLY on the Unified rows, so deleting that view would have deleted the
    /// feature's only entry point. It belongs here anyway: a Playback row IS a play event, and
    /// `PlayRef.eventId` is the very id `rewindSlice` keys on.
    @ViewBuilder private func rowMenu(_ song: IndexSong, eventId: UUID) -> some View {
        rewindMenuItem(eventId: eventId)
        Button {
            rowSelection.enterSelectMode(scope: Self.selectionScope, initial: song.id)
        } label: { Label("Select", systemImage: "checklist") }
            .accessibilityIdentifier("history-select-song-\(song.id)")
        Button {
            rowSelection.copyRowOrSelection(rowId: song.id, scope: Self.selectionScope,
                                            single: SongTransfer.make(ids: [song.id],
                                                                      songsById: app.songsById))
        } label: { Label("Copy", systemImage: "doc.on.doc") }
            .accessibilityIdentifier("history-copy-song-\(song.id)")
        ShareLink(item: ShareText.forSong(song)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// The last RENDERED row scrolled into view → grow the render budget toward the full result
    /// count (no-op once everything is shown). Mirrors BrowseView.onRowAppear.
    private func onRowAppear(_ item: BrowseItem, rendered: [BrowseItem], fullCount: Int) {
        guard item.id == rendered.last?.id, liveVisible < fullCount else { return }
        visibleCount = BrowsePaging.grow(liveVisible, upTo: fullCount)
        visibleKey = pagingKey
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text(history.events.isEmpty ? "No plays yet" : "No plays match your filters")
                .font(.headline).foregroundStyle(Theme.fg)
            Text(history.events.isEmpty
                 ? "Songs you play in a Mix, Playlist, Pocket, Set list, or the Browser show up here."
                 : "Adjust the filters or date range to see more.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("history-empty")
    }

    /// One history row: the shared song row, with a context line ("Mix · Friday Mix · 2h ago")
    /// beneath it so you see WHERE and WHEN you played it.
    private func row(song: IndexSong, play: PlayRef) -> some View {
        let album = song.albumId.flatMap { app.albumsById[$0] }
        return VStack(alignment: .leading, spacing: 3) {
            SongRowView(data: SongRowData(song: song, album: album))
            HStack(spacing: 5) {
                Image(systemName: play.source.symbol).font(.system(size: 9))
                Text(contextLabel(play)).lineLimit(1)
                Text("·")
                Text(Self.relative(play.playedAt))
                Spacer()
                if play.count > 1 {
                    Text("\(play.count) plays")
                        .accessibilityIdentifier("history-count-\(song.id)")
                }
            }
            .font(.caption2).foregroundStyle(Theme.fgDim)
            .padding(.leading, 52)   // align under the row's text, past the thumbnail
        }
        .padding(.vertical, 2)
    }

    // MARK: - Rewind playback to a point in History (R5b)

    /// "Rewind to here" on a History row: pick the set back up from that play and run forward
    /// through everything that followed it, in order.
    ///
    /// Two cases, and the difference matters. If the tapped play is still in the RUNNING queue,
    /// this is the same cursor move the Now Playing deck offers — no rebuild, the live set keeps
    /// its identity and its edits. If it's from a past run, there is no queue to move a cursor in,
    /// so the run is reconstructed from the log: the contiguous slice of plays that shared this
    /// one's context, starting at it. That slice IS the tail of the old set as it actually played.
    @ViewBuilder private func rewindMenuItem(eventId: UUID) -> some View {
        if let e = history.events.first(where: { $0.id == eventId }) {
            Button {
                rewindTarget = e
            } label: {
                Label("Rewind to here", systemImage: "backward.end.fill")
            }
            .accessibilityIdentifier("history-rewind-\(e.songId)")
        }
    }

    /// The slice a past-run rewind plays: this event and every later play that shared its context,
    /// in order, stopping at the first play from a DIFFERENT context (that's a different set).
    /// Pure + testable — no view state, no player.
    static func rewindSlice(from eventId: UUID,
                            in events: [PlayHistoryStore.PlayEvent]) -> [PlayHistoryStore.PlayEvent] {
        guard let start = events.firstIndex(where: { $0.id == eventId }) else { return [] }
        let context = events[start].contextId
        var out: [PlayHistoryStore.PlayEvent] = []
        for e in events[start...] {
            guard e.contextId == context else { break }
            out.append(e)
        }
        return out
    }

    /// A rewind ALWAYS confirms — it is never silent.
    ///
    /// The obvious gate would be `sequencer.isRunning`, and it is wrong. History is the default
    /// landing tab and is interactive during the launch sync window, BEFORE the durable-session
    /// restore runs; `isRunning` is false there, so an isRunning-gated confirmation would vanish
    /// exactly when a restored set is most at risk of being replaced before it has even been
    /// rehydrated. (`PlaybackSessionStore` isn't `@Observable`, so a view can't cheaply ask whether
    /// a snapshot exists either.) Always asking costs one tap and closes the hole.
    private var rewindReplacesLiveSet: Bool { sequencer.isRunning }

    /// Execute a rewind. Re-reads the event by id at execute time rather than trusting the value
    /// captured when the menu was built — a cloud pull can merge new rows in underneath an open
    /// menu, and the confirmation dialog gives it a whole extra window to happen.
    private func performRewind(_ target: PlayHistoryStore.PlayEvent) {
        guard let e = history.events.first(where: { $0.id == target.id }) else { return }
        // SAME RUN: a pure cursor move, so the live set keeps its identity, its edits, and its
        // origin. Matching on the LAST played row with this song id — a song can repeat in a set,
        // and the most recent occurrence is the one the user is looking at.
        if sequencer.isRunning, let uid = sequencer.played.last(where: { $0.id == e.songId })?.uid {
            sequencer.jumpToPlayed(uid: uid)
            return
        }
        // PAST RUN: rebuild from the log. `playSongIds` is the right door — it already does the
        // onboarding veto and awaits `ensureReady()`, so a rewind can't fire against an empty
        // catalog and mint a corrupt Now Playing setlist. The slice starts AT the tapped event, so
        // playback begins there with no start-index parameter needed.
        let slice = Self.rewindSlice(from: e.id, in: history.events)
        guard !slice.isEmpty else { return }
        let name = e.contextName ?? "History"
        Task {
            try? await intents.playSongIds(slice.map(\.songId), name: name, source: e.source)
        }
    }

    private func contextLabel(_ play: PlayRef) -> String {
        var label = play.source.label
        if let name = play.contextName, !name.isEmpty { label += " · \(name)" }
        // History is merged across devices now, so a row can be something you played elsewhere.
        // Saying so is the difference between "useful" and "why is that there?".
        if play.fromAnotherDevice { label += " · on another device" }
        return label
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Sort/filter drive the Playback timeline only — hidden on For You and Collection.
            if tab == .playback {
                if selecting {
                    // Select-all / deselect-all — the touch-reachable equivalent of ⌘A/⌃A. "Select
                    // all" is the WHOLE filtered universe (`displayedSongs`, the full `displayItems`,
                    // not just the rendered page), so its count reflects rows not yet scrolled in.
                    Menu {
                        Button { selectAllMatching() } label: {
                            Label("Select all (\(displayedSongs.count))", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("history-select-all")
                        Button { rowSelection.deselectAll() } label: {
                            Label("Deselect all", systemImage: "circle")
                        }
                        .disabled(!rowSelection.hasSelection)
                        .accessibilityIdentifier("history-deselect-all")
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityIdentifier("history-select-menu")
                    // Share stays History's own action (the shared SelectionBar carries Copy /
                    // Add to… / Clear): it exports one "Title — Artist + links" block per song.
                    ShareLink(item: ShareText.forSongs(selectedSongs),
                              subject: Text("\(rowSelection.count) songs")) {
                        Label("Share (\(rowSelection.count))", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!rowSelection.hasSelection)
                    .accessibilityIdentifier("history-share-selected")
                    Button("Done") { rowSelection.clearAndExit() }
                        .accessibilityIdentifier("history-select-done")
                } else {
                    Button {
                        rowSelection.enterSelectMode(scope: Self.selectionScope, initial: nil)
                    } label: { Image(systemName: "checklist") }
                        .help("Select songs to share, copy, or add to a collection")
                        .accessibilityIdentifier("history-select")
                    Button { showSort = true } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityIdentifier("history-sort")
                    Button { showFilter = true } label: {
                        Image(systemName: browse.activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("history-filter")
                }
            } else if tab == .forYou {
                // THE For You MENU. The tab is CACHED — it renders the last ranking that was
                // computed and does not move on its own — so this is the one control that asks
                // for a new one. A standard iOS Menu, not a bare button, because it is the place
                // any future For You-wide action belongs.
                Menu {
                    Button { forYouRefreshToken &+= 1 } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("foryou-refresh")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Recompute your For You tiles")
                .accessibilityIdentifier("foryou-menu")
            } else if canBackfill {
                // Collection shows your ADDs — offer to (re)send the recent ones to the Apple
                // Music playlists they came from, for adds that never made it upstream (added
                // before write-back shipped, or while offline / signed out). The look-back window
                // is the one configured in Settings ▸ Apple Music (default 2 days).
                Button { runBackfill() } label: { Image(systemName: "arrow.up.circle") }
                    .accessibilityIdentifier("history-writeback-backfill")
            }
        }
    }

    /// Only offer the backfill where a write-back can actually land: this device can write to
    /// Apple Music (iOS/visionOS, not macOS) AND at least one collection came from an Apple Music
    /// source. Otherwise there is nothing to push and the button would be a dead end.
    private var canBackfill: Bool {
        writeBack?.canWriteBack == true && appleMusicLinkedCount > 0
    }
    private var appleMusicLinkedCount: Int {
        collections.pockets.filter { $0.hasSource && PlaylistWriteBack.isAppleMusicSource($0.sourceName ?? "") }.count +
        collections.playlists.filter { $0.hasSource && PlaylistWriteBack.isAppleMusicSource($0.sourceName ?? "") }.count
    }

    /// Re-drive the Apple Music write-back for the configured look-back window and report the
    /// count. Idempotent (the queue dedups) — tapping twice reports nothing new the second time.
    private func runBackfill() {
        let days = settings.writeBackBackfillDays
        let n = collections.backfillSourceWriteBacks(from: activity.events, days: days,
                                                     localInstallId: activity.installId)
        let window = "the last \(days) day\(days == 1 ? "" : "s")"
        backfillMessage = n == 0
            ? "Everything you added to your Apple Music collections in \(window) is already in Apple Music."
            : "Sending \(n) song\(n == 1 ? "" : "s") from \(window) to your Apple Music playlists."
    }

    /// Hidden shortcut buttons (mirrors BrowseView): ⌥⌘F filter, ⌥⌘S sort within History.
    private var shortcuts: some View {
        Group {
            Button("HistoryFilter-shadow") { showFilter = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("HistorySort-shadow") { showSort = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
            // ⌃A — select every song matching the current filters/sort. ⌘A is NOT registered
            // here any more: RootView's shared `SelectAllSongs-shadow` owns it for whichever
            // list is registered (History's, while the Playback tab is up), and two live
            // registrations of one key resolve ambiguously on macOS.
            Button("HistorySelectAll-ctrl") { selectAllMatching() }
                .keyboardShortcut("a", modifiers: .control)
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    // MARK: - Multi-select (shared RowSelection, Playback tab)

    /// One scope for History's play rows. Everything RowSelection does is keyed on it, which
    /// is what keeps arming Select here from intercepting taps in Browse or a collection.
    static let selectionScope = "history-plays"

    /// The selection bar / select-mode toolbar shows while a History selection (or Select
    /// mode) is live in THIS scope.
    private var selecting: Bool { rowSelection.isActive(in: Self.selectionScope) }

    /// Every DISTINCT song currently matching the filters/sort (the displayed set), in order — the
    /// universe ⌘A selects and that Share exports from.
    private var displayedSongs: [IndexSong] { Self.distinctSongs(browse.displayItems) }
    /// Same universe as ids: the range/select-all id space (deduped, display order).
    private var displayedSongIds: [String] { displayedSongs.map(\.id) }

    /// Dedupe the History rows (one per PLAY) down to one entry per song, preserving display
    /// order. Pure + static so it's unit-testable without a view host.
    static func distinctSongs(_ items: [BrowseItem]) -> [IndexSong] {
        var seen = Set<String>(); var out: [IndexSong] = []
        for item in items {
            if case .song(let song, _, _, _, _) = item, seen.insert(song.id).inserted { out.append(song) }
        }
        return out
    }

    /// The selected songs in displayed order (deduped — History rows are one-per-event).
    private var selectedSongs: [IndexSong] {
        displayedSongs.filter { rowSelection.isSelected($0.id, scope: Self.selectionScope) }
    }

    /// The ordered selection as a transfer payload — what Copy, the bar's Add to…, and a
    /// multi-row drag all serialize.
    private func selectionPayload() -> SongTransfer? {
        let ordered = rowSelection.orderedSelection(in: displayedSongIds)
        guard !ordered.isEmpty else { return nil }
        return SongTransfer.make(ids: ordered, songsById: app.songsById)
    }
    private func dragPayload(for song: IndexSong) -> SongTransfer {
        rowSelection.payloadForRow(song.id, scope: Self.selectionScope,
                                   single: SongTransfer.make(ids: [song.id], songsById: app.songsById))
    }

    /// ⌃A / the toolbar's "Select all" — select every song matching the current filters, and
    /// arm Select mode so the next plain tap toggles instead of navigating (the touch path).
    /// Playback only.
    private func selectAllMatching() {
        guard tab == .playback else { return }
        rowSelection.enterSelectMode(scope: Self.selectionScope, initial: nil)
        rowSelection.selectAll()
    }

    // MARK: - Base rows from the event log

    /// Build the `[BrowseItem]` + parallel search keys the filter/sort engine works over.
    /// Timeline: one row per event. Group-by-song: one row per song (latest event as the
    /// representative, with a play count). Called on the main actor (reads the catalog), then
    /// the pure filter/sort runs off-main.
    private func buildItems() -> (base: [BrowseItem], keys: [String]) {
        var items: [BrowseItem] = []
        var keys: [String] = []
        if groupBySong {
            var latest: [String: PlayHistoryStore.PlayEvent] = [:]
            var counts: [String: Int] = [:]
            var order: [String] = []
            for e in history.events {
                counts[e.songId, default: 0] += 1
                if let cur = latest[e.songId] {
                    if e.playedAt >= cur.playedAt { latest[e.songId] = e }
                } else {
                    latest[e.songId] = e
                    order.append(e.songId)
                }
            }
            for sid in order {
                guard let e = latest[sid] else { continue }
                let (item, key) = makeRow(e, count: counts[sid] ?? 1)
                items.append(item); keys.append(key)
            }
        } else {
            items.reserveCapacity(history.events.count)
            keys.reserveCapacity(history.events.count)
            for e in history.events {
                let (item, key) = makeRow(e, count: 1)
                items.append(item); keys.append(key)
            }
        }
        return (items, keys)
    }

    private func makeRow(_ e: PlayHistoryStore.PlayEvent, count: Int) -> (BrowseItem, String) {
        // Resolve the live catalog song; fall back to the event's snapshot when the song has
        // left the catalog, so history stays readable.
        let song = app.songsById[e.songId]
            ?? IndexSong.minimal(id: e.songId, name: e.title ?? "Unknown", artist: e.artist ?? "")
        let album = app.album(forSongId: e.songId)
        let albumName = album?.name ?? ""
        let play = PlayRef(eventId: e.id, playedAt: e.playedAt, source: e.source,
                           contextName: e.contextName, count: count,
                           fromAnotherDevice: history.isFromAnotherDevice(e))
        let item = BrowseItem.song(song, albumName: albumName, source: app.source(ofSong: e.songId),
                                   genre: Genre.category(album?.genre), play: play)
        let key = (song.name + "\n" + song.artist + "\n" + albumName)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return (item, key)
    }

    // MARK: - Relative time

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ epochMs: Double) -> String {
        relativeFormatter.localizedString(for: Date(timeIntervalSince1970: epochMs / 1000), relativeTo: Date())
    }
}

/// Registers History's Playback rows as the window's ACTIVE selectable list (so ⌘A / ⌘C /
/// the bar's Add to… act on them), prunes a live selection when the result set changes, and
/// parks the ⌘A shadow while the search field has focus.
///
/// A ViewModifier rather than four more chain entries on `HistoryView.body`: that chain is at
/// the type-checker's budget (the file says so twice), and this is the same extraction
/// `CollectionSelectionChrome` is for. `active` is "the Playback tab is showing" — For You and
/// Collection have no selectable song rows, so registering there would point ⌘A at rows that
/// aren't on screen.
private struct HistorySelectionWiring: ViewModifier {
    @Environment(RowSelection.self) private var selection
    let scope: String
    let active: Bool
    /// Cheap stand-in for "the result set changed" (the full id list is expensive to build on
    /// every render — History can hold tens of thousands of events).
    let pagingKey: String
    let allIds: () -> [String]
    let payload: () -> SongTransfer?
    let searchFocused: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: active) { sync() }
            .onChange(of: pagingKey) {
                guard selection.scopeId == scope, selection.hasSelection else { return }
                selection.prune(validIds: Set(allIds()))
            }
            .onChange(of: searchFocused) { _, focused in selection.textEntryFocused = focused }
            .onDisappear {
                selection.unregisterActiveList(scope: scope)
                selection.textEntryFocused = false   // never leave ⌘A suspended by stale focus
            }
    }

    private func sync() {
        guard active else { selection.unregisterActiveList(scope: scope); return }
        selection.registerActiveList(scope: scope, allIds: allIds, payload: payload)
    }
}
