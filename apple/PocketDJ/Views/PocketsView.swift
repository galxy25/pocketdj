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

    private var pocket: Pocket? { collections.pocket(pocketId) }
    private var hasSongs: Bool { !collections.songIds(forPocket: pocketId).isEmpty }

    var body: some View {
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
                                NavigationLink(value: song) { CollectionSongRow(song: song) }
                                InlinePlayerSlot(songId: song.id)
                            }
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
                    Button { nameDraft = pocket?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                        .accessibilityIdentifier("rename-pocket")
                    Button { showFormatDialog = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("export-pocket")
                    Divider()
                    CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forPocket: pocketId) }, noun: "pocket")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete pocket", systemImage: "trash") }
                        .accessibilityIdentifier("delete-pocket")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("pocket-menu")
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton().accessibilityIdentifier("pocket-edit-order")
            }
            #endif
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
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .zip,
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

    /// `<sanitized name>.pocket.pocketdj` — `.fileExporter` appends `.zip`, yielding
    /// `<name>.pocket.pocketdj.zip` (the standalone pocket transfer).
    private var exportFilename: String {
        let base = (pocket?.name ?? "pocket")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "pocket" : base).pocket.pocketdj"
    }

    /// `<sanitized name>.csv` — the universal tracklist filename.
    private var csvFilename: String {
        let base = (pocket?.name ?? "pocket")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "pocket" : base
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
