import SwiftUI

/// The Apple Music block inside the Shazam "Heard it" sheet. Independent of the crate
/// status above it: it resolves the recognized track against the user's Apple Music
/// **library** and offers exactly one primary action —
///   • not linked  → "Connect Apple Music"
///   • in library  → open its album (in-app when the album is in our index, else the
///                    synthesized `AlbumPreviewView`)
///   • not in library → ＋ "Add to Apple Music", which saves the song to the user's OWN
///     Apple Music library — a complete action in its own right — and THEN separately asks
///     the server to prepare the user's own copy and save it to this device (store-owned,
///     survives sheet dismissal).
///
/// Apple Music itself is playback only: nothing on this screen captures, records or
/// downloads audio from it. The prepare step runs only against media the user owns in their
/// cloud library; a track they don't own is simply a miss — the server returns nothing and
/// never acquires the audio from anywhere else.
///
/// #TOUPDATE: that second half is the TARGET, not current behaviour. `add(storeID:…)` still
/// calls `burns.startRipAndBurn`, and scripts/rip-server.mjs:798 routes every digital-source
/// job to a real-time Apple Music capture ("Digital songs always capture from Apple Music")
/// regardless of what the user owns. Remove this marker once ＋ Add ends at
/// `addSongToLibrary` — or the prepare step reads the user's own cloud library — AND the
/// server fails closed on media the user does not own.
///
/// All navigation uses `NavigationLink(value:)` against destinations registered on the
/// sheet's own `NavigationStack`, so the section needs no path binding.
struct AppleMusicRecognitionSection: View {
    let info: ShazamHitInfo

    @Environment(AppModel.self) private var app
    @Environment(StreamingStore.self) private var streaming
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns
    @Environment(SettingsStore.self) private var settings
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

    /// Live progress for the post-add prepare + save-to-device step (driven off the store's
    /// job phase + burned-file presence, both observable).
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
        // #TOUPDATE: the two "your copy" labels below are the TARGET. Today there is no per-user
        // copy to find or prepare — `AppleMusicRecognition.burnSongID` is deterministic from the
        // Apple Music store id (catalog id, else "amrec_<storeID>"), so every user's request
        // resolves to the same flat, public-read object rips/<songId>.mp3 on a server that
        // reports auth:false. Remove this marker once rips are keyed per user
        // (users/<userId>/rips/<songId>.mp3), the public rips/* grant is gone, and the server
        // authenticates the requester and serves each user only their own copy.
        case .some(.queued), .some(.searching): return "Preparing — finding your copy…"
        case .some(.ripping), .some(.streaming): return "Preparing your copy…"
        case .some(.uploading): return "Preparing — finishing up…"
        default: return "Saving to this device…"
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

    /// Save the recognized song to the user's own Apple Music library — a complete action in
    /// its own right — THEN separately ask the server to prepare the user's own copy and save
    /// it to this device (the user's confirmed order). The save is store-owned so it survives
    /// dismissal.
    ///
    /// This code is AGNOSTIC to how the server fulfils the second step, and must stay that
    /// way. The app states an intent ("prepare this user's copy") and the server decides what
    /// it can honour — its contract is that it works ONLY against media the user owns in their
    /// cloud library, and a track with no such media is simply a miss. Nothing is captured,
    /// recorded or downloaded from Apple Music.
    ///
    /// #TOUPDATE: that contract is the TARGET. Today the server neither restricts itself to
    /// media the user owns nor serves per-user copies — a digital-source job is captured from
    /// Apple Music in real time (scripts/rip-server.mjs:798). Remove this marker once it does.
    private func add(storeID: String, title: String, artist: String) {
        guard let contributor else { return }
        adding = true; errorText = nil
        Task {
            do {
                // EDITION preference (Settings ▸ Apple Music ▸ Explicit versions): swap the
                // recognized store id for its preferred-edition sibling — clean by default,
                // explicit when preferred — when one verifiably exists. Best-effort: any
                // miss keeps the recognized id. (Discover's `discoverAdd` deliberately does
                // NOT do this — a tapped edition row is the user's authoritative pick.)
                var chosen = storeID
                if let provider = streaming.appleMusicProvider {
                    chosen = await VariantResolver.preferredStoreID(
                        storeID: storeID, title: title, artist: artist,
                        preferExplicit: settings.preferExplicitVersions, using: provider)
                }
                try await contributor.addSongToLibrary(storeID: chosen)
                added = true   // latch — don't re-offer ＋ during library-index lag
                let catalogID = AppleMusicRecognition.indexSong(
                    storeID: chosen, title: title, artist: artist, in: app.songs)?.id
                let id = AppleMusicRecognition.burnSongID(catalogSongID: catalogID, storeID: chosen)
                burnSongID = id
                // #TOUPDATE: this is the "prepare the user's own copy" step, but the call it
                // makes today is a real-time Apple Music capture into a shared object. Repoint
                // it at an owned-media prepare that fails closed on anything the user does not
                // own — or delete it, so ＋ Add ends at `addSongToLibrary` above.
                burns.startRipAndBurn(songId: id, title: title, artist: artist,
                                      appleMusicId: chosen, lengthMs: nil)
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
