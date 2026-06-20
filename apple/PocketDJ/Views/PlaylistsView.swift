import SwiftUI

/// Playlists — ordered chapters (sequences) of songs/albums/pockets/text cues.
struct PlaylistsView: View {
    @Environment(CollectionsStore.self) private var collections
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        Group {
            if collections.playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists yet", systemImage: "music.note.list")
                } description: {
                    Text("A playlist is a template: ordered chapters of songs, albums, pockets, and text cues.")
                } actions: {
                    Button("New Playlist") { showNew = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(collections.playlists) { pl in
                        NavigationLink(value: pl) {
                            HStack {
                                Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pl.name).foregroundStyle(Theme.fg)
                                    Text("\(pl.sequences.count) chapter\(pl.sequences.count == 1 ? "" : "s") · \(pl.sequences.reduce(0) { $0 + ($1.children?.count ?? 0) }) item(s)")
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

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let playlistId: String
    @Binding var path: NavigationPath
    @State private var newSeq = ""
    @State private var showNewSeq = false

    private var playlist: Playlist? { collections.playlist(playlistId) }
    private var setlists: [Setlist] { collections.setlists(forPlaylist: playlistId) }
    private var itemCount: Int { (playlist?.sequences ?? []).reduce(0) { $0 + ($1.children?.count ?? 0) } }

    var body: some View {
        List {
            if let playlist {
                ForEach(playlist.sequences) { seq in
                    Section(seq.name ?? "Chapter") {
                        let children = seq.children ?? []
                        if children.isEmpty {
                            Text("Empty chapter — add items from a song/album ▸ Add to…")
                                .font(.caption).foregroundStyle(Theme.fgDim)
                        }
                        ForEach(children) { node in
                            nodeRow(node)
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) } }
                        }
                        if playlist.sequences.count > 1 {
                            Button("Delete chapter", role: .destructive) { collections.removeSequence(seq.nodeId, fromPlaylist: playlistId) }
                                .font(.caption)
                        }
                    }
                }

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
        }
        .alert("New Chapter", isPresented: $showNewSeq) {
            TextField("Name", text: $newSeq)
            Button("Add") { let n = newSeq.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.addSequence(n, toPlaylist: playlistId) }; newSeq = "" }
            Button("Cancel", role: .cancel) { newSeq = "" }
        }
    }

    /// ▶ Play: realize the template into a frozen Setlist, persist it, and push its view.
    private func play() {
        if let sl = collections.realize(playlistId: playlistId) { path.append(sl) }
    }

    @ViewBuilder private func nodeRow(_ node: PlaylistNode) -> some View {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = app.songsById[id] {
                NavigationLink(value: song) { Label(song.name, systemImage: "music.note").foregroundStyle(Theme.fg) }
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
