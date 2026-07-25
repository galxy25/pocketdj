import SwiftUI
import UniformTypeIdentifiers

// NOTE: The PocketsView list (create/import/list) has been merged into PlaylistsView.
// This file retains only PocketDetailView (the per-pocket detail) and its helpers,
// which are still navigated to from the merged list via .navigationDestination(for: Pocket.self).

/// One pocket's members: songs, albums, and nested child pockets.
struct PocketDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(\.dismiss) private var dismiss
    let pocketId: String
    @Binding var path: NavigationPath
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

    /// Apple Music source playlists this unlinked pocket could be linked to (the only sources
    /// write-back can push to). Name-ordered.
    private var linkableSources: [SourcePlaylist] {
        app.indexPlaylists
            .filter { PlaylistWriteBack.isAppleMusicSource($0.sourceName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var hasSongs: Bool { !collections.songIds(forPocket: pocketId).isEmpty }

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
                    let stats = collections.catalog().stats(forPocket: pocketId)
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
                    ForEach(pocket.songIds, id: \.self) { sid in
                        if let song = app.songsById[sid] {
                            // One List row = nav link + inline panel below, kept together in
                            // a VStack so the panel's taps reach it (not the link) and the
                            // 1:1 element↔row mapping `onMove` relies on is preserved.
                            VStack(spacing: 0) {
                                NavigationLink(value: song) { CollectionSongRow(song: song, syncsToSource: pocket.syncsWithSource) }
                                    .forceSyncContextMenu(song: song, kind: .pocket, collectionId: pocketId)
                                InlinePlayerSlot(songId: song.id)
                            }
                            .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(sid, fromPocket: pocketId) } }
                        } else if StudioFactory.isStudioId(sid) {
                            // Performance items (sample/loop/sequence/instrumental) ride songIds but
                            // aren't in the catalog — render a studio-aware row with its repeat count
                            // (previously rendered NOTHING, which also broke onMove's 1:1 mapping).
                            StudioCollectionRow(
                                id: sid,
                                repeatCount: collections.repeatCount(forSong: sid, inPocket: pocketId),
                                onSetRepeat: { collections.setSongRepeat(sid, count: $0, inPocket: pocketId) },
                                onRemove: { collections.removeSong(sid, fromPocket: pocketId) })
                            .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(sid, fromPocket: pocketId) } }
                        }
                    }
                    .onMove { from, to in collections.movePocketSongs(inPocket: pocketId, from: from, to: to) }
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
        .navigationTitle(pocket?.name ?? "Pocket")
        .accessibilityIdentifier("pocket-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
        .onAppear { nowPlayingPushed = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PlaybackModeToggle()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: false) } label: { Image(systemName: "play.fill") }
                    .help("Play this pocket now")
                    .disabled(!hasSongs)
                    .accessibilityIdentifier("pocket-play")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: true) } label: { Image(systemName: "shuffle") }
                    .help("Shuffle-play this pocket now")
                    .disabled(!hasSongs)
                    .accessibilityIdentifier("pocket-shuffle")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { noteDraft = ""; addingNote = true } label: { Label("Add note", systemImage: "text.badge.plus") }
                        .accessibilityIdentifier("add-pocket-note")
                    #if os(iOS)
                    // Inside the ⋯ menu (not a 5th toolbar item) so the compact-width
                    // iPhone toolbar stays at 4 items and never nests a system "More".
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
                    Divider()
                    CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forPocket: pocketId) }, noun: "pocket")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete pocket", systemImage: "trash") }
                        .accessibilityIdentifier("delete-pocket")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("pocket-menu")
            }
        }
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
                linkResult = "“\(pocket?.name ?? "This pocket")” is now linked to “\(sp.name)”. Songs you add to it will be added to that Apple Music playlist too. To send ones you already added, use Settings ▸ Sync ▸ “Send my adds to Apple Music” (or the ↑ button on History ▸ Collection)."
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

    /// Presented-state for the sync-result alert (a computed Binding INSIDE body blew
    /// the type-checker budget for the whole List expression).
    private var syncResultShowing: Binding<Bool> {
        Binding(get: { syncResult != nil }, set: { if !$0 { syncResult = nil } })
    }

    /// Source-sync ⋯-menu items — shown only for a pocket converted from a source
    /// playlist (provenance present). Split out of the Menu builder: the inline
    /// Binding + ternary blew the type-checker's budget in the big toolbar expression.
    @ViewBuilder private var sourceSyncMenuItems: some View {
        let syncBinding = Binding<Bool>(
            get: { pocket?.syncsWithSource ?? false },
            set: { collections.setSourceSyncEnabled($0, forPocket: pocketId) })
        Divider()
        Section(sourceLinkHeader) {
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
            // write-back candidates (then Settings ▸ Sync ▸ "Send my adds" pushes them).
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
