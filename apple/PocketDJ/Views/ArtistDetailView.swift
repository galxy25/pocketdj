import SwiftUI

/// All albums by one artist (the Artists browse kind → tap an artist). A header with Play all /
/// Shuffle all plays the artist's WHOLE discography (every track across their albums, in order or
/// shuffled) into the reserved Now Playing setlist; each album row opens the normal album detail.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let artistName: String
    @Binding var path: NavigationPath
    @State private var nowPlayingPushed = false

    /// The artist's albums, in the catalog's (artist › name) order. Case-INSENSITIVE match so a
    /// merged catalog with inconsistent casing still gathers the whole discography (matches the
    /// case-insensitive grouping in AppModel.buildEffective).
    private var albums: [IndexAlbum] {
        app.albums.filter { $0.artist.localizedCaseInsensitiveCompare(artistName) == .orderedSame }
    }
    /// Every track by the artist, album by album, in order.
    private var allSongIds: [String] { albums.flatMap(\.trackList) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(albums) { album in
                    Button { path.append(album) } label: { albumRow(album) }
                        .buttonStyle(.plain)
                    Divider().overlay(Theme.border).padding(.leading, 62)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(artistName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("artist-detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(artistName).font(.title2.bold()).foregroundStyle(Theme.fg)
            Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(allSongIds.count) songs")
                .font(.caption).foregroundStyle(Theme.fgDim)
            HStack(spacing: 12) {
                Button { play(shuffle: false) } label: {
                    Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("artist-play-all")
                Button { play(shuffle: true) } label: {
                    Label("Shuffle all", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("artist-shuffle-all")
            }
            .buttonStyle(.borderedProminent)
            .disabled(allSongIds.isEmpty)
        }
    }

    private func albumRow(_ album: IndexAlbum) -> some View {
        HStack(spacing: 12) {
            SongThumbnail(album: album).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                Text("\(album.trackList.count) tracks" + (album.year.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
        }
        .contentShape(Rectangle())
    }

    /// ▶/🔀 the artist's whole discography — a fresh Now Playing snapshot, then open it autostarting
    /// (mirrors AlbumDetailView.play). Attributed to History as source `.artist`.
    private func play(shuffle: Bool) {
        collections.playNow(songIds: allSongIds, name: artistName, shuffle: shuffle, source: .artist,
                            originId: artistName)
        if !nowPlayingPushed {
            nowPlayingPushed = true
            path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
        }
    }
}
