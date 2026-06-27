import SwiftUI

/// Shown when a recognized track is in the user's Apple Music library but its album is
/// NOT in our index: a lightweight album screen built purely from Apple Music metadata
/// (cover · title · artist · year · tracklist) with a ＋ that adds the whole album to the
/// library AND burns its tracks to the device. Pushed from `AppleMusicRecognitionSection`
/// via `NavigationLink(value: AppleMusicAlbumRef)` (destination registered on the sheet's
/// `NavigationStack`).
struct RecognizedAlbumView: View {
    let album: AppleMusicAlbumRef

    @Environment(StreamingStore.self) private var streaming
    @Environment(BurnStore.self) private var burns
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var tracks: [AppleMusicSongRow] = []
    @State private var loading = true
    @State private var adding = false
    @State private var added = false
    @State private var errorText: String?

    private var contributor: (any MusicLibraryContributor)? {
        streaming.providers.libraryContributors.first
    }
    /// macOS can't write the library via MusicKit → hide ＋ there (the header's
    /// "Open in Apple Music" link is the fallback).
    private var canAdd: Bool { contributor?.canAddToLibrary ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if canAdd { addButton }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(Theme.danger)
                }
                tracklist
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("recognized-album")
        .task(id: album.storeID) { await loadTracks() }
        .toolbar {
            if canAdd {
                ToolbarItem(placement: .primaryAction) {
                    Button { addAlbum() } label: { Label("Add to Library", systemImage: "plus") }
                        .disabled(adding || added)
                        .accessibilityIdentifier("recognized-album-add-toolbar")
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title).font(.title3.bold()).foregroundStyle(Theme.fg)
                Text(album.artist).font(.headline).foregroundStyle(Theme.fgDim)
                if let y = album.year { Text(String(y)).font(.subheadline).foregroundStyle(Theme.fgDim) }
                if let url = album.url {
                    Button { openURL(url) } label: {
                        Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent2)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("recognized-album-open-music")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var artwork: some View {
        Group {
            if let url = album.artworkURL {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                placeholder: { Rectangle().fill(Theme.bgRaised) }
            } else {
                Rectangle().fill(Theme.bgRaised)
                    .overlay(Image(systemName: "square.stack").foregroundStyle(Theme.fgDim))
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: add

    private var addButton: some View {
        Button { addAlbum() } label: {
            Label {
                Text(added ? "Added to Apple Music" : (adding ? "Adding…" : "Add album to Library"))
            } icon: {
                if adding { ProgressView().controlSize(.small) }
                else { Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill") }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(added ? .green : (adding ? Theme.fgDim : Theme.accent))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.bgRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(adding || added)
        .accessibilityIdentifier("recognized-album-add")
    }

    // MARK: tracklist

    @ViewBuilder private var tracklist: some View {
        if loading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading tracks…").foregroundStyle(Theme.fgDim) }
                .font(.subheadline)
        } else if tracks.isEmpty {
            Text("No track list available.").font(.subheadline).foregroundStyle(Theme.fgDim)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.storeID) { idx, t in
                    HStack(spacing: 12) {
                        Text("\(t.trackNumber ?? idx + 1)")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.subheadline).foregroundStyle(Theme.fg).lineLimit(1)
                            Text(t.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let secs = t.durationSeconds {
                            Text(Self.clock(secs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        }
                    }
                    .padding(.vertical, 8)
                    if idx < tracks.count - 1 { Divider().overlay(Theme.border) }
                }
            }
        }
    }

    // MARK: data + actions

    private func loadTracks() async {
        loading = true
        tracks = await contributor?.albumTracks(albumStoreID: album.storeID) ?? []
        loading = false
    }

    private func addAlbum() {
        guard let contributor else { return }
        adding = true; errorText = nil
        Task {
            do {
                try await contributor.addAlbumToLibrary(storeID: album.storeID)
                added = true
                // Add to library FIRST, then rip + burn the tracks to the device. Use the
                // BATCHED path: one shared poll loop (not one 30-min timer per track) against
                // the concurrency-1 real-time ripper.
                let payload = tracks.map { t -> BurnStore.RipBurnTrack in
                    let catalogID = AppleMusicRecognition.indexSong(
                        storeID: t.storeID, title: t.title, artist: t.artist, in: app.songs)?.id
                    let id = AppleMusicRecognition.burnSongID(catalogSongID: catalogID, storeID: t.storeID)
                    return BurnStore.RipBurnTrack(
                        id: id, title: t.title, artist: t.artist, appleMusicId: t.storeID,
                        lengthMs: t.durationSeconds.map { Int(($0 * 1000).rounded()) })
                }
                burns.startRipAndBurnAlbum(payload)
            } catch {
                errorText = error.localizedDescription
            }
            adding = false
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "" }
        let total = Int(s.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
