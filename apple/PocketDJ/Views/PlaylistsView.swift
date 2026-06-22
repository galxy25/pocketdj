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
    @State private var showImporter = false
    @State private var renamingId: String?
    @State private var nameDraft = ""
    @State private var deletingId: String?

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
                            .contextMenu {
                                Button { nameDraft = pl.name; renamingId = pl.id } label: { Label("Rename", systemImage: "pencil") }
                                    .accessibilityIdentifier("list-rename-\(pl.id)")
                                Button(role: .destructive) { deletingId = pl.id } label: { Label("Delete", systemImage: "trash") }
                                    .accessibilityIdentifier("list-delete-\(pl.id)")
                            }
                        }
                        .onDelete { idx in idx.map { collections.playlists[$0].id }.forEach(collections.deletePlaylist) }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden).background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Import a playlist export")
                    .accessibilityIdentifier("import-playlist")
            }
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
        .alert("Rename playlist", isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                if let id = renamingId { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePlaylist(id, n) } }
                renamingId = nil
            }
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .confirmationDialog("Delete this playlist?", isPresented: Binding(get: { deletingId != nil }, set: { if !$0 { deletingId = nil } }), titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) { if let id = deletingId { collections.deletePlaylist(id) }; deletingId = nil }
            Button("Cancel", role: .cancel) { deletingId = nil }
        } message: {
            Text("This also deletes its set lists. This can’t be undone.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .zip]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try? collections.importAny(url: url)
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
    @State private var ripBurn = CollectionRipBurnController()

    private var songs: [IndexSong] { source.songIds.compactMap { app.songsById[$0] } }

    var body: some View {
        List {
            Section {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(songs.isEmpty)
                    .accessibilityIdentifier("indexplaylist-play")
                Button { duplicate() } label: { Label("Duplicate as editable playlist", systemImage: "plus.square.on.square") }
                    .accessibilityIdentifier("indexplaylist-duplicate")
                CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forSource: source) }, noun: "playlist")
            } footer: {
                Text("\(songs.count) of \(source.songIds.count) song\(source.songIds.count == 1 ? "" : "s") resolved from \(source.sourceName).")
            }

            Section("Songs") {
                ForEach(songs) { song in
                    VStack(spacing: 0) {
                        NavigationLink(value: song) { CollectionSongRow(song: song) }
                        InlinePlayerSlot(songId: song.id)
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .accessibilityIdentifier("indexplaylist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
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
    @State private var exportDoc = PlaylistZipFile(data: Data())
    @State private var renamingSetlistId: String?
    @State private var setlistNameDraft = ""
    @State private var deletingSetlistId: String?
    @State private var addingNoteChapter: String?     // sequence nodeId to add a text note to
    @State private var noteDraft = ""
    @State private var ripBurn = CollectionRipBurnController()

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
                    chapterSection(seq, chapterCount: playlist.sequences.count)
                }
                .onMove { from, to in collections.moveSequences(inPlaylist: playlistId, from: from, to: to) }

                if !setlists.isEmpty {
                    Section("Set lists") {
                        ForEach(setlists) { sl in setlistRow(sl) }
                        .onDelete { idx in idx.map { setlists[$0].id }.forEach(collections.deleteSetlist) }
                    }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .accessibilityIdentifier("playlist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
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
                    CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forPlaylist: playlistId) }, noun: "playlist")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                        .accessibilityIdentifier("delete-playlist")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("playlist-menu")
            }
        }
        .modifier(playlistAlerts)
        .collectionRipBurn(ripBurn)
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
        .alert("Rename set list", isPresented: Binding(get: { renamingSetlistId != nil }, set: { if !$0 { renamingSetlistId = nil } })) {
            TextField("Name", text: $setlistNameDraft)
            Button("Save") {
                if let id = renamingSetlistId { let n = setlistNameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renameSetlist(id, n) } }
                renamingSetlistId = nil
            }
            Button("Cancel", role: .cancel) { renamingSetlistId = nil }
        }
        .confirmationDialog("Delete this set list?", isPresented: Binding(get: { deletingSetlistId != nil }, set: { if !$0 { deletingSetlistId = nil } }), titleVisibility: .visible) {
            Button("Delete set list", role: .destructive) { if let id = deletingSetlistId { collections.deleteSetlist(id) }; deletingSetlistId = nil }
            Button("Cancel", role: .cancel) { deletingSetlistId = nil }
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .zip,
                      defaultFilename: exportFilename) { _ in }
    }

    /// New-chapter / rename-playlist / rename-chapter / add-note alerts, grouped into
    /// one modifier so the main `body` stays within the Swift type-checker's reach.
    private var playlistAlerts: PlaylistAlerts {
        PlaylistAlerts(
            collections: collections, playlistId: playlistId,
            showNewSeq: $showNewSeq, newSeq: $newSeq,
            renaming: $renaming, nameDraft: $nameDraft,
            renamingChapter: $renamingChapter, chapterDraft: $chapterDraft,
            addingNoteChapter: $addingNoteChapter, noteDraft: $noteDraft)
    }

    /// `<sanitized name>.playlist.pocketdj` — the `.fileExporter` appends the `.zip`
    /// content-type extension, yielding `<name>.playlist.pocketdj.zip` (PWA-readable).
    private var exportFilename: String {
        let base = (playlist?.name ?? "playlist")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "playlist" : base).playlist.pocketdj"
    }

    /// ▶ Play: realize the template into a frozen Setlist, persist it, and push its view.
    private func play() {
        if let sl = collections.realize(playlistId: playlistId) { path.append(sl) }
    }

    private func export() {
        if let data = try? collections.exportPlaylistZip(playlistId) {
            exportDoc = PlaylistZipFile(data: data); showExporter = true
        }
    }

    @ViewBuilder private func chapterSection(_ seq: PlaylistNode, chapterCount: Int) -> some View {
        let children = seq.children ?? []
        Section {
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
            chapterActions(seq, chapterCount: chapterCount)
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

    /// The per-chapter action rows (add note / rename / delete), extracted so the
    /// chapter section body stays within the type-checker's reach.
    @ViewBuilder private func chapterActions(_ seq: PlaylistNode, chapterCount: Int) -> some View {
        Button { addingNoteChapter = seq.nodeId; noteDraft = "" } label: {
            Label("Add note", systemImage: "text.badge.plus").font(.caption)
        }
        .accessibilityIdentifier("add-note-\(seq.nodeId)")
        Button { renamingChapter = seq.nodeId; chapterDraft = seq.name ?? "" } label: {
            Label("Rename chapter", systemImage: "pencil").font(.caption)
        }
        .accessibilityIdentifier("rename-chapter")
        if chapterCount > 1 {
            Button("Delete chapter", role: .destructive) { collections.removeSequence(seq.nodeId, fromPlaylist: playlistId) }
                .font(.caption)
        }
    }

    @ViewBuilder private func setlistRow(_ sl: Setlist) -> some View {
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
        .contextMenu {
            Button { setlistNameDraft = sl.name ?? ""; renamingSetlistId = sl.id } label: { Label("Rename", systemImage: "pencil") }
                .accessibilityIdentifier("list-rename-\(sl.id)")
            Button(role: .destructive) { deletingSetlistId = sl.id } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("list-delete-\(sl.id)")
        }
    }

    @ViewBuilder private func nodeRow(_ node: PlaylistNode) -> some View {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = app.songsById[id] {
                // One List row = nav link + (when this song is playing) the inline panel
                // BELOW it, both in a VStack so the panel's taps don't hit the link and the
                // 1:1 element↔row mapping `onMove`/`onDelete` rely on is preserved.
                VStack(spacing: 0) {
                    NavigationLink(value: song) { CollectionSongRow(song: song) }
                    InlinePlayerSlot(songId: song.id)
                }
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

/// The PlaylistDetailView text-entry alerts, lifted out of `body` so the view's main
/// expression stays type-checkable. Holds only bindings + the store.
private struct PlaylistAlerts: ViewModifier {
    let collections: CollectionsStore
    let playlistId: String
    @Binding var showNewSeq: Bool
    @Binding var newSeq: String
    @Binding var renaming: Bool
    @Binding var nameDraft: String
    @Binding var renamingChapter: String?
    @Binding var chapterDraft: String
    @Binding var addingNoteChapter: String?
    @Binding var noteDraft: String

    func body(content: Content) -> some View {
        content
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
            .alert("Add note", isPresented: Binding(get: { addingNoteChapter != nil }, set: { if !$0 { addingNoteChapter = nil } })) {
                TextField("Note (mic break, sample, cue…)", text: $noteDraft)
                Button("Add") {
                    if let sid = addingNoteChapter {
                        let n = noteDraft.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { collections.addText(n, toPlaylist: playlistId, sequenceId: sid) }
                    }
                    addingNoteChapter = nil
                }
                Button("Cancel", role: .cancel) { addingNoteChapter = nil }
            }
    }
}
