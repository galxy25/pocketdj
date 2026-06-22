import SwiftUI
import UniformTypeIdentifiers

/// Pockets — reusable, nestable groupings of items that sound good together.
struct PocketsView: View {
    @Environment(CollectionsStore.self) private var collections
    @State private var newName = ""
    @State private var showNew = false
    @State private var showImporter = false
    @State private var renamingId: String?
    @State private var nameDraft = ""
    @State private var deletingId: String?

    var body: some View {
        Group {
            if collections.pockets.isEmpty {
                ContentUnavailableView {
                    Label("No pockets yet", systemImage: "rectangle.stack")
                } description: {
                    Text("A pocket is a collection of items that sound good together — songs, albums, even poetry or cues — that you can drop into playlists. Add items from a song or album.")
                } actions: {
                    Button("New Pocket") { showNew = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(collections.pockets) { pocket in
                        NavigationLink(value: pocket) {
                            HStack {
                                Image(systemName: "rectangle.stack").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pocket.name).foregroundStyle(Theme.fg)
                                    let stats = collections.catalog().stats(forPocket: pocket.id)
                                    Text("\(pocket.memberCount) item\(pocket.memberCount == 1 ? "" : "s") · \(stats.summary)")
                                        .font(.caption).foregroundStyle(Theme.fgDim)
                                }
                            }
                        }
                        .accessibilityIdentifier("pocket-\(pocket.id)")
                        .contextMenu {
                            Button { nameDraft = pocket.name; renamingId = pocket.id } label: { Label("Rename", systemImage: "pencil") }
                                .accessibilityIdentifier("list-rename-\(pocket.id)")
                            Button(role: .destructive) { deletingId = pocket.id } label: { Label("Delete", systemImage: "trash") }
                                .accessibilityIdentifier("list-delete-\(pocket.id)")
                        }
                    }
                    .onDelete { idx in idx.map { collections.pockets[$0].id }.forEach(collections.deletePocket) }
                }
            }
        }
        .navigationTitle("Pockets")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden).background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Import a pocket export")
                    .accessibilityIdentifier("import-pocket")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("new-pocket")
            }
        }
        .alert("New Pocket", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { let n = newName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createPocket(n) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename pocket", isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                if let id = renamingId { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePocket(id, n) } }
                renamingId = nil
            }
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .confirmationDialog("Delete this pocket?", isPresented: Binding(get: { deletingId != nil }, set: { if !$0 { deletingId = nil } }), titleVisibility: .visible) {
            Button("Delete pocket", role: .destructive) { if let id = deletingId { collections.deletePocket(id) }; deletingId = nil }
            Button("Cancel", role: .cancel) { deletingId = nil }
        } message: {
            Text("Removes the pocket and unnests it from any parent. Its items aren’t deleted. This can’t be undone.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .zip]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try? collections.importAny(url: url)
        }
    }
}

/// One pocket's members: songs, albums, and nested child pockets.
struct PocketDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(\.dismiss) private var dismiss
    let pocketId: String
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingDelete = false
    @State private var showExporter = false
    @State private var exportDoc = PlaylistZipFile(data: Data())
    @State private var addingNote = false
    @State private var noteDraft = ""
    @State private var editingNoteId: String?
    @State private var ripBurn = CollectionRipBurnController()

    private var pocket: Pocket? { collections.pocket(pocketId) }

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { noteDraft = ""; addingNote = true } label: { Label("Add note", systemImage: "text.badge.plus") }
                        .accessibilityIdentifier("add-pocket-note")
                    Button { nameDraft = pocket?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                        .accessibilityIdentifier("rename-pocket")
                    Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
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
            Text("Removes the pocket and unnests it from any parent. Its items aren’t deleted. This can’t be undone.")
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .zip,
                      defaultFilename: exportFilename) { _ in }
    }

    /// `<sanitized name>.pocket.pocketdj` — `.fileExporter` appends `.zip`, yielding
    /// `<name>.pocket.pocketdj.zip` (the standalone pocket transfer).
    private var exportFilename: String {
        let base = (pocket?.name ?? "pocket")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "pocket" : base).pocket.pocketdj"
    }

    private func export() {
        if let data = try? collections.exportPocketZip(pocketId) {
            exportDoc = PlaylistZipFile(data: data); showExporter = true
        }
    }
}
