import SwiftUI
import UniformTypeIdentifiers

// NOTE: The PocketsView list (create/import/list) has been merged into PlaylistsView.
// This file retains only PocketDetailView (the per-pocket detail) and its helpers,
// which are still navigated to from the merged list via .navigationDestination(for: Pocket.self).

/// One pocket's members: songs, albums, and nested child pockets.
struct PocketDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(FavoritesStore.self) private var favorites
    /// Optional like the other app-scoped services: always injected, but a preview/test host
    /// rendering this standalone should degrade rather than trap.
    @Environment(PlaylistAppleMusicSync.self) private var playlistSync: PlaylistAppleMusicSync?
    @Environment(RowSelection.self) private var rowSelection
    @Environment(\.dismiss) private var dismiss
    let pocketId: String
    @Binding var path: NavigationPath
    /// Per-collection sort/filter (keyed by pocket id → remembered per pocket, on-device).
    @State private var browse: BrowseState
    @State private var showSort = false
    @State private var showFilter = false

    init(pocketId: String, path: Binding<NavigationPath>) {
        self.pocketId = pocketId
        self._path = path
        self._browse = State(initialValue: BrowseState(persistenceKey: "pdj.collection.\(pocketId)"))
    }
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingDelete = false
    @State private var showExporter = false
    @State private var exportDoc = PlaylistZipFile(data: Data())
    @State private var showFormatDialog = false
    @State private var showCSVExporter = false
    @State private var csvDoc = CSVFile(data: Data())
    @State private var addingNote = false
    @State private var noteDraft = ""
    @State private var editingNoteId: String?
    @State private var ripBurn = CollectionRipBurnController()
    /// CRITIC-B: don't stack a duplicate Now Playing SetlistDetailView (see PlaylistDetailView).
    @State private var nowPlayingPushed = false
    /// Feedback for the manual "Sync from source now" action (nil = no alert showing).
    @State private var syncResult: String?
    /// "Link to Apple Music playlist…" picker + its confirmation (rescues an unlinked pocket).
    @State private var showLinkPicker = false
    @State private var linkResult: String?

    private var pocket: Pocket? { collections.pocket(pocketId) }

    /// A catalog-song row in the pocket's Songs section (selectable/draggable row + inline
    /// player + swipe-remove). `selectableSongRow` replaces the old NavigationLink — plain
    /// tap still opens the song; modifier-clicks / Select mode multi-select; the row is the
    /// drag source. Select/Copy fold into the SAME force-sync context menu (one-menu rule).
    @ViewBuilder private func pocketSongRow(_ song: IndexSong) -> some View {
        VStack(spacing: 0) {
            CollectionSongRow(song: song, syncsToSource: collections.pocket(pocketId)?.syncsWithSource ?? false,
                              cleanOnlyCollection: pocket?.cleanOnly == true)
                // reorderHost: this ForEach owns .onMove — the drag source attaches only to
                // selected rows so plain row-drags still reorder (macOS's only reorder path).
                .selectableSongRow(id: song.id, scope: selectionScope, reorderHost: true,
                                   orderedIds: { displayedSongIds() },
                                   payload: { dragPayload(for: song) },
                                   onOpen: { path.append(song) })
                .forceSyncContextMenu(song: song, kind: .pocket, collectionId: pocketId) {
                    Button { rowSelection.enterSelectMode(scope: selectionScope, initial: song.id) } label: {
                        Label("Select", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("select-pocket-song-\(song.id)")
                    Button { rowSelection.copyRowOrSelection(rowId: song.id, scope: selectionScope,
                        single: SongTransfer.make(ids: [song.id], songsById: app.songsById)) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("copy-pocket-song-\(song.id)")
                }
            InlinePlayerSlot(songId: song.id)
        }
        // Clean-versions-only skip indicator (see the PlaylistsView twin): a row this
        // pocket would SKIP at ▶ Play dims. Styling only, no new a11y id.
        .opacity(pocket?.cleanOnly == true && CleanOnly.isSkipped(song) ? 0.45 : 1)
        .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(song.id, fromPocket: pocketId) } }
    }

    /// A studio (sample/loop/pattern/take) row — performance items ride songIds but aren't in the catalog.
    @ViewBuilder private func pocketStudioRow(_ sid: String) -> some View {
        StudioCollectionRow(
            id: sid,
            repeatCount: collections.repeatCount(forSong: sid, inPocket: pocketId),
            onSetRepeat: { collections.setSongRepeat(sid, count: $0, inPocket: pocketId) },
            onRemove: { collections.removeSong(sid, fromPocket: pocketId) })
        .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(sid, fromPocket: pocketId) } }
    }

    /// Apple Music source playlists this unlinked pocket could be linked to (the only sources
    /// write-back can push to). Name-ordered.
    private var linkableSources: [SourcePlaylist] {
        app.indexPlaylists
            .filter { PlaylistWriteBack.isAppleMusicSource($0.sourceName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var hasSongs: Bool { !collections.songIds(forPocket: pocketId).isEmpty }

    // MARK: Multi-select (song-id keys; studio members stay outside the selection)

    private var selectionScope: String { "pocket-\(pocketId)" }

    /// The pocket's CATALOG songs in display order (stored order, or the sorted/filtered
    /// Browse pipeline when a per-pocket sort/filter is active) — the range/⌘A universe.
    private func displayedSongIds() -> [String] {
        guard let pocket else { return [] }
        if browse.sortKeys.isEmpty && browse.activeFilterCount == 0 {
            return pocket.songIds.filter { app.songsById[$0] != nil }
        }
        return app.sortedFilteredSongs(ids: pocket.songIds, browse: browse,
                                       collections: collections, favorites: favorites).map(\.id)
    }
    private func selectionPayload() -> SongTransfer? {
        let ids = rowSelection.orderedSelection(in: displayedSongIds())
        guard !ids.isEmpty else { return nil }
        return SongTransfer.make(ids: ids, songsById: app.songsById)
    }
    private func dragPayload(for song: IndexSong) -> SongTransfer {
        rowSelection.payloadForRow(song.id, scope: selectionScope,
            single: SongTransfer.make(ids: [song.id], songsById: app.songsById))
    }
    private func acceptDrop(_ items: [SongTransfer]) -> Bool {
        // Studio ids RESOLVE through studioLookup (the id must be backed by a real item on
        // this device) — a bare prefix test would persist any foreign "smp_…" string from
        // the cross-process pasteboard into the cloud-synced document.
        let ids = SongDrop.acceptableIds(items) { app.songsById[$0] != nil || collections.studioLookup?($0) != nil }
        guard !ids.isEmpty else { return false }
        return collections.addSongs(ids, to: AddTarget(kind: .pocket, id: pocketId)) > 0
    }

    // Split into memberList (the List) + chromeApplied (the toolbar/alert/dialog chain):
    // one combined expression exceeded the type-checker's budget once the source-sync
    // menu + alert joined the toolbar.
    var body: some View {
        chromeApplied
    }

    private var memberList: some View {
        List {
            if let pocket {
                Section {
                    let stats = collections.stats(forPocket: pocketId)
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack").foregroundStyle(Theme.accent)
                        Text(stats.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                        Spacer()
                    }
                    .accessibilityIdentifier("pocket-stats")
                } footer: {
                    Text("Total resolved songs (own + album tracks + nested pockets, deduped). Runtime sums known track lengths.")
                }
                if !pocket.childPocketIds.isEmpty {
                    Section("Nested pockets") {
                        ForEach(pocket.childPocketIds, id: \.self) { cid in
                            if let child = collections.pocket(cid) {
                                NavigationLink(value: child) {
                                    Label(child.name, systemImage: "rectangle.stack")
                                }
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeChildPocket(cid, fromPocket: pocketId) } }
                            }
                        }
                        .onMove { from, to in collections.movePocketChildren(inPocket: pocketId, from: from, to: to) }
                    }
                }
                Section("Albums (\(pocket.albumIds.count))") {
                    ForEach(pocket.albumIds, id: \.self) { aid in
                        if let album = app.albumsById[aid] {
                            NavigationLink(value: album) { AlbumRow(album: album) }
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeAlbum(aid, fromPocket: pocketId) } }
                        }
                    }
                    .onMove { from, to in collections.movePocketAlbums(inPocket: pocketId, from: from, to: to) }
                }
                Section("Songs (\(pocket.songIds.count))") {
                    // DEFAULT order (no sort/filter): the stored order as-is, with drag-reorder.
                    // SORTED/FILTERED: catalog songs via the Browser pipeline (no-dateAdded songs sort
                    // to the END), then studio items pinned at the very end (studio items carry no
                    // song fields, so a FILTER hides them; a plain sort keeps them, last).
                    if browse.sortKeys.isEmpty && browse.activeFilterCount == 0 {
                        ForEach(pocket.songIds, id: \.self) { sid in
                            if let song = app.songsById[sid] { pocketSongRow(song) }
                            else if StudioFactory.isStudioId(sid) { pocketStudioRow(sid) }
                        }
                        .onMove { from, to in collections.movePocketSongs(inPocket: pocketId, from: from, to: to) }
                    } else {
                        ForEach(app.sortedFilteredSongs(ids: pocket.songIds, browse: browse,
                                                        collections: collections, favorites: favorites)) { song in
                            pocketSongRow(song)
                        }
                        if browse.activeFilterCount == 0 {
                            ForEach(pocket.songIds.filter { StudioFactory.isStudioId($0) }, id: \.self) { sid in
                                pocketStudioRow(sid)
                            }
                        }
                    }
                }
                if !pocket.notes.isEmpty {
                    Section("Notes (\(pocket.notes.count))") {
                        ForEach(pocket.notes) { note in
                            Button {
                                editingNoteId = note.id; noteDraft = note.text
                            } label: {
                                Label(note.text, systemImage: "text.quote")
                                    .foregroundStyle(Theme.fgDim).italic()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pocket-note-\(note.id)")
                            .swipeActions { Button("Remove", role: .destructive) { collections.removeNote(note.id, fromPocket: pocketId) } }
                        }
                        .onMove { from, to in collections.movePocketNotes(inPocket: pocketId, from: from, to: to) }
                    }
                }
                if pocket.isEmpty {
                    Text("Empty. Add songs or albums from their detail view ▸ Add to…, or add a note below.")
                        .foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    private var chromeApplied: some View {
        memberList
        .collectionSortFilterSheets(browse: browse, showSort: $showSort, showFilter: $showFilter,
                                    app: app, collections: collections)
        .navigationTitle(pocket?.name ?? "Pocket")
        .accessibilityIdentifier("pocket-detail")
        // Selection bar + whole-list drop target + paste registration (song-id keys).
        .modifier(CollectionSelectionChrome(scope: selectionScope,
                                            allIds: { displayedSongIds() },
                                            payload: { selectionPayload() },
                                            acceptDrop: { acceptDrop($0) }))
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
        .onAppear { nowPlayingPushed = false }
        // The SHARED `CollectionToolbar` — identical furniture to the playlist screen. Adopting it
        // also fixed a real drift: this screen's ▶/🔀 were bare `Image`s where the playlist's were
        // `Label`s, so VoiceOver read them as unnamed buttons here and named ones there.
        // ▶▶ Play All rides along for the same reason it does on the playlist screen: the owner
        // asked for all three every time, and the two collection screens must not differ from each
        // other OR from the tile screens. A pocket has no sunk tail, so ▶▶ is ▶ — accepted.
        .collectionToolbar(idPrefix: "pocket", noun: "pocket", canPlay: hasSongs,
                           play: { play(shuffle: $0) },
                           playAll: { play(shuffle: false) },
                           menuItems: { overflowMenu })
        .alert("Add note", isPresented: $addingNote) {
            TextField("Note (a line of poetry, a cue…)", text: $noteDraft)
            Button("Add") {
                let n = noteDraft.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { collections.addNote(n, toPocket: pocketId) }
                noteDraft = ""
            }
            Button("Cancel", role: .cancel) { noteDraft = "" }
        }
        .alert("Edit note", isPresented: Binding(get: { editingNoteId != nil }, set: { if !$0 { editingNoteId = nil } })) {
            TextField("Note", text: $noteDraft)
            Button("Save") {
                if let nid = editingNoteId {
                    let n = noteDraft.trimmingCharacters(in: .whitespaces)
                    if n.isEmpty { collections.removeNote(nid, fromPocket: pocketId) }
                    else { collections.setNoteText(nid, text: n, inPocket: pocketId) }
                }
                editingNoteId = nil
            }
            Button("Remove", role: .destructive) {
                if let nid = editingNoteId { collections.removeNote(nid, fromPocket: pocketId) }
                editingNoteId = nil
            }
            Button("Cancel", role: .cancel) { editingNoteId = nil }
        }
        .alert("Sync from source", isPresented: syncResultShowing) {
            Button("OK") { syncResult = nil }
        } message: {
            Text(syncResult ?? "")
        }
        .sheet(isPresented: $showLinkPicker) {
            LinkSourceSheet(sources: linkableSources, pocketName: pocket?.name ?? "") { sp in
                showLinkPicker = false
                collections.linkPocketToSource(pocketId, source: sp)
                linkResult = "“\(pocket?.name ?? "This pocket")” is now linked to “\(sp.name)”. Songs you add to it will be added to that Apple Music playlist too. To send ones you already added, use Settings ▸ Apple Music ▸ Syncing ▸ “Send to Apple Music” (or the ↑ button on History ▸ Collection)."
            }
        }
        .alert("Linked to Apple Music", isPresented: Binding(
            get: { linkResult != nil }, set: { if !$0 { linkResult = nil } })) {
            Button("OK") { linkResult = nil }
        } message: { Text(linkResult ?? "") }
        .alert("Rename pocket", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePocket(pocketId, n) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this pocket?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete pocket", role: .destructive) { collections.deletePocket(pocketId); dismiss() }
                .accessibilityIdentifier("delete-pocket-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the pocket and unnests it from any parent. Its items aren't deleted. This can't be undone.")
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .pocketDJCollection,
                      defaultFilename: exportFilename) { _ in }
        .fileExporter(isPresented: $showCSVExporter, document: csvDoc, contentType: .commaSeparatedText,
                      defaultFilename: csvFilename) { _ in }
        .confirmationDialog("Export pocket", isPresented: $showFormatDialog, titleVisibility: .visible) {
            Button("PocketDJ (full metadata)") { exportPocketDJ() }.accessibilityIdentifier("export-format-pocketdj")
            Button("CSV (tracklist)") { exportCSV() }.accessibilityIdentifier("export-format-csv")
        } message: {
            Text("PocketDJ keeps everything (re-importable). CSV is a universal tracklist (title, artist, album, year, genre).")
        }
    }

    /// The ⋯ menu — everything beyond the primary Play/Shuffle, so the compact-width iPhone
    /// toolbar stays at 4 items and never nests a system "More".
    @ViewBuilder private var overflowMenu: some View {
        // Per-pocket sort + filter. Reuses the Browser's sort/filter machinery.
        CollectionSortFilterMenuButtons(browse: browse, showSort: $showSort, showFilter: $showFilter)
        // Multi-select: arm Select mode for this list / paste the copied songs (deduped).
        Button { rowSelection.enterSelectMode(scope: selectionScope, initial: nil) } label: {
            Label("Select songs", systemImage: "checklist")
        }
        .accessibilityIdentifier("select-songs")
        Button { rowSelection.performPaste() } label: {
            Label("Paste songs", systemImage: "doc.on.clipboard")
        }
        .disabled(!SongPasteboard.hasSongs)
        .accessibilityIdentifier("paste-songs")
        Divider()
        Button { noteDraft = ""; addingNote = true } label: { Label("Add note", systemImage: "text.badge.plus") }
            .accessibilityIdentifier("add-pocket-note")
        #if os(iOS)
        EditButton().accessibilityIdentifier("pocket-edit-order")
        #endif
        Button { nameDraft = pocket?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
            .accessibilityIdentifier("rename-pocket")
        Button { showFormatDialog = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("export-pocket")
        if pocket?.hasSource == true {
            sourceSyncMenuItems
        } else if !linkableSources.isEmpty {
            Divider()
            Button { showLinkPicker = true } label: {
                Label("Link to Apple Music playlist…", systemImage: "link")
            }
            .accessibilityIdentifier("pocket-link-source")
        }
        cleanOnlyMenuItem
        Divider()
        CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.ripIds(forPocket: pocketId) }, noun: "pocket")
        Divider()
        Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete pocket", systemImage: "trash") }
            .accessibilityIdentifier("delete-pocket")
    }

    /// Presented-state for the sync-result alert (a computed Binding INSIDE body blew
    /// the type-checker budget for the whole List expression).
    private var syncResultShowing: Binding<Bool> {
        Binding(get: { syncResult != nil }, set: { if !$0 { syncResult = nil } })
    }

    /// Clean-versions-only toggle (see `CleanOnly`): explicit songs play/rip their clean
    /// edition when one is resolved, else are skipped for this pocket.
    @ViewBuilder private var cleanOnlyMenuItem: some View {
        let b = Binding<Bool>(get: { pocket?.cleanOnly == true },
                              set: { collections.setCleanOnly($0, forPocket: pocketId) })
        Toggle(isOn: b) { Label("Clean versions only", systemImage: "c.square") }
            .accessibilityIdentifier("pocket-clean-only")
    }

    /// Source-sync ⋯-menu items — shown only for a pocket converted from a source
    /// playlist (provenance present). Split out of the Menu builder: the inline
    /// Binding + ternary blew the type-checker's budget in the big toolbar expression.
    @ViewBuilder private var sourceSyncMenuItems: some View {
        let syncBinding = Binding<Bool>(
            get: { pocket?.syncsWithSource ?? false },
            set: { collections.setSourceSyncEnabled($0, forPocket: pocketId) })
        // Per-pocket Apple Music sync DIRECTION (Levi 2026-07-29): "Get only" is the smart-
        // playlist setting — the pocket keeps following its source but is never pushed (a push
        // would mint a regular-playlist duplicate, since smart playlists are write-invisible).
        let directionBinding = Binding<CollectionSyncDirection>(
            get: { pocket?.amSyncDir ?? .both },
            set: { collections.setAMSyncDirection($0, forPocket: pocketId) })
        Divider()
        Section(sourceLinkHeader) {
            Picker(selection: directionBinding) {
                ForEach(CollectionSyncDirection.allCases, id: \.self) { d in
                    Text(d.label).tag(d)
                }
            } label: {
                Label("Apple Music sync", systemImage: "arrow.up.arrow.down.circle")
            }
            .accessibilityIdentifier("pocket-am-sync-direction")
            // Send THIS pocket now, without waiting for a whole-library pass. Writes a normal sync
            // report, so it lands in Settings ▸ Apple Music's sync history like any other run.
            // Hidden when the direction gate would refuse the push anyway.
            if let playlistSync, (pocket?.amSyncDir ?? .both).allowsPush {
                Button {
                    Task { await playlistSync.syncCollection(pocketId: pocketId,
                                                             collections: collections, app: app) }
                } label: {
                    // Say WHY it's unavailable — see the note on the playlist twin.
                    Label(playlistSync.isSyncing ? "Syncing… (Apple Music sync running)"
                                                 : "Sync with Apple Music",
                          systemImage: playlistSync.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.up.circle")
                }
                .disabled(playlistSync.isSyncing)
                .accessibilityIdentifier("pocket-am-sync-now")
            }
            Toggle(isOn: syncBinding) {
                Label("Sync with source", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("pocket-sync-toggle")
            Button(action: syncFromSourceNow) {
                Label("Sync from source now", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("pocket-sync-now")
            // Re-link (Levi 2026-07-22): a pocket that converted from a playlist can point at the
            // WRONG playlist or carry a stale membership snapshot, so its adds silently read as
            // "already in the source" and never reach Apple Music. Re-linking re-snapshots the
            // chosen playlist's CURRENT membership, turning the pocket's extra songs back into
            // write-back candidates (then Settings ▸ Apple Music ▸ "Send to Apple Music" pushes them).
            if !linkableSources.isEmpty {
                Button { showLinkPicker = true } label: {
                    Label("Re-link to Apple Music playlist…", systemImage: "link")
                }
                .accessibilityIdentifier("pocket-relink-source")
            }
        }
    }

    /// ⋯-menu header for a linked pocket — names the Apple Music playlist it's tied to so the user
    /// can eyeball whether the linkage is correct. Falls back when the source isn't loaded.
    private var sourceLinkHeader: String {
        if let name = collections.sourcePlaylist(forPocket: pocketId)?.name {
            return "Linked to “\(name)”"
        }
        return "Apple Music link"
    }

    /// Manual sync + user feedback (runs regardless of the auto-sync toggles).
    private func syncFromSourceNow() {
        if collections.syncPocketFromSourceNow(pocketId) {
            let source = pocket?.sourceName ?? "source"
            syncResult = "Updated from \(source)."
        } else if collections.sourcePlaylist(forPocket: pocketId) == nil {
            syncResult = "Source playlist not available (check the source is enabled and loaded)."
        } else {
            syncResult = "Already in sync."
        }
    }

    /// `<sanitized name>.pocket.pdjcollection` — the extension is written EXPLICITLY (see the
    /// PlaylistsView note: `.fileExporter` doesn't reliably append a custom type's extension
    /// on-device). The `.pdjcollection` tail = com.pocketdj.collection → tap-to-open + selectable.
    private var exportFilename: String {
        let base = (pocket?.name ?? "pocket")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "pocket" : base).pocket.pdjcollection"
    }

    /// `<sanitized name>.csv` — the universal tracklist filename. The `.csv` is written EXPLICITLY
    /// (like `.pdjcollection` above): `.fileExporter` doesn't reliably append even a standard type's
    /// extension on-device, so it shipped bare, extension-less files.
    private var csvFilename: String {
        let base = (pocket?.name ?? "pocket")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "pocket" : base).csv"
    }

    private func exportPocketDJ() {
        if let data = try? collections.exportPocketZip(pocketId) {
            exportDoc = PlaylistZipFile(data: data); showExporter = true
        }
    }

    private func exportCSV() {
        if let data = collections.exportPocketCSV(pocketId) {
            csvDoc = CSVFile(data: data); showCSVExporter = true
        }
    }

    /// ▶ Play / 🔀 Shuffle: snapshot the pocket's resolved (DAG) songs into the reusable
    /// "Now Playing" setlist and open it autostarting. CRITIC-B no-duplicate-push guard.
    private func play(shuffle: Bool) {
        collections.playNow(pocketId: pocketId, shuffle: shuffle)
        // Donate the equivalent App Intent so Siri/Spotlight learn this habit.
        IntentDonations.playedPocket(collections.pocket(pocketId), shuffle: shuffle)
        if !nowPlayingPushed {
            nowPlayingPushed = true
            path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
        }
    }
}

/// Picks the Apple Music source playlist to link an unlinked pocket back to (rescues a pocket
/// whose link was dropped by duplicate → convert → delete-playlist). Searchable because a real
/// library can carry a hundred-plus playlists; tapping one links immediately.
private struct LinkSourceSheet: View {
    let sources: [SourcePlaylist]
    let pocketName: String
    let onPick: (SourcePlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [SourcePlaylist] {
        let q = query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return sources }
        return sources.filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { sp in
                Button { onPick(sp) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list").foregroundStyle(Theme.accent2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sp.name).foregroundStyle(Theme.fg)
                            Text("\(sp.songIds.count) song\(sp.songIds.count == 1 ? "" : "s") · \(sp.sourceName)")
                                .font(.caption2).foregroundStyle(Theme.fgDim)
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("link-source-\(sp.id)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden).background(Theme.bg)
            .searchable(text: $query, prompt: "Search playlists")
            .navigationTitle("Link to a playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if sources.isEmpty {
                    Text("No Apple Music playlists found. Make sure the Apple Music source is enabled and loaded.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                        .multilineTextAlignment(.center).padding()
                }
            }
        }
    }
}
