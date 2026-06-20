import SwiftUI

/// Pockets — reusable, nestable groupings of harmonically-similar items.
struct PocketsView: View {
    @Environment(CollectionsStore.self) private var collections
    @State private var newName = ""
    @State private var showNew = false

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
                                    Text("\(pocket.memberCount) item\(pocket.memberCount == 1 ? "" : "s")")
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
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("new-pocket")
            }
        }
        .alert("New Pocket", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { let n = newName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createPocket(n) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

/// One pocket's members: songs, albums, and nested child pockets.
struct PocketDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let pocketId: String

    private var pocket: Pocket? { collections.pocket(pocketId) }

    var body: some View {
        List {
            if let pocket {
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
                    }
                }
                Section("Albums (\(pocket.albumIds.count))") {
                    ForEach(pocket.albumIds, id: \.self) { aid in
                        if let album = app.albumsById[aid] {
                            NavigationLink(value: album) { AlbumRow(album: album) }
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeAlbum(aid, fromPocket: pocketId) } }
                        }
                    }
                }
                Section("Songs (\(pocket.songIds.count))") {
                    ForEach(pocket.songIds, id: \.self) { sid in
                        if let song = app.songsById[sid] {
                            NavigationLink(value: song) { SongRow(song: song, albumName: app.albumName(forSong: song)) }
                                .swipeActions { Button("Remove", role: .destructive) { collections.removeSong(sid, fromPocket: pocketId) } }
                        }
                    }
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
    }
}
