import SwiftUI

/// History mode — a scrollable timeline of what you've done: every song you've played (in whichever
/// Mix / Playlist / Pocket / Set list / Browser it happened in) AND every collection change (adding
/// a song, hearting/unhearting, removing), with the Browser's filter + sort controls on the plays.
/// Opened from anywhere with ⌘H.
///
/// Three views over two event streams:
///  • **Playback** — song PLAYS from the append-only `PlayHistoryStore`, driven through the Browser's
///    own filter/sort/paged machinery (see `BrowseState.refreshExternal`, which runs off the main actor).
///  • **Collection** — collection ACTIVITY (add / heart / unheart / remove) from `CollectionActivityStore`.
///  • **Unified** (default) — both streams interleaved newest-first.
///
/// The tab control shows the TWO views you're NOT currently in — tap one to switch. So from Unified you
/// see [Playback | Collection]; from either single view you see [the other | Unified] to cross over or
/// return to the combined timeline.
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
    @Binding var path: NavigationPath

    enum HistoryTab: String, CaseIterable {
        case unified = "Unified", playback = "Playback", collection = "Collection"
        var symbol: String {
            switch self {
            case .unified:    return "square.stack.3d.up.fill"
            case .playback:   return "play.circle.fill"
            case .collection: return "rectangle.stack.fill"
            }
        }
    }
    @State private var tab: HistoryTab = .unified
    /// The History row a rewind is pending on — nil unless the confirmation is up.
    @State private var rewindTarget: PlayHistoryStore.PlayEvent?

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
    /// Multi-select share (Playback tab): whether we're selecting, and the chosen song ids. Tap a
    /// row to toggle; the select-mode menu's "Select all" / "Deselect all" (touch-reachable) or
    /// ⌘A / ⌃A select every song matching the current filters/sort — the WHOLE filtered universe,
    /// not just the loaded page; Share exports one "Title — Artist + links" block per distinct song.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// Result of a manual write-back backfill (the "send my adds to Apple Music" toolbar action),
    /// shown in a one-off alert. nil ⇒ no alert.
    @State private var backfillMessage: String?
    /// On-device incremental rendering budget — History can grow to tens of thousands of
    /// events, so (exactly like the Browser) only a growing PREFIX of the filtered+sorted rows
    /// is handed to ForEach; it grows as the last visible row appears. Paired with the
    /// `recomputeSignature` it was grown against so a filter/sort/mode change restarts paging.
    @State private var visibleCount = BrowsePaging.pageSize
    @State private var visibleKey = ""

    /// The merged Unified timeline (newest-first), rebuilt off `unifiedSignature`. Kept in state
    /// (not a computed property) so the O(n) merge+sort runs only when its inputs change, and only
    /// while the Unified tab is showing.
    @State private var unified: [HistoryEntry] = []
    @State private var uVisibleCount = BrowsePaging.pageSize
    @State private var uVisibleKey = ""

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

    /// Unified rebuilds when the catalog, either event stream, the search query, or the tab changes
    /// (the tab is included so switching TO Unified triggers a build; the build no-ops for other tabs).
    private var unifiedSignature: String {
        "\(tab)-\(app.catalogRevision)-\(history.revision)-\(activity.revision)-\(browse.query)"
    }
    private var unifiedPagingKey: String { "\(history.revision)-\(activity.revision)-\(browse.query)-\(unified.count)" }
    private var liveUnifiedVisible: Int { uVisibleKey == unifiedPagingKey ? uVisibleCount : BrowsePaging.pageSize }

    var body: some View {
        content
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $browse.query, prompt: "Search title or artist")
            .toolbar { toolbar }
            .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app, collections: collections) }
            .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
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
            .task(id: unifiedSignature) {
                guard tab == .unified else { return }
                unified = buildUnified()
            }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            tabBar
            switch tab {
            case .unified:
                unifiedContent
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
                activityContent
            }
        }
        // Match every other tab's dark-blue canvas (the Lists are made transparent via
        // .scrollContentBackground(.hidden), so this shows through instead of the system black).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Tab control (two destinations = the views you're NOT in)

    private var altTabs: [HistoryTab] {
        switch tab {
        case .unified:    return [.playback, .collection]
        case .playback:   return [.collection, .unified]
        case .collection: return [.playback, .unified]
        }
    }

    /// Custom two-button control (not a segmented `Picker`) so it renders prominently and identically
    /// on iOS, macOS, and visionOS. Each button is a destination; tapping switches the view and the
    /// pair re-renders to the two views you can now reach.
    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(altTabs, id: \.self) { t in
                Button {
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
                // bgOverlay (not bgRaised) + a stronger accent stroke so the toggle stands out
                // against the dark-blue Theme.bg canvas (bgRaised is nearly bg — too low-contrast).
                .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
                )
                .accessibilityIdentifier("history-tab-\(t.rawValue.lowercased())")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        // NB: no container accessibilityIdentifier here — a parent id absorbs the child buttons'
        // identifiers and makes `history-tab-<mode>` unqueryable in XCUITest.
    }

    // MARK: - Unified timeline (plays + activity interleaved)

    @ViewBuilder private var unifiedContent: some View {
        if unified.isEmpty {
            unifiedEmptyState
        } else {
            let page = Array(unified.prefix(liveUnifiedVisible))
            List {
                ForEach(page) { entry in
                    unifiedRow(entry)
                        .onAppear { onUnifiedRowAppear(entry, rendered: page) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func unifiedRow(_ entry: HistoryEntry) -> some View {
        switch entry {
        case .play(let eventId, let song, let play):
            row(song: song, play: play)
                .contentShape(Rectangle())
                .onTapGesture { path.append(song) }
                .contextMenu { rewindMenuItem(eventId: eventId) }
        case .activity(let e):
            activityRow(e)
                .contentShape(Rectangle())
                .onTapGesture { openActivityItem(e) }
        }
    }

    /// Merge plays + activity into one newest-first timeline, filtered by the search query
    /// (title/artist for plays; item title + collection name for activity). Runs on the main actor
    /// (reads the catalog); paged on render, so only a prefix is ever materialized into rows.
    private func buildUnified() -> [HistoryEntry] {
        let q = browse.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var entries: [HistoryEntry] = []
        entries.reserveCapacity(history.events.count + activity.events.count)
        for e in history.events {
            let (item, key) = makeRow(e, count: 1)
            guard case .song(let song, _, _, _, let play) = item, let play else { continue }
            if q.isEmpty || key.contains(q) {
                entries.append(.play(eventId: e.id, song: song, play: play))
            }
        }
        for ev in activity.events where q.isEmpty || activitySearchKey(ev).contains(q) {
            entries.append(.activity(ev))
        }
        entries.sort { $0.at > $1.at }
        return entries
    }

    private func onUnifiedRowAppear(_ entry: HistoryEntry, rendered: [HistoryEntry]) {
        guard entry.id == rendered.last?.id, liveUnifiedVisible < unified.count else { return }
        uVisibleCount = BrowsePaging.grow(liveUnifiedVisible, upTo: unified.count)
        uVisibleKey = unifiedPagingKey
    }

    private var unifiedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text(history.events.isEmpty && activity.events.isEmpty ? "No history yet" : "Nothing matches your search")
                .font(.headline).foregroundStyle(Theme.fg)
            Text("Songs you play — and changes you make to your collections (adds, hearts, removals) — show up here together.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("history-unified-empty")
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
    /// on the way to "Amy") match the whole log, and Unified filters plays on title/artist/album
    /// only, so such a query would return every activity row and zero plays.
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
                    HStack(spacing: 10) {
                        if selecting {
                            Image(systemName: selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selection.contains(song.id) ? Theme.accent : Theme.fgDim)
                        }
                        row(song: song, play: play)
                    }
                    .contentShape(Rectangle())
                    // Select mode: tap toggles the song; otherwise open its detail.
                    .onTapGesture { if selecting { toggleSelect(song.id) } else { path.append(song) } }
                    .onAppear { onRowAppear(item, rendered: page, fullCount: items.count) }
                    // Single-row share (works in either mode) — right-click / long-press.
                    .contextMenu {
                        ShareLink(item: ShareText.forSong(song)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
            // Sort/filter drive the Playback timeline only — hidden on Unified and Collection.
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
                        Button { selection = [] } label: {
                            Label("Deselect all", systemImage: "circle")
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("history-deselect-all")
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityIdentifier("history-select-menu")
                    ShareLink(item: ShareText.forSongs(selectedSongs),
                              subject: Text("\(selection.count) songs")) {
                        Label("Share (\(selection.count))", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("history-share-selected")
                    Button("Done") { selecting = false; selection = [] }
                        .accessibilityIdentifier("history-select-done")
                } else {
                    Button { selecting = true } label: { Image(systemName: "checklist") }
                        .help("Select songs to share")
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
            } else if canBackfill {
                // Collection + Unified show your ADDs — offer to (re)send the recent ones to the
                // Apple Music playlists they came from, for adds that never made it upstream (added
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
            // ⌘A / ⌃A — select every song matching the current filters/sort (enters select mode).
            // Both accelerators map to select-all-matching, per the spec.
            Button("HistorySelectAll-cmd") { selectAllMatching() }
                .keyboardShortcut("a", modifiers: .command)
            Button("HistorySelectAll-ctrl") { selectAllMatching() }
                .keyboardShortcut("a", modifiers: .control)
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    // MARK: - Multi-select share (Playback tab)

    private func toggleSelect(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Every DISTINCT song currently matching the filters/sort (the displayed set), in order — the
    /// universe ⌘A selects and that Share exports from.
    private var displayedSongs: [IndexSong] {
        var seen = Set<String>(); var out: [IndexSong] = []
        for item in browse.displayItems {
            if case .song(let song, _, _, _, _) = item, seen.insert(song.id).inserted { out.append(song) }
        }
        return out
    }

    /// The selected songs in displayed order (deduped — History rows are one-per-event).
    private var selectedSongs: [IndexSong] { displayedSongs.filter { selection.contains($0.id) } }

    /// ⌘A / ⌃A — select every song matching the current filters (enters select mode). Playback only.
    private func selectAllMatching() {
        guard tab == .playback else { return }
        selecting = true
        selection = Set(displayedSongs.map(\.id))
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

/// A single row in the unified History timeline: either a song play (reusing the play row) or a
/// collection-activity event, each carrying its own timestamp for the merge sort.
private enum HistoryEntry: Identifiable {
    case play(eventId: UUID, song: IndexSong, play: PlayRef)
    case activity(CollectionActivityStore.ActivityEvent)

    var id: String {
        switch self {
        case .play(let eid, _, _): return "p:\(eid.uuidString)"
        case .activity(let e):     return "a:\(e.id.uuidString)"
        }
    }
    var at: Double {
        switch self {
        case .play(_, _, let p): return p.playedAt
        case .activity(let e):   return e.at
        }
    }
}
