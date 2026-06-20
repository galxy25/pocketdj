import SwiftUI
import UniformTypeIdentifiers

/// Pockets — reusable, nestable groupings of harmonically-similar items.
struct PocketsView: View {
    @Environment(CollectionsStore.self) private var collections
    @State private var newName = ""
    @State private var showNew = false
    @State private var showImporter = false

    var body: some View {
        Group {
            if collections.pockets.isEmpty {
                ContentUnavailableView {
                    Label("No pockets yet", systemImage: "rectangle.stack")
                } description: {
                    Text("Pockets group harmonically-similar songs & albums you can drop into playlists. Add items from a song or album.")
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
                    }
                    .onDelete { idx in idx.map { collections.pockets[$0].id }.forEach(collections.deletePocket) }
                }
            }
        }
        .navigationTitle("Pockets")
        .background(Theme.bg)
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
                            NavigationLink(value: song) { CollectionSongRow(song: song) }
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(sid, fromPocket: pocketId) } }
                        }
                    }
                    .onMove { from, to in collections.movePocketSongs(inPocket: pocketId, from: from, to: to) }
                }
                if pocket.isEmpty {
                    Text("Empty. Add songs or albums from their detail view ▸ Add to…")
                        .foregroundStyle(Theme.fgDim)
                }
            }
        }
        .navigationTitle(pocket?.name ?? "Pocket")
        .accessibilityIdentifier("pocket-detail")
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { nameDraft = pocket?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                        .accessibilityIdentifier("rename-pocket")
                    Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("export-pocket")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete pocket", systemImage: "trash") }
                        .accessibilityIdentifier("delete-pocket")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("pocket-menu")
            }
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
