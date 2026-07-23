import SwiftUI

/// Presents a Shazam recognition result. Two independent blocks:
///   • CRATE status — an in-catalog hit deep-links into `SongDetailView`; a not-in-catalog
///     hit shows the recognized metadata.
///   • APPLE MUSIC (`AppleMusicRecognitionSection`) — resolves the track against the user's
///     Apple Music library and offers "open album" (in-app when indexed, else the
///     synthesized `RecognizedAlbumView`) or ＋ add-to-library-and-burn.
///
/// Navigation is self-contained: the sheet owns its `NavigationStack`'s path and registers
/// the destinations the two blocks push (`IndexAlbum`, `IndexSong`, `AppleMusicAlbumRef`),
/// so deep-links work inside the sheet without reaching the root stack.
struct ShazamResultSheet: View {
    let match: ShazamMatch
    /// Called when the user dismisses (the button resets the recognizer).
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    /// The recognized metadata, regardless of crate membership — feeds the Apple Music block.
    private var hitInfo: ShazamHitInfo {
        switch match {
        case .inCatalog(_, let info): return info
        case .notInCatalog(let info): return info
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Heard it")
            .navigationDestination(for: IndexAlbum.self) { AlbumDetailView(album: $0, path: $path) }
            .navigationDestination(for: IndexSong.self) { SongDetailView(song: $0) }
            .navigationDestination(for: AppleMusicAlbumRef.self) { RecognizedAlbumView(album: $0) }
            // AlbumDetailView's artist hotlink pushes an `Artist`; register its destination
            // on THIS stack too (navigationDestination doesn't cross the sheet boundary).
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistName: $0.name, path: $path) }
            // AlbumDetailView's Play/Shuffle push a SetlistLaunch; register the setlist
            // destinations on THIS stack too (navigationDestination doesn't cross the sheet
            // boundary) so playing a deep-linked album from the sheet actually works.
            .navigationDestination(for: SetlistLaunch.self) {
                SetlistDetailView(setlistId: $0.setlistId, autoplay: $0.autoplay, path: $path)
            }
            .navigationDestination(for: Setlist.self) { SetlistDetailView(setlistId: $0.id, path: $path) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); onDone() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            crateBlock
            AppleMusicRecognitionSection(info: hitInfo)
        }
    }

    @ViewBuilder private var crateBlock: some View {
        switch match {
        case .inCatalog(let song, let info):
            artwork(info.artworkURL)
            Text(song.name).font(.title2.bold()).foregroundStyle(Theme.fg)
            Text(song.artist).font(.headline).foregroundStyle(Theme.fgDim)
            Label("In your crate", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            NavigationLink(value: song) {
                Label("Open song", systemImage: "chevron.right.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, 4)

        case .notInCatalog(let info):
            artwork(info.artworkURL)
            Text(info.title ?? "Unknown title").font(.title2.bold()).foregroundStyle(Theme.fg)
            Text(info.artist ?? "Unknown artist").font(.headline).foregroundStyle(Theme.fgDim)
            Label("Not in your crate", systemImage: "questionmark.circle")
                .foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder private func artwork(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Theme.bgRaised)
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgRaised)
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: "music.note").foregroundStyle(Theme.fgDim))
        }
    }
}
