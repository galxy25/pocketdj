import SwiftUI

/// Song metadata viewer — reached by tapping a song in the songs browser or in
/// an album's track table. Links back to its album, and supports editing.
struct SongDetailView: View {
    @Environment(AppModel.self) private var app
    let song: IndexSong
    @State private var showEdit = false
    @State private var showAdd = false

    /// Always read the latest (possibly edited) version from the catalog.
    private var current: IndexSong { app.songsById[song.id] ?? song }
    private var album: IndexAlbum? { current.albumId.flatMap { app.albumsById[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().overlay(Theme.border)
                MetadataGrid(rows: rows)
                if let kw = current.sentimentKeywords, !kw.isEmpty { sentiment(kw) }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(current.name)
        .accessibilityIdentifier("song-detail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus.circle") }
                    .accessibilityIdentifier("add-song-to")
                Button("Edit") { showEdit = true }.accessibilityIdentifier("edit-song")
            }
        }
        .sheet(isPresented: $showEdit) { EditSongView(song: current) }
        .sheet(isPresented: $showAdd) { AddToCollectionView(item: .song(current.id)) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.name).font(.title2.bold()).foregroundStyle(Theme.fg)
            Text(current.artist).font(.title3).foregroundStyle(Theme.accent)
            KeyChip(key: current.key, camelot: current.camelot)
            if let album {
                NavigationLink(value: album) {
                    Label(album.name, systemImage: "rectangle.stack")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("album-hotlink")
            }
        }
    }

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        r.append(("Artist", current.artist))
        if let album { r.append(("Album", album.name)) }
        if let n = current.trackNumber { r.append(("Track #", String(n))) }
        if let y = current.year { r.append(("Year", String(y))) }
        r.append(("BPM", Fmt.bpm(current.bpm)))
        if let k = current.key { r.append(("Key", k)) }
        if let c = current.camelot { r.append(("Camelot", c)) }
        r.append(("Length", Fmt.duration(current.length)))
        r.append(("Explicit", current.explicit == true ? "Yes" : "No"))
        if let f = current.fileType { r.append(("File type", f.uppercased())) }
        if let l = current.lyricsStatus { r.append(("Lyrics", l)) }
        return r
    }

    private func sentiment(_ keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sentiment").font(.caption.weight(.semibold)).textCase(.uppercase)
                .foregroundStyle(Theme.fgDim)
            FlowTags(tags: keywords)
        }
    }
}

/// A simple label/value metadata grid.
struct MetadataGrid: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).font(.caption).foregroundStyle(Theme.fgDim)
                        .gridColumnAlignment(.leading)
                    Text(value).font(.callout).foregroundStyle(Theme.fg)
                }
            }
        }
    }
}

/// Wrapping tag row.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        // Simple wrap via a lazy grid of adaptive chips.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { Tag(text: $0, color: Theme.accent2) }
        }
    }
}
