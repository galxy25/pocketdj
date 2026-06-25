import SwiftUI

/// Song metadata viewer — reached by tapping a song in the songs browser or in
/// an album's track table. Links back to its album, and supports editing.
struct SongDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(LyricsStore.self) private var lyricsStore: LyricsStore?
    let song: IndexSong
    @State private var showEdit = false
    @State private var showAdd = false
    /// Lazily-loaded, on-disk-cached lyrics (nil until loaded / when absent).
    @State private var lyrics: String?

    /// Always read the latest (possibly edited) version from the catalog.
    private var current: IndexSong { app.songsById[song.id] ?? song }
    private var album: IndexAlbum? { current.albumId.flatMap { app.albumsById[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let album {
                    CoverImage(album: album)
                        .frame(width: 220, height: 220)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("song-detail-art")
                }
                header
                Divider().overlay(Theme.border)
                MetadataGrid(rows: rows)
                if let kw = current.sentimentKeywords, !kw.isEmpty { sentiment(kw) }
                if let lyrics, !lyrics.isEmpty { lyricsSection(lyrics) }
                playback
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
        // Lyrics: fetch-once + on-disk cache, only when this song's `lyricsStatus == "found"`.
        .task(id: current.id) { lyrics = await lyricsStore?.lyrics(for: current) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.name).font(.title2.bold()).foregroundStyle(Theme.fg)
            Text(current.artist).font(.title3).foregroundStyle(Theme.accent)
            KeyChip(key: current.key, camelot: current.camelot)
            if let src = app.source(ofSong: current.id) {
                Tag(text: src, color: Theme.fgDim)
                    .accessibilityIdentifier("source-tag")
            }
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
        if let src = app.source(ofSong: current.id) { r.append(("Source", src)) }
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

    /// On-demand lyrics (when present + loaded), selectable for copy.
    private func lyricsSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lyrics").font(.caption.weight(.semibold)).textCase(.uppercase)
                .foregroundStyle(Theme.fgDim)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("song-lyrics")
        }
    }

    /// Bottom playback bar: the SAME ▶ play / ⤓ download transport used in every track row,
    /// plus the slide-out streaming / waveform inline player that reveals below it on Play.
    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            HStack(spacing: 12) {
                Text("Play").font(.caption.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(Theme.fgDim)
                Spacer()
                RowTransport(song: (id: current.id, title: current.name, artist: current.artist),
                             startMs: nil)
            }
            // NOTE: no `.accessibilityIdentifier` on this container — SwiftUI propagates a
            // container id onto every descendant, clobbering RowTransport's own
            // `row-play-<id>` / `row-download-<id>` ids (same trap as InlinePlayerPanel).
            InlinePlayerSlot(songId: current.id)
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
