import SwiftUI

/// Song metadata viewer — reached by tapping a song in the songs browser or in
/// an album's track table. Links back to its album, and supports editing.
struct SongDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(LyricsStore.self) private var lyricsStore: LyricsStore?
    @Environment(RipsStore.self) private var rips
    @Environment(StreamingStore.self) private var streaming
    @Environment(IntentServices.self) private var intents
    @Environment(\.dismiss) private var dismiss
    let song: IndexSong
    @State private var showEdit = false
    @State private var showAdd = false
    /// "Remove from Library" (PocketDJ catalog) confirmation — only for user-added provisional
    /// items (Discover ＋Add / Imported). Distinct from the Apple Music library affordance below.
    @State private var showRemoveFromLibraryConfirm = false
    /// Apple Music LIBRARY affordance (the platter long-press ask): resolved
    /// membership for AM-backed tracks → "in your library" / ＋ Add / open-in-Music.
    @State private var libraryResolution: AppleMusicResolution?
    @State private var addingToLibrary = false
    @State private var addedToLibrary = false
    @State private var libraryError: String?
    /// Lazily-loaded, on-disk-cached lyrics (nil until loaded / when absent).
    @State private var lyrics: String?
    /// Stem-audition panel (SongDetail-ONLY): toggled by the stem glyph, owns the synced
    /// `StemPlayer` so playback survives the panel's internal re-renders. Stopped on disappear.
    @State private var showStems = false
    @State private var stemPlayer = StemPlayer()

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
                appleMusicLibrary
                catalogLibrary
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
                ShareLink(item: ShareText.forSong(current),
                          subject: Text("\(current.name) — \(current.artist)")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share this song")
                .accessibilityIdentifier("song-share")
                Button { showAdd = true } label: { Image(systemName: "plus.circle") }
                    .accessibilityIdentifier("add-song-to")
                Button("Edit") { showEdit = true }.accessibilityIdentifier("edit-song")
            }
        }
        .sheet(isPresented: $showEdit) { EditSongView(song: current) }
        .sheet(isPresented: $showAdd) { AddToCollectionView(item: .song(current.id)) }
        .confirmationDialog("Remove from Library?", isPresented: $showRemoveFromLibraryConfirm,
                            titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) {
                app.removeFromLibrary(songId: current.id)
                dismiss()   // the song is gone from the catalog — leave the now-orphaned detail view
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(current.name)” will be removed from your library and won't appear in Recently Added. This won't delete it from Apple Music.")
        }
        // Lyrics: fetch-once + on-disk cache, only when this song's `lyricsStatus == "found"`.
        .task(id: current.id) { lyrics = await lyricsStore?.lyrics(for: current) }
        // Refresh the rips manifest so the stem glyph reflects the latest stemmed state (a job
        // that finished while this view was elsewhere) without a manual reload.
        .task(id: current.id) { await rips.refreshManifest() }
        // Tear down stem playback when leaving the detail screen.
        .onDisappear { stemPlayer.stop(); showStems = false }
        // Apple Music library membership — storeID when the catalog (or an amrec_ ad-hoc
        // id) knows it, else a title/artist catalog search. Provider-unavailable (offline,
        // unit/UI fixtures) simply resolves nothing and the section stays hidden.
        .task(id: current.id) {
            libraryResolution = nil; addedToLibrary = false; libraryError = nil
            guard streaming.appleMusicProvider?.isAvailable == true,
                  let contributor = streaming.providers.libraryContributors.first else { return }
            let storeID = current.appleMusicId ?? SongLibraryAffordance.adHocStoreID(current.id)
            libraryResolution = await contributor.resolveForLibrary(
                storeID: storeID, title: current.name, artist: current.artist)
        }
    }

    /// The library row: membership state or the ＋ Add affordance (macOS, where MusicKit
    /// can't add, deep-links to Music instead — the recognizer flow's rule).
    @ViewBuilder private var appleMusicLibrary: some View {
        let affordance = SongLibraryAffordance.decide(
            resolution: libraryResolution,
            canAdd: streaming.providers.libraryContributors.first?.canAddToLibrary ?? false)
        if affordance != .none {
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                if addedToLibrary || affordance == .inLibrary {
                    Label("In your Apple Music library", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("song-am-in-library")
                } else if case .add(let storeID) = affordance {
                    Button {
                        addToLibrary(storeID: storeID)
                    } label: {
                        if addingToLibrary { ProgressView().controlSize(.small) }
                        else { Label("Add to Apple Music Library", systemImage: "plus.circle") }
                    }
                    .disabled(addingToLibrary)
                    .accessibilityIdentifier("song-add-to-am-library")
                } else if case .openLink(let url) = affordance {
                    Link(destination: url) {
                        Label("Add in Apple Music…", systemImage: "arrow.up.forward.app")
                    }
                    .accessibilityIdentifier("song-open-in-am")
                }
                if let libraryError {
                    Text(libraryError).font(.caption).foregroundStyle(Theme.danger)
                }
                Spacer()
            }
        }
    }

    /// The PocketDJ-catalog "Remove from Library" row — shown ONLY for user-added provisional items
    /// (Discover ＋Add / Imported transfers), the inverse of the ＋Add gesture. Removing drops the
    /// item from the live catalog, logs a catalog-remove History event, and (via the dedupe) takes
    /// it out of Recently Added. Real catalog sources and profile custom-audio are not offered here.
    @ViewBuilder private var catalogLibrary: some View {
        if app.isRemovableFromLibrary(songId: current.id) {
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    showRemoveFromLibraryConfirm = true
                } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
                .accessibilityIdentifier("song-remove-from-library")
                Spacer()
            }
        }
    }

    private func addToLibrary(storeID: String) {
        guard let contributor = streaming.providers.libraryContributors.first else { return }
        addingToLibrary = true; libraryError = nil
        Task {
            do {
                try await contributor.addSongToLibrary(storeID: storeID)
                addedToLibrary = true
            } catch {
                libraryError = "Couldn't add: \(error.localizedDescription)"
            }
            addingToLibrary = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.name).font(.title2.bold()).foregroundStyle(Theme.fg)
            // Artist + album are HOTLINKS into the Browser (Levi 2026-07-18). They route
            // via IntentRoute (not NavigationLink) so they work from EVERY presentation —
            // the browser push, the platter long-press sheet, the mix-session sheet —
            // where an ad-hoc NavigationStack has no destinations registered. dismiss()
            // closes a sheet first (a no-op-ish pop in the pushed context, whose stack
            // the route consumption resets anyway).
            Button {
                let artist = current.artist
                dismiss()
                intents.pendingRoute = .artist(artist)
            } label: {
                Text(current.artist).font(.title3).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artist-hotlink")
            KeyChip(key: current.key, camelot: current.camelot)
            if let src = app.source(ofSong: current.id) {
                Tag(text: src, color: Theme.fgDim)
                    .accessibilityIdentifier("source-tag")
            }
            if let album {
                Button {
                    let id = album.id
                    dismiss()
                    intents.pendingRoute = .album(id)
                } label: {
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

    /// Bottom action bar: the ♥ favorite toggle + the SAME ▶ play / ⤓ download transport used
    /// in every track row, plus the slide-out streaming / waveform inline player that reveals
    /// below it on Play.
    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            HStack(spacing: 12) {
                Text("Play").font(.caption.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(Theme.fgDim)
                Spacer()
                // ♥ lives HERE, in the in-content action cluster, NOT in the toolbar: on
                // iPhone the toolbar's primaryAction group overflows into a nested "More"
                // menu, which would bury a one-tap primary action two taps deep.
                FavoriteToggle(songId: current.id, appleMusicId: current.appleMusicId, font: .title3)
                // Queue actions live in the in-content cluster for the same reason ♥ does: on
                // iPhone the toolbar's primaryAction group overflows into a nested "More".
                // Rendered only while a set is running (QueueMenuItems is empty otherwise), so
                // the menu button itself is conditional — an empty Menu is an inert glyph.
                if sequencer.isRunning {
                    Menu {
                        QueueMenuItems(songs: [current])
                    } label: {
                        Image(systemName: "text.append").font(.title3)
                    }
                    .accessibilityIdentifier("song-queue-menu")
                }
                RowTransport(song: (id: current.id, title: current.name, artist: current.artist),
                             startMs: nil,
                             // SongDetail ONLY: a stemmed song's glyph slides out the audition
                             // panel (the e2e stem test bed) instead of re-stemifying.
                             onStemGlyph: { withAnimation(.easeInOut(duration: 0.22)) { showStems.toggle() } })
            }
            // NOTE: no `.accessibilityIdentifier` on this container — SwiftUI propagates a
            // container id onto every descendant, clobbering RowTransport's own
            // `row-play-<id>` / `row-download-<id>` ids (same trap as InlinePlayerPanel).
            InlinePlayerSlot(songId: current.id)
            if showStems {
                StemAuditionPanel(song: (id: current.id, title: current.name, artist: current.artist),
                                  player: stemPlayer)
            }
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

/// Pure decision for the Apple Music LIBRARY row (unit-tested) — the recognizer
/// reducer's shape, minus album deep-links: membership wins, then ＋ Add where the
/// platform can write the library, then the Music deep link (macOS), else nothing.
enum SongLibraryAffordance: Equatable {
    case none
    case inLibrary
    case add(storeID: String)
    case openLink(URL)

    static func decide(resolution: AppleMusicResolution?, canAdd: Bool) -> SongLibraryAffordance {
        guard let r = resolution else { return .none }
        if r.inLibrary { return .inLibrary }
        if canAdd { return .add(storeID: r.songStoreID) }
        if let url = r.songURL { return .openLink(url) }
        return .none
    }

    /// `amrec_<storeId>` ad-hoc rip ids carry their Apple Music store id in the name
    /// (the recognizer/Discover convention) — recover it for membership resolution.
    static func adHocStoreID(_ songId: String) -> String? {
        guard songId.hasPrefix("amrec_") else { return nil }
        let raw = String(songId.dropFirst("amrec_".count))
        return !raw.isEmpty && raw.allSatisfy(\.isNumber) ? raw : nil
    }
}
