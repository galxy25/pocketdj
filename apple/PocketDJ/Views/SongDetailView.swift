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
    @Environment(CollectionsStore.self) private var collections
    /// Optional-degrade (the AddToCollectionView `writeBack` pattern): previews/tests that
    /// render the detail standalone lose only the Suggested-collections rows.
    @Environment(RecommendationService.self) private var recEngine: RecommendationService?
    @Environment(\.dismiss) private var dismiss
    let song: IndexSong
    /// The stack this detail was pushed onto, when it HAS one. Every presentation now passes
    /// it (RootView, the Shazam sheet, and the two song-detail sheets, which grew their own
    /// path + `pocketDJDestinations`), so the artist/album hotlinks can push DIRECTLY —
    /// the mechanism `AlbumDetailView` has always used and the only one that works.
    ///
    /// The nil default is a compile-compatibility fallback for any future call site that
    /// genuinely has no stack; it keeps the old `dismiss()` + `IntentRoute` round trip, which
    /// is what produced the blank screen and must not be the default path.
    var path: Binding<NavigationPath>? = nil
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
    /// Recommendation-engine collection suggestions for THIS song (empty = section hidden).
    @State private var collectionSuggestions: [RecommendationService.CollectionSuggestion] = []
    /// Suggestions the user tapped "Add" on this visit — render as checkmarks immediately.
    @State private var addedSuggestionIds: Set<String> = []

    /// Always read the latest (possibly edited) version from the catalog.
    private var current: IndexSong { app.songsById[song.id] ?? song }
    private var album: IndexAlbum? { current.albumId.flatMap { app.albumsById[$0] } }

    /// The provisional Discover entry behind this song, when it is one. Carries the album
    /// identity a ＋Add now records (`albumAppleMusicId`) even though no catalog album exists
    /// for it — that id is what turns the album line into a tappable PREVIEW.
    private var discoverEntry: DiscoverAddsStore.Entry? {
        rips.discoverAdds?.entry(forSongId: current.id)
    }

    /// The Apple Music album this song belongs to, for songs whose album is NOT in the
    /// catalog. Two sources, in order: what MusicKit already resolved for the library
    /// affordance (free — `resolveForLibrary` fetches the album relationship and this view
    /// used to throw it away), then the Discover entry's recorded album id.
    private var albumRef: AppleMusicAlbumRef? {
        if let resolved = libraryResolution?.album { return resolved }
        guard let e = discoverEntry, let cid = e.albumAppleMusicId, !cid.isEmpty else { return nil }
        return AppleMusicAlbumRef(
            storeID: cid,
            title: e.album ?? "Album",
            artist: e.artist,
            year: e.year,
            artworkURL: (e.albumArtworkUrl ?? e.artworkUrl).flatMap(URL.init(string:)),
            url: nil)
    }

    /// The album's NAME wherever it can be known — catalog album, resolved/recorded ref, or
    /// the bare name the Discover row carried. Drives both the header line and the "Album"
    /// metadata row, which used to be blank for every Discover add.
    private var albumName: String? {
        album?.name ?? albumRef?.title ?? discoverEntry?.album
    }

    /// Cover art URL for a song with no catalog album (the ref's art, else the row's).
    private var fallbackArtworkURL: URL? {
        albumRef?.artworkURL
            ?? discoverEntry.flatMap { ($0.albumArtworkUrl ?? $0.artworkUrl).flatMap(URL.init(string:)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Cover art used to require a CATALOG album, so a Discover-added song showed
                // none at all. Fall back to the album reference's / the added row's artwork.
                if let album {
                    CoverImage(album: album)
                        .frame(width: 220, height: 220)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("song-detail-art")
                } else if let url = fallbackArtworkURL {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Theme.bgRaised)
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
                suggestedCollections
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
        // Recommendation-engine collection suggestions — gated on the engine (nothing fires
        // while it's off; the service's own `isEnabled` guard is the privacy gate).
        .task(id: current.id) {
            collectionSuggestions = []; addedSuggestionIds = []
            if let rec = recEngine, rec.isEnabled {
                collectionSuggestions = await rec.collectionSuggestions(for: current.id)
            }
        }
    }

    /// "Suggested collections" rows — the engine's per-song collection matches. Hidden when
    /// there are none (engine off, offline, nothing above threshold). Rows whose collection no
    /// longer resolves locally are dropped at render.
    @ViewBuilder private var suggestedCollections: some View {
        let rows = collectionSuggestions.filter { resolvesLocally($0) }
        if !rows.isEmpty {
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested collections").font(.caption.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(Theme.fgDim)
                ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { idx, sug in
                    HStack(spacing: 10) {
                        Image(systemName: sug.kind == "pocket" ? "rectangle.stack" : "music.note.list")
                            .foregroundStyle(Theme.accent2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sug.name).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                            if let reason = sug.reasons.first {
                                Text(reason).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                            }
                        }
                        Spacer()
                        if addedSuggestionIds.contains(sug.id) || isMember(sug) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        } else {
                            Button("Add") { addToSuggestion(sug) }
                                .buttonStyle(.bordered)
                                .tint(Theme.accent2)
                        }
                    }
                    .accessibilityIdentifier("song-suggested-collection-\(idx)")
                }
            }
        }
    }

    private func resolvesLocally(_ sug: RecommendationService.CollectionSuggestion) -> Bool {
        sug.kind == "pocket" ? collections.pocket(sug.id) != nil : collections.playlist(sug.id) != nil
    }

    /// Already a member (stale server snapshot) → checkmark, no dup add.
    private func isMember(_ sug: RecommendationService.CollectionSuggestion) -> Bool {
        sug.kind == "pocket"
            ? collections.pocket(sug.id)?.songIds.contains(current.id) ?? false
            : collections.playlist(sug.id, contains: current.id)
    }

    private func addToSuggestion(_ sug: RecommendationService.CollectionSuggestion) {
        let kind: AddTarget.Kind = sug.kind == "pocket" ? .pocket : .playlist
        // The generic addSong(_:to:) choke point — stamps activity + write-back via the
        // existing seams, exactly like the Add sheet.
        collections.addSong(current.id, to: AddTarget(kind: kind, id: sug.id, sequenceId: nil))
        addedSuggestionIds.insert(sug.id)
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
            // Artist + album are HOTLINKS into the Browser (Levi 2026-07-18).
            //
            // They PUSH onto the stack this view was given — the mechanism AlbumDetailView
            // has always used (and whose UI test has always passed). They used to
            // `dismiss()` and park an `IntentRoute`, which RootView consumed by re-rooting
            // the path, swapping the section and staging the append 450 ms later. That round
            // trip DROPPED the push: the destination rendered blank (proven on a plain
            // catalog song, 2026-08-07). Every presentation now supplies a path AND registers
            // `pocketDJDestinations`, so the long way round is no longer needed.
            hotlink(id: "artist-hotlink", value: Artist(name: current.artist),
                    route: .artist(current.artist)) {
                Text(current.artist).font(.title3).foregroundStyle(Theme.accent)
            }
            KeyChip(key: current.key, camelot: current.camelot)
            if let src = app.source(ofSong: current.id) {
                Tag(text: src, color: Theme.fgDim)
                    .accessibilityIdentifier("source-tag")
            }
            albumLink
        }
    }

    /// The album line. Shown whenever an album NAME is known — from the catalog album, or
    /// (for a Discover ＋Add whose album isn't a catalog citizen) from the provisional entry.
    /// Three outcomes, and none of them is a dead tap:
    ///   • catalog album      → push the real `IndexAlbum`
    ///   • Apple Music id only → push an `AppleMusicAlbumRef` → the PREVIEW screen, where the
    ///                           giant ＋ pulls the whole album in
    ///   • name only           → plain, unlinked label (nothing to open)
    @ViewBuilder private var albumLink: some View {
        if let album {
            hotlink(id: "album-hotlink", value: album, route: .album(album.id)) {
                Label(album.name, systemImage: "rectangle.stack").font(.callout)
            }
            .foregroundStyle(Theme.accent)
        } else if let ref = albumRef {
            hotlink(id: "album-hotlink", value: ref, route: nil) {
                Label(ref.title, systemImage: "rectangle.stack").font(.callout)
            }
            .foregroundStyle(Theme.accent)
        } else if let name = albumName {
            Label(name, systemImage: "rectangle.stack")
                .font(.callout)
                .foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("album-plain")
        }
    }

    /// One hotlink button: push when we have a stack, else fall back to the legacy
    /// cross-stack route (only reachable from a presentation that passed no path).
    /// `route` nil ⇒ there IS no legacy equivalent, so a path-less host simply can't link it.
    private func hotlink<V: Hashable, L: View>(id: String, value: V, route: IntentRoute?,
                                               @ViewBuilder label: () -> L) -> some View {
        Button {
            if let path {
                path.wrappedValue.append(value)
            } else if let route {
                dismiss()
                intents.pendingRoute = route
            }
        } label: { label() }
        .buttonStyle(.plain)
        .disabled(path == nil && route == nil)
        .accessibilityIdentifier(id)
    }

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        r.append(("Artist", current.artist))
        // `albumName`, not `album?.name`: a Discover-added song has no catalog album, and
        // showing no Album row at all is what made its detail screen look empty.
        if let name = albumName { r.append(("Album", name)) }
        if let n = current.trackNumber ?? discoverEntry?.trackNumber { r.append(("Track #", String(n))) }
        if let y = current.year ?? discoverEntry?.year ?? albumRef?.year { r.append(("Year", String(y))) }
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
