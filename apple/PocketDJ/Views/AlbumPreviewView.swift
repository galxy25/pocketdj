import SwiftUI

// ============================================================================
// MARK: - Ownership (pure — unit-tested off the view)
// ============================================================================

/// How much of an album the user already has. Drives the ＋ button's wording, the per-row
/// ✓ ticks, and whether the screen offers "Open album" instead of an add at all.
///
/// PURE on purpose: a view that decides this inline can only be checked by driving the whole
/// UI, and "the button said the wrong thing" is exactly the class of defect that ships green.
enum AlbumOwnership: Equatable {
    case none(total: Int)
    case partial(owned: Int, total: Int)
    case owned(total: Int)

    /// Whether the user has THIS track, by any of the three routes a track can arrive:
    ///   • the provisional Discover/recognizer id (`amrec_<storeID>`) is in the catalog,
    ///   • some catalog song claims that Apple Music id (the real indexed song, post-supersede),
    ///   • the rips manifest holds a prepared copy.
    static func owns(storeID: String,
                     catalogSongIds: Set<String>,
                     catalogAppleMusicIds: Set<String>,
                     rippedSongIds: Set<String>) -> Bool {
        let adHoc = "amrec_\(storeID)"
        return catalogSongIds.contains(adHoc)
            || catalogAppleMusicIds.contains(storeID)
            || rippedSongIds.contains(adHoc)
    }

    /// Roll the per-track answer up. An album with NO known tracks is `.none(total: 0)` —
    /// "you own all zero tracks" would wrongly hide the ＋ on an album we simply couldn't
    /// expand (offline, no server, not in the catalog).
    static func of(trackStoreIDs: [String],
                   catalogSongIds: Set<String>,
                   catalogAppleMusicIds: Set<String>,
                   rippedSongIds: Set<String>) -> AlbumOwnership {
        let total = trackStoreIDs.count
        guard total > 0 else { return .none(total: 0) }
        let owned = trackStoreIDs.reduce(0) {
            $0 + (owns(storeID: $1, catalogSongIds: catalogSongIds,
                       catalogAppleMusicIds: catalogAppleMusicIds,
                       rippedSongIds: rippedSongIds) ? 1 : 0)
        }
        if owned == 0 { return .none(total: total) }
        if owned >= total { return .owned(total: total) }
        return .partial(owned: owned, total: total)
    }

    /// The ＋ button's title. "Add remaining (n)" is the honest wording for a part-owned
    /// album — "Add album" would imply re-adding what the user already has.
    var addTitle: String {
        switch self {
        case .none: return "Add album to your library"
        case let .partial(owned, total): return "Add remaining (\(total - owned))"
        case .owned: return "In your library"
        }
    }

    var isFullyOwned: Bool { if case .owned = self { return true }; return false }
}

/// Why a preview has nothing to show — each case names the ACTUAL reason so the screen is
/// never just empty. Pure so the mapping from (offline, hasServer, canContribute) to a
/// message is checkable without a network.
enum AlbumPreviewUnavailable: Equatable {
    case offline
    case noServer
    case notFound

    static func reason(isOffline: Bool, hasServer: Bool, canUseMusicKit: Bool) -> AlbumPreviewUnavailable {
        if isOffline { return .offline }
        if !hasServer && !canUseMusicKit { return .noServer }
        return .notFound
    }

    var title: String {
        switch self {
        case .offline: return "You’re offline"
        case .noServer: return "No import server configured"
        case .notFound: return "Not in the Apple Music catalog"
        }
    }

    var message: String {
        switch self {
        case .offline: return "Connect to load this album’s track list."
        case .noServer: return "Add one in Settings ▸ Import server, or sign in to Apple Music."
        case .notFound: return "We couldn’t find this album’s track list."
        }
    }

    var systemImage: String {
        switch self {
        case .offline: return "wifi.slash"
        case .noServer: return "server.rack"
        case .notFound: return "questionmark.square.dashed"
        }
    }
}

// ============================================================================
// MARK: - The preview screen
// ============================================================================

/// An album you do NOT own yet, made browsable: cover · title · artist · year · runtime ·
/// track list, with a GIANT ＋ that pulls the whole album into your library and populates
/// its metadata.
///
/// This began as `RecognizedAlbumView`, reachable only from the Shazam sheet. It is now a
/// first-class destination registered by `pocketDJDestinations`, so ANY song whose album
/// isn't in the catalog can link to it — which is the feature Levi asked for ("a preview of
/// the album detail screen with a giant plus button to add the album and fully populate the
/// metadata").
///
/// DATA: three tiers, degrading to something readable rather than to a blank screen.
///   1. MusicKit (`albumTracks` / `album(storeID:)`) — needs an Apple Music subscription.
///   2. The rip server's subscription-free iTunes proxy (`/album-tracks`) — every tester.
///   3. Neither — whatever the passed-in reference already holds, plus a named reason.
struct AlbumPreviewView: View {
    let album: AppleMusicAlbumRef
    /// The stack this was pushed onto — the artist hotlink and "Open album" push onto it.
    var path: Binding<NavigationPath>? = nil

    @Environment(AppModel.self) private var app
    @Environment(RipsStore.self) private var rips
    @Environment(StreamingStore.self) private var streaming
    @Environment(BurnStore.self) private var burns
    @Environment(\.openURL) private var openURL

    /// The album as finally resolved (the passed-in ref, enriched by whichever tier answered).
    @State private var resolved: AppleMusicAlbumRef?
    @State private var tracks: [AppleMusicSongRow] = []
    @State private var loading = true
    @State private var unavailable: AlbumPreviewUnavailable?
    @State private var adding = false
    @State private var errorText: String?
    @State private var downloading = false

    private var contributor: (any MusicLibraryContributor)? {
        streaming.providers.libraryContributors.first
    }
    private var canAddToLibrary: Bool { contributor?.canAddToLibrary ?? false }
    private var canUseMusicKit: Bool { contributor?.canContribute ?? false }
    private var ref: AppleMusicAlbumRef { resolved ?? album }

    // MARK: derived state

    /// The provisional album row once an add has recorded it — the source of the live n/m.
    private var addedEntry: DiscoverAddsStore.AlbumEntry? {
        rips.discoverAdds?.albums.first { $0.albumId == "amrec_album_\(album.storeID)" }
    }

    /// The REAL catalog album for this Apple Music id, if the user already has it. O(1) via
    /// `AppModel.albumId(forAppleMusicId:)`'s revision-keyed memo, plus the provisional-id
    /// probe — safe to ask from `body`, unlike the recognizer's O(catalog) normalized scan.
    private var catalogAlbum: IndexAlbum? {
        if let id = app.albumId(forAppleMusicId: album.storeID), let a = app.albumsById[id] { return a }
        return app.albumsById["amrec_album_\(album.storeID)"]
    }

    private var ownership: AlbumOwnership {
        AlbumOwnership.of(trackStoreIDs: tracks.map(\.storeID),
                          catalogSongIds: catalogSongIds,
                          catalogAppleMusicIds: catalogAppleMusicIds,
                          rippedSongIds: rippedSongIds)
    }

    /// Only the ids these tracks could possibly match — building the whole catalog's id set
    /// per render would be an O(90k) allocation in `body` (the collections-perf lesson).
    private var catalogSongIds: Set<String> {
        Set(tracks.map { "amrec_\($0.storeID)" }.filter { app.songsById[$0] != nil })
    }
    private var catalogAppleMusicIds: Set<String> {
        Set(tracks.map(\.storeID).filter { app.songId(forAppleMusicId: $0) != nil })
    }
    private var rippedSongIds: Set<String> {
        Set(tracks.map { "amrec_\($0.storeID)" }.filter { rips.manifest[$0] != nil })
    }

    private var totalRuntime: Double {
        tracks.compactMap(\.durationSeconds).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                addSection
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("album-preview-error")
                }
                tracklist
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(ref.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("album-preview")
        .task(id: album.storeID) { await load() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            artwork
                .frame(maxWidth: .infinity, alignment: .center)
            Text(ref.title).font(.title2.bold()).foregroundStyle(Theme.fg)
            // The artist is a hotlink into the Browser, like every other artist in the app.
            Button {
                path?.wrappedValue.append(Artist(name: ref.artist))
            } label: {
                Text(ref.artist).font(.title3).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(path == nil || ref.artist.isEmpty)
            .accessibilityIdentifier("artist-hotlink")
            Text(subtitle).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("album-preview-subtitle")
            if let url = ref.url {
                Button { openURL(url) } label: {
                    Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-preview-open-music")
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let y = ref.year { parts.append(String(y)) }
        if !tracks.isEmpty { parts.append("\(tracks.count) tracks") }
        if totalRuntime > 0 { parts.append(Self.runtime(totalRuntime)) }
        if let g = catalogAlbum?.genre { parts.append(g) }
        return parts.isEmpty ? "Apple Music" : parts.joined(separator: " · ")
    }

    private var artwork: some View {
        Group {
            if let url = ref.artworkURL {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                placeholder: { Rectangle().fill(Theme.bgRaised) }
            } else {
                Rectangle().fill(Theme.bgRaised)
                    .overlay(Image(systemName: "square.stack").font(.largeTitle).foregroundStyle(Theme.fgDim))
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("album-preview-art")
    }

    // MARK: the giant ＋

    @ViewBuilder private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry = addedEntry {
                progressCapsule(entry)
            } else if ownership.isFullyOwned || (catalogAlbum != nil && tracks.isEmpty) {
                ownedCapsule
            } else {
                addButton
            }
            // Downloading the audio to the device is a SEPARATE, secondary intent from
            // "put this album in my library" — the ＋ above populates the catalog.
            if canUseMusicKit && !tracks.isEmpty {
                Button { downloadToDevice() } label: {
                    Label(downloading ? "Downloading…" : "Download to device",
                          systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(downloading ? Theme.fgDim : Theme.accent2)
                }
                .buttonStyle(.plain)
                .disabled(downloading)
                .accessibilityIdentifier("album-preview-download")
            }
        }
    }

    private var addButton: some View {
        Button { addAlbum() } label: {
            Label {
                Text(adding ? "Adding…" : ownership.addTitle)
            } icon: {
                if adding { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus.circle.fill") }
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(adding ? Theme.fgDim : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.bgRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(adding || isOffline)
        .help(isOffline
              ? "Connect to add this album"
              : DiscoverAddWording.addHelp(noun: "album", canAddToLibrary: canAddToLibrary,
                                           opensInMusic: opensInMusic))
        .accessibilityIdentifier("album-preview-add")
    }

    private var ownedCapsule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("In your library", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Theme.bgRaised, in: Capsule())
                .accessibilityIdentifier("album-preview-add")
            if let a = catalogAlbum, path != nil {
                Button { path?.wrappedValue.append(a) } label: {
                    Label("Open album", systemImage: "chevron.right.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-preview-open")
            }
        }
    }

    /// Live n/m from the EXISTING settlement reducer the Discover row uses — a track that
    /// never lands settles the album as PARTIAL instead of spinning forever.
    @ViewBuilder private func progressCapsule(_ entry: DiscoverAddsStore.AlbumEntry) -> some View {
        let ids = entry.trackIds ?? []
        let readyIds = Set(ids.filter { rips.manifest[$0] != nil })
        let erroredIds = Set(ids.filter { rips.jobs[$0]?.phase == .error })
        let state = DiscoverAlbumAddState.of(trackIds: ids, readyIds: readyIds, erroredIds: erroredIds)
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch state {
                case .added:
                    Label("In your library", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold)).foregroundStyle(.green)
                case let .partial(ready, total):
                    Label("\(ready) of \(total) ready — the rest couldn’t be prepared",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                case let .adding(ready, total):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding… \(ready)/\(total)").font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.fgDim)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.bgRaised, in: Capsule())
            .accessibilityIdentifier("album-preview-add")

            if let a = catalogAlbum, path != nil {
                Button { path?.wrappedValue.append(a) } label: {
                    Label("Open album", systemImage: "chevron.right.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-preview-open")
            }
        }
    }

    /// macOS can't write the Apple Music library through MusicKit; the ＋ opens the album in
    /// Music.app there instead (mirrors `DiscoverAlbumRow.add()`), and the help text says so.
    private var opensInMusic: Bool {
        #if os(macOS)
        return canAddToLibrary == false && ref.url != nil
        #else
        return false
        #endif
    }

    private var isOffline: Bool { !rips.hasServer && !canUseMusicKit }

    // MARK: tracklist

    @ViewBuilder private var tracklist: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading tracks…").foregroundStyle(Theme.fgDim)
            }
            .font(.subheadline)
            .accessibilityIdentifier("album-preview-loading")
        } else if tracks.isEmpty {
            let reason = unavailable ?? .notFound
            ContentUnavailableView {
                Label(reason.title, systemImage: reason.systemImage)
            } description: {
                Text(reason.message)
            }
            .accessibilityIdentifier("album-preview-empty")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.storeID) { idx, t in
                    row(index: idx, track: t)
                    if idx < tracks.count - 1 { Divider().overlay(Theme.border) }
                }
            }
        }
    }

    private func row(index: Int, track t: AppleMusicSongRow) -> some View {
        let ownsIt = AlbumOwnership.owns(storeID: t.storeID,
                                         catalogSongIds: catalogSongIds,
                                         catalogAppleMusicIds: catalogAppleMusicIds,
                                         rippedSongIds: rippedSongIds)
        return HStack(spacing: 12) {
            Text("\(t.trackNumber ?? index + 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.subheadline).foregroundStyle(Theme.fg).lineLimit(1)
                Text(t.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            if t.isExplicit == true {
                Text("E").font(.caption2.weight(.bold)).foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
            }
            if let secs = t.durationSeconds {
                Text(Self.runtime(secs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            if ownsIt {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album-preview-track-\(index)")
    }

    // MARK: data

    /// Tier 1 MusicKit → tier 2 the free proxy → tier 3 whatever the ref already held.
    private func load() async {
        loading = true; unavailable = nil
        resolved = album

        // Tier 1 — MusicKit (subscription). Fills in a ref built from a bare id, too.
        if canUseMusicKit, let contributor {
            if album.title.isEmpty || album.title == "Album" || album.artist.isEmpty {
                if let better = await contributor.album(storeID: album.storeID) { resolved = better }
            }
            let rows = await contributor.albumTracks(albumStoreID: album.storeID)
            if !rows.isEmpty { tracks = rows; loading = false; return }
        }

        // Tier 2 — the subscription-free `/album-tracks` proxy. THIS is the fix for a
        // non-subscriber, who previously got "No track list available" and nothing else.
        let expansion = await rips.fetchAlbumExpansion(collectionId: album.storeID)
        if let serverAlbum = expansion.album,
           resolved == nil || resolved?.title.isEmpty != false || resolved?.title == "Album" {
            resolved = serverAlbum.albumRef
        }
        if !expansion.tracks.isEmpty {
            tracks = expansion.tracks.map { t in
                AppleMusicSongRow(storeID: t.id, title: t.title, artist: t.artist,
                                  albumTitle: ref.title, albumStoreID: album.storeID,
                                  trackNumber: t.trackNumber, year: ref.year,
                                  durationSeconds: t.durationMs.map { Double($0) / 1000 },
                                  isExplicit: nil, artworkURL: ref.artworkURL)
            }
            loading = false
            return
        }

        // Tier 3 — nothing to expand. Name the ACTUAL reason; never an empty screen.
        unavailable = AlbumPreviewUnavailable.reason(isOffline: isOffline,
                                                     hasServer: rips.hasServer,
                                                     canUseMusicKit: canUseMusicKit)
        loading = false
    }

    // MARK: actions

    /// The giant ＋: the EXISTING whole-album add — Apple Music library write (where the
    /// platform allows), per-track `amrec_` rip fan-out, and ONE batched provisional
    /// album+songs inject. Deliberately NOT `startRipAndBurnAlbum`: that downloads audio to
    /// the device, which is the secondary action below, not "add this album to my library".
    private func addAlbum() {
        let hit = RipsStore.DiscoverAlbumHit(ref: ref, trackCount: tracks.isEmpty ? nil : tracks.count)
        let lib = contributor
        #if os(macOS)
        if (lib?.canAddToLibrary ?? false) == false, let u = ref.url { openURL(u) }
        #endif
        adding = true; errorText = nil
        Task {
            await rips.discoverAddAlbum(hit, library: lib)
            if let e = rips.discoverError { errorText = e }
            adding = false
        }
    }

    /// Secondary: pull the audio onto the device (what the recognizer's album screen always
    /// did). Separate button, separate wording — adding to the library and downloading are
    /// different promises and must not hide behind one tap.
    private func downloadToDevice() {
        guard !tracks.isEmpty else { return }
        downloading = true
        let payload = tracks.map { t -> BurnStore.RipBurnTrack in
            let catalogID = AppleMusicRecognition.indexSong(
                storeID: t.storeID, title: t.title, artist: t.artist, in: app.songs)?.id
            let id = AppleMusicRecognition.burnSongID(catalogSongID: catalogID, storeID: t.storeID)
            return BurnStore.RipBurnTrack(id: id, title: t.title, artist: t.artist,
                                          appleMusicId: t.storeID,
                                          lengthMs: t.durationSeconds.map { Int(($0 * 1000).rounded()) })
        }
        burns.startRipAndBurnAlbum(payload)
        downloading = false
    }

    /// m:ss for a track, h:mm:ss once an album's total runs past an hour.
    static func runtime(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "" }
        let total = Int(s.rounded())
        let (h, m, sec) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", sec))"
            : "\(m):\(String(format: "%02d", sec))"
    }
}
