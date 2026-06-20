import SwiftUI
import UniformTypeIdentifiers

/// Playlists — ordered chapters (sequences) of songs/albums/pockets/text cues.
/// Lists the read-only playlists carried in the enabled sources ("From your
/// sources") above the editable local playlists ("Your playlists").
struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Binding var path: NavigationPath
    @State private var newName = ""
    @State private var showNew = false

    private var indexPlaylists: [SourcePlaylist] { app.indexPlaylists }

    var body: some View {
        Group {
            if collections.playlists.isEmpty && indexPlaylists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists yet", systemImage: "music.note.list")
                } description: {
                    Text("A playlist is a template: ordered chapters of songs, albums, pockets, and text cues.")
                } actions: {
                    Button("New Playlist") { showNew = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if !indexPlaylists.isEmpty {
                        Section {
                            ForEach(indexPlaylists) { sp in
                                NavigationLink(value: sp) {
                                    HStack {
                                        Image(systemName: "music.note.list").foregroundStyle(Theme.accent2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(sp.name).foregroundStyle(Theme.fg)
                                            HStack(spacing: 6) {
                                                Text(sp.sourceName)
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Theme.accent2.opacity(0.18), in: Capsule())
                                                    .foregroundStyle(Theme.accent2)
                                                Text("\(sp.songIds.count) song\(sp.songIds.count == 1 ? "" : "s")")
                                                    .font(.caption).foregroundStyle(Theme.fgDim)
                                            }
                                        }
                                    }
                                }
                                .accessibilityIdentifier("indexplaylist-\(sp.id)")
                            }
                        } header: {
                            Text("From your sources")
                        } footer: {
                            Text("Read-only playlists from your enabled sources. Play one, or duplicate it into an editable playlist.")
                        }
                    }

                    Section("Your playlists") {
                        if collections.playlists.isEmpty {
                            Text("No editable playlists yet — tap + to create one.")
                                .font(.caption).foregroundStyle(Theme.fgDim)
                        }
                        ForEach(collections.playlists) { pl in
                            NavigationLink(value: pl) {
                                HStack {
                                    Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pl.name).foregroundStyle(Theme.fg)
                                        let stats = collections.catalog().stats(forPlaylist: pl)
                                        Text("\(pl.sequences.count) chapter\(pl.sequences.count == 1 ? "" : "s") · \(stats.summary)")
                                            .font(.caption).foregroundStyle(Theme.fgDim)
                                    }
                                }
                            }
                            .accessibilityIdentifier("playlist-\(pl.id)")
                        }
                        .onDelete { idx in idx.map { collections.playlists[$0].id }.forEach(collections.deletePlaylist) }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("new-playlist")
            }
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { let n = newName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createPlaylist(n) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

/// Read-only detail for a source ("From your sources") playlist: its songs, with a
/// ▶ Play (realize → Setlist) and a "Duplicate as editable playlist" action.
struct IndexPlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let source: SourcePlaylist
    @Binding var path: NavigationPath

    private var songs: [IndexSong] { source.songIds.compactMap { app.songsById[$0] } }

    var body: some View {
        List {
            Section {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(songs.isEmpty)
                    .accessibilityIdentifier("indexplaylist-play")
                Button { duplicate() } label: { Label("Duplicate as editable playlist", systemImage: "plus.square.on.square") }
                    .accessibilityIdentifier("indexplaylist-duplicate")
            } footer: {
                Text("\(songs.count) of \(source.songIds.count) song\(source.songIds.count == 1 ? "" : "s") resolved from \(source.sourceName).")
            }

            Section("Songs") {
                ForEach(songs) { song in
                    NavigationLink(value: song) { CollectionSongRow(song: song) }
                }
            }
        }
        .navigationTitle(source.name)
        .accessibilityIdentifier("indexplaylist-detail")
        .background(Theme.bg)
    }

    private func play() {
        if let sl = collections.realize(songIds: source.songIds, name: source.name) { path.append(sl) }
    }
    private func duplicate() {
        let pl = collections.createPlaylist(source.name, songIds: source.songIds)
        // Replace the read-only detail with the new editable one.
        path.removeLast()
        path.append(pl)
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let playlistId: String
    @Binding var path: NavigationPath
    @State private var newSeq = ""
    @State private var showNewSeq = false
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var renamingChapter: String?       // sequence nodeId being renamed
    @State private var chapterDraft = ""
    @State private var confirmingDelete = false
    @State private var showExporter = false
    @State private var exportDoc = EditsFile(data: Data())

    private var playlist: Playlist? { collections.playlist(playlistId) }
    private var setlists: [Setlist] { collections.setlists(forPlaylist: playlistId) }
    private var itemCount: Int { (playlist?.sequences ?? []).reduce(0) { $0 + ($1.children?.count ?? 0) } }

    var body: some View {
        List {
            if let playlist {
                Section {
                    let stats = collections.catalog().stats(forPlaylist: playlist)
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                        Text(stats.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                        Spacer()
                    }
                    .accessibilityIdentifier("playlist-stats")
                }
                ForEach(playlist.sequences) { seq in
                    Section {
                        let children = seq.children ?? []
                        if children.isEmpty {
                            Text("Empty chapter — add items from a song/album ▸ Add to…")
                                .font(.caption).foregroundStyle(Theme.fgDim)
                        }
                        ForEach(Array(children.enumerated()), id: \.element.nodeId) { idx, node in
                            nodeRow(node)
                                .swipeActions(edge: .trailing) {
                                    Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Up", systemImage: "arrow.up") }
                                        .tint(Theme.accent)
                                        .disabled(idx == 0)
                                    Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Down", systemImage: "arrow.down") }
                                        .tint(Theme.accent2)
                                        .disabled(idx == children.count - 1)
                                }
                                .contextMenu {
                                    Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Move up", systemImage: "arrow.up") }
                                        .accessibilityIdentifier("move-up-\(node.nodeId)")
                                        .disabled(idx == 0)
                                    Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Move down", systemImage: "arrow.down") }
                                        .accessibilityIdentifier("move-down-\(node.nodeId)")
                                        .disabled(idx == children.count - 1)
                                    Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
                                }
                        }
                        .onMove { from, to in
                            collections.moveNodes(inPlaylist: playlistId, sequenceId: seq.nodeId, from: from, to: to)
                        }
                        .onDelete { offsets in
                            offsets.map { children[$0].nodeId }.forEach { collections.removeNode($0, fromPlaylist: playlistId) }
                        }
                        Button { renamingChapter = seq.nodeId; chapterDraft = seq.name ?? "" } label: {
                            Label("Rename chapter", systemImage: "pencil").font(.caption)
                        }
                        .accessibilityIdentifier("rename-chapter")
                        if playlist.sequences.count > 1 {
                            Button("Delete chapter", role: .destructive) { collections.removeSequence(seq.nodeId, fromPlaylist: playlistId) }
                                .font(.caption)
                        }
                    } header: {
                        HStack {
                            Text(seq.name ?? "Chapter")
                            Spacer()
                            Text(collections.catalog().stats(forChapter: seq).summary)
                                .foregroundStyle(Theme.fgDim)
                        }
                        .accessibilityIdentifier("chapter-stats-\(seq.nodeId)")
                    }
                }
                .onMove { from, to in collections.moveSequences(inPlaylist: playlistId, from: from, to: to) }

                if !setlists.isEmpty {
                    Section("Set lists") {
                        ForEach(setlists) { sl in
                            NavigationLink(value: sl) {
                                HStack {
                                    Image(systemName: "waveform").foregroundStyle(Theme.accent2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sl.name ?? "Set list").foregroundStyle(Theme.fg)
                                        Text("\(sl.tracks.count) track\(sl.tracks.count == 1 ? "" : "s") · \(Fmt.duration(sl.totalMs))")
                                            .font(.caption).foregroundStyle(Theme.fgDim)
                                    }
                                }
                            }
                            .accessibilityIdentifier("setlist-\(sl.id)")
                        }
                        .onDelete { idx in idx.map { setlists[$0].id }.forEach(collections.deleteSetlist) }
                    }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .accessibilityIdentifier("playlist-detail")
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .help("Realize this template into a frozen set list")
                    .disabled(itemCount == 0)
                    .accessibilityIdentifier("playlist-play")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSeq = true } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .help("Add chapter")
                    .accessibilityIdentifier("add-chapter")
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton().accessibilityIdentifier("edit-order")   // toggles drag-reorder of chapters + items
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { nameDraft = playlist?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                        .accessibilityIdentifier("rename-playlist")
                    Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("export-playlist")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                        .accessibilityIdentifier("delete-playlist")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("playlist-menu")
            }
        }
        .alert("New Chapter", isPresented: $showNewSeq) {
            TextField("Name", text: $newSeq)
            Button("Add") { let n = newSeq.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.addSequence(n, toPlaylist: playlistId) }; newSeq = "" }
            Button("Cancel", role: .cancel) { newSeq = "" }
        }
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePlaylist(playlistId, n) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename chapter", isPresented: Binding(get: { renamingChapter != nil }, set: { if !$0 { renamingChapter = nil } })) {
            TextField("Name", text: $chapterDraft)
            Button("Save") {
                if let sid = renamingChapter {
                    let n = chapterDraft.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { collections.renameSequence(sid, n, inPlaylist: playlistId) }
                }
                renamingChapter = nil
            }
            Button("Cancel", role: .cancel) { renamingChapter = nil }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                collections.deletePlaylist(playlistId)
                if !path.isEmpty { path.removeLast() }
            }
            .accessibilityIdentifier("delete-playlist-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also deletes its set lists. This can’t be undone.")
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .json,
                      defaultFilename: "pocketdj-playlist") { _ in }
    }

    /// ▶ Play: realize the template into a frozen Setlist, persist it, and push its view.
    private func play() {
        if let sl = collections.realize(playlistId: playlistId) { path.append(sl) }
    }

    private func export() {
        if let data = try? collections.exportPlaylist(playlistId) {
            exportDoc = EditsFile(data: data); showExporter = true
        }
    }

    @ViewBuilder private func nodeRow(_ node: PlaylistNode) -> some View {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = app.songsById[id] {
                NavigationLink(value: song) { CollectionSongRow(song: song) }
            } else { missing("song") }
        case .album:
            if let id = node.albumId, let album = app.albumsById[id] {
                NavigationLink(value: album) { Label(album.name, systemImage: "rectangle.stack").foregroundStyle(Theme.fg) }
            } else { missing("album") }
        case .pocket:
            if let id = node.pocketId, let pocket = collections.pocket(id) {
                NavigationLink(value: pocket) { Label(pocket.name, systemImage: "rectangle.stack.badge.play").foregroundStyle(Theme.accent2) }
            } else { missing("pocket") }
        case .text:
            Label(node.text ?? "", systemImage: "text.quote").foregroundStyle(Theme.fgDim).italic()
        case .sequence:
            Label(node.name ?? "Sub-chapter", systemImage: "list.bullet.indent").foregroundStyle(Theme.fgDim)
        }
    }

    private func missing(_ what: String) -> some View {
        Label("(missing \(what))", systemImage: "questionmark.circle").foregroundStyle(Theme.fgDim)
    }
}
