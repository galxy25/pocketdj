import SwiftUI

/// The Apple Music block inside the Shazam "Heard it" sheet. Independent of the crate
/// status above it: it resolves the recognized track against the user's Apple Music
/// **library** and offers exactly one primary action —
///   • not linked  → "Connect Apple Music"
///   • in library  → open its album (in-app when the album is in our index, else the
///                    synthesized `RecognizedAlbumView`)
///   • not in library → ＋ "Add to Apple Music" which adds the song to the library and
///     THEN rips + burns it to the device (store-owned, survives sheet dismissal).
///
/// All navigation uses `NavigationLink(value:)` against destinations registered on the
/// sheet's own `NavigationStack`, so the section needs no path binding.
struct AppleMusicRecognitionSection: View {
    let info: ShazamHitInfo

    @Environment(AppModel.self) private var app
    @Environment(StreamingStore.self) private var streaming
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns
    @Environment(\.openURL) private var openURL

    @State private var resolving = true
    @State private var resolution: AppleMusicResolution?
    @State private var adding = false
    @State private var added = false
    @State private var burnSongID: String?
    @State private var errorText: String?

    private var contributor: (any MusicLibraryContributor)? {
        streaming.providers.libraryContributors.first
    }
    private var available: Bool { streaming.appleMusicProvider?.isAvailable ?? false }
    private var canContribute: Bool { contributor?.canContribute ?? false }
    private var canAdd: Bool { contributor?.canAddToLibrary ?? false }

    /// Catalog album id matching the resolved Apple Music album (nil → not in our index).
    private var indexAlbumID: String? {
        guard let album = resolution?.album else { return nil }
        return AppleMusicRecognition.indexAlbum(matching: album, in: app.albums)?.id
    }

    private var action: AppleMusicRecognitionAction {
        AppleMusicRecognition.action(
            available: available, canContribute: canContribute, canAdd: canAdd,
            resolving: adding ? false : resolving,   // while adding we show our own status
            resolution: resolution, indexAlbumID: indexAlbumID)
    }

    var body: some View {
        content
            .task(id: info) { await resolve() }
    }

    @ViewBuilder private var content: some View {
        switch action {
        case .unavailable, .notFound:
            EmptyView()
        case .connect:
            section { connectRow }
        case .checking:
            section {
                Label { Text("Checking your Apple Music library…") } icon: { ProgressView().controlSize(.small) }
                    .font(.subheadline).foregroundStyle(Theme.fgDim)
            }
        case .inLibrary:
            section { inLibraryLabel; burnStatus }
        case .openIndexAlbum(let id):
            section { openIndexAlbumLink(id); burnStatus }
        case .openRecognizedAlbum(let ref):
            section { openRecognizedAlbumLink(ref); burnStatus }
        case .openInMusicApp(let url):
            section { openInMusicRow(url) }
        case .addToLibrary(let storeID, let title, let artist):
            section { addRow(storeID: storeID, title: title, artist: artist); burnStatus }
        }
    }

    /// macOS fallback (no library-write API): send the user to Apple Music to add it.
    private func openInMusicRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Not in your Apple Music library", systemImage: "questionmark.circle")
                .font(.subheadline).foregroundStyle(Theme.fgDim)
            Button { openURL(url) } label: {
                Label("Add in Apple Music", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("am-recog-open-music")
        }
    }

    // MARK: rows

    private var connectRow: some View {
        Button {
            streaming.appleMusicProvider?.login()
            // The consent sheet resolves asynchronously; poll auth for up to ~10s (the
            // status isn't Observable) and resolve once linked, instead of guessing a delay.
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if contributor?.canContribute == true { await resolve(); break }
                }
            }
        } label: {
            Label("Connect Apple Music", systemImage: "link")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("am-recog-connect")
    }

    private var inLibraryLabel: some View {
        Label("In your Apple Music library", systemImage: "checkmark.seal.fill")
            .font(.subheadline).foregroundStyle(.green)
    }

    @ViewBuilder private func openIndexAlbumLink(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inLibraryLabel
            if let album = app.albumsById[id] {
                NavigationLink(value: album) {
                    Label("Open album", systemImage: "square.stack.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("am-recog-open-album")
            }
        }
    }

    @ViewBuilder private func openRecognizedAlbumLink(_ ref: AppleMusicAlbumRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inLibraryLabel
            NavigationLink(value: ref) {
                Label("Open album", systemImage: "square.stack")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("am-recog-open-album")
        }
    }

    @ViewBuilder private func addRow(storeID: String, title: String, artist: String) -> some View {
        // Latch "added" so library-search latency (the just-added song isn't indexed
        // instantly) can't re-offer the ＋ and invite a duplicate add.
        if added {
            Label("Added to Apple Music", systemImage: "checkmark.seal.fill")
                .font(.subheadline).foregroundStyle(.green)
        } else {
            Button {
                add(storeID: storeID, title: title, artist: artist)
            } label: {
                Label {
                    Text(adding ? "Adding…" : "Add to Apple Music")
                } icon: {
                    if adding { ProgressView().controlSize(.small) }
                    else { Image(systemName: "plus.circle.fill") }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(adding ? Theme.fgDim : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(adding)
            .accessibilityIdentifier("am-recog-add")
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    /// Live "downloading to device" status for the post-add rip/burn (driven off the
    /// store's job phase + burned-file presence, both observable).
    @ViewBuilder private var burnStatus: some View {
        if let id = burnSongID {
            if burns.localURL(forSong: id) != nil {
                Label("Saved to device", systemImage: "internaldrive.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if let err = burns.ripBurnErrorMessage(id) {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            } else if burns.isRipBurning(id) || burns.isDownloadingToDevice(id) {
                Label {
                    Text(ripPhaseLabel(rips.jobs[id]?.phase))
                } icon: { ProgressView().controlSize(.mini) }
                    .font(.caption).foregroundStyle(Theme.accent2)
            }
        }
    }

    private func ripPhaseLabel(_ phase: RipsStore.Phase?) -> String {
        switch phase {
        case .some(.queued), .some(.searching): return "Downloading — finding the track…"
        case .some(.ripping), .some(.streaming): return "Downloading — capturing…"
        case .some(.uploading): return "Downloading — finishing…"
        default: return "Downloading to device…"
        }
    }

    // MARK: actions

    private func resolve() async {
        guard let contributor, contributor.canContribute else {
            resolution = nil; resolving = false; return
        }
        resolving = true
        resolution = await contributor.resolveForLibrary(
            storeID: info.appleMusicID, title: info.title, artist: info.artist)
        resolving = false
    }

    /// Add the recognized song to the Apple Music library, THEN rip + burn it to device
    /// (the user's confirmed order). The burn is store-owned so it survives dismissal.
    private func add(storeID: String, title: String, artist: String) {
        guard let contributor else { return }
        adding = true; errorText = nil
        Task {
            do {
                try await contributor.addSongToLibrary(storeID: storeID)
                added = true   // latch — don't re-offer ＋ during library-index lag
                let catalogID = AppleMusicRecognition.indexSong(
                    storeID: storeID, title: title, artist: artist, in: app.songs)?.id
                let id = AppleMusicRecognition.burnSongID(catalogSongID: catalogID, storeID: storeID)
                burnSongID = id
                burns.startRipAndBurn(songId: id, title: title, artist: artist,
                                      appleMusicId: storeID, lengthMs: nil)
                await resolve()   // flips the section to the in-library state
            } catch {
                errorText = error.localizedDescription
            }
            adding = false
        }
    }

    // MARK: chrome

    @ViewBuilder private func section<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            HStack(spacing: 6) {
                Image(systemName: "music.note").font(.caption2)
                Text("Apple Music").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.fgDim)
            body()
        }
        .padding(.top, 4)
    }
}
