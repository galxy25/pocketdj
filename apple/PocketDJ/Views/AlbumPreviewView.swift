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
    ///
    /// `adHocPrefix` is the ONLY thing that differs between a track and a whole album: the three
    /// routes are identical, but an album arrives under `amrec_album_<id>` rather than
    /// `amrec_<id>` (the convention `RipsStore` synthesizes). The release feed passes that prefix
    /// so "does he already have this album" is answered by THIS predicate — a second one would
    /// start identical and drift the first time either is fixed.
    ///
    /// `localRecordMatch` is the FOURTH route, and the only one that is not an id: the caller has
    /// resolved the release to a record already in the library by artist + title (see
    /// `AppModel.ownedAlbumRecordIndex(forArtistName:artistId:)`). It exists as a parameter rather
    /// than the caller pre-deciding and passing a synthetic id, so this function stays the one
    /// place ownership is decided and a future change here can still veto it. Defaults to `false`,
    /// so the track-level callers are untouched — a TRACK has no such resolution.
    static func owns(storeID: String,
                     catalogSongIds: Set<String>,
                     catalogAppleMusicIds: Set<String>,
                     rippedSongIds: Set<String>,
                     adHocPrefix: String = "amrec_",
                     localRecordMatch: Bool = false) -> Bool {
        let adHoc = adHocPrefix + storeID
        return catalogSongIds.contains(adHoc)
            || catalogAppleMusicIds.contains(storeID)
            || rippedSongIds.contains(adHoc)
            || localRecordMatch
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

/// How far the SEPARATE "Download to device" request has got. Since the ＋ stopped capturing
/// audio (see `RipsStore.AlbumAddIntent`), this button is the only way to get an added album's
/// audio onto the device — so it has to REPORT, not just fire and go quiet. A real-time capture
/// takes minutes per track; a button that flipped straight back to "Download to device" would
/// read as "nothing happened" and invite a second request for work already running.
///
/// PURE, like `AlbumOwnership` above: "the button said the wrong thing" is not a defect any
/// existence assertion catches.
enum AlbumDownloadState: Equatable {
    case idle
    case working(done: Int, total: Int)
    case done(total: Int)
    /// Settled with at least one track that will never land — `message` is the first failure.
    case failed(done: Int, total: Int, message: String)

    /// `onDevice` = tracks whose burned file is present; `errors` = per-track failure messages.
    /// A track that is neither is still in flight. No ids ⇒ nothing was requested ⇒ `.idle`.
    static func of(ids: [String], onDevice: Set<String>, errors: [String: String]) -> AlbumDownloadState {
        guard !ids.isEmpty else { return .idle }
        let done = ids.filter { onDevice.contains($0) }.count
        if done >= ids.count { return .done(total: ids.count) }
        let failures = ids.filter { !onDevice.contains($0) }.compactMap { errors[$0] }
        if done + failures.count >= ids.count {
            return .failed(done: done, total: ids.count, message: failures[0])
        }
        return .working(done: done, total: ids.count)
    }

    var label: String {
        switch self {
        case .idle: return "Download to device"
        case let .working(done, total): return "Downloading… \(done)/\(total)"
        case .done: return "On this device"
        case let .failed(done, total, message):
            return done == 0 ? message : "\(done)/\(total) downloaded — \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .working: return "arrow.down.circle"
        case .done: return "internaldrive.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Only a settled state may be tapped again: idle starts it, a failure retries the tracks
    /// that never landed. Tapping mid-capture would be a no-op the user reads as a dead button.
    var isTappable: Bool {
        switch self {
        case .idle, .failed: return true
        case .working, .done: return false
        }
    }
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
    /// The burn ids the download request was made under — the handle `downloadState` reports
    /// against. Empty until the user actually taps Download (idle).
    @State private var downloadIds: [String] = []

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
            //
            // Gated on the RIP SERVER, not on MusicKit: preparing a copy is the server's job,
            // and the old `canUseMusicKit` gate both hid the button from server-only users and
            // showed it to subscribers with no server, where it could only ever fail. It is the
            // ONLY route to the audio now that the ＋ captures nothing, so the gate has to name
            // the thing it actually needs.
            if rips.hasServer && !tracks.isEmpty {
                let state = downloadState
                Button { downloadToDevice() } label: {
                    Label {
                        Text(state.label)
                    } icon: {
                        if case .working = state { ProgressView().controlSize(.small) }
                        else { Image(systemName: state.systemImage) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(downloadTint(state))
                }
                .buttonStyle(.plain)
                .disabled(!state.isTappable)
                .accessibilityIdentifier("album-preview-download")
            }
        }
    }

    /// Live download status from the burn store's per-track facts. `items[id]?.state == .ready`
    /// rather than `localURL(forSong:)`: the latter stats the filesystem per call, and this is
    /// read from `body` once per track.
    private var downloadState: AlbumDownloadState {
        guard !downloadIds.isEmpty else { return .idle }
        let onDevice = Set(downloadIds.filter { burns.items[$0]?.state == .ready })
        var errors: [String: String] = [:]
        for id in downloadIds { errors[id] = burns.ripBurnErrorMessage(id) }
        return AlbumDownloadState.of(ids: downloadIds, onDevice: onDevice,
                                     errors: errors.compactMapValues { $0 })
    }

    private func downloadTint(_ s: AlbumDownloadState) -> Color {
        switch s {
        case .idle: return Theme.accent2
        case .working: return Theme.fgDim
        case .done: return .green
        case .failed: return Theme.danger
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
    /// never lands settles the album as PARTIAL instead of spinning forever. A LIBRARY-ONLY add
    /// (this screen's ＋) requested no copies at all, so the entry-aware overload reads it as
    /// `.added` immediately rather than waiting on rips that were never queued.
    @ViewBuilder private func progressCapsule(_ entry: DiscoverAddsStore.AlbumEntry) -> some View {
        let ids = entry.trackIds ?? []
        let readyIds = Set(ids.filter { rips.manifest[$0] != nil })
        let erroredIds = Set(ids.filter { rips.jobs[$0]?.phase == .error })
        let state = DiscoverAlbumAddState.of(entry: entry, readyIds: readyIds, erroredIds: erroredIds)
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

    /// The giant ＋: the whole-album add — Apple Music library write (where the platform
    /// allows), and ONE batched provisional album+songs inject. `.libraryOnly`: it captures
    /// NOTHING. The tracks stream through the user's subscription the moment they land, and
    /// the audio only comes down when the user asks for it, via "Download to device" below.
    ///
    /// This is the fix for Levi's device report — "I added the album … in the new tile and it
    /// is ripping the whole album … it should add the items to the users apple music library
    /// but not rip unless they hit download". The screen inherited its ripping from the Shazam
    /// recognizer flow it was extracted from, where add-then-rip WAS the intent; reusing it for
    /// the New tile brought a promise the ＋'s own wording ("Add album to your library") never
    /// made. The Discover search album row still passes `.andPrepareCopies` — see its `add()`.
    private func addAlbum() {
        let hit = RipsStore.DiscoverAlbumHit(ref: ref, trackCount: tracks.isEmpty ? nil : tracks.count)
        let lib = contributor
        #if os(macOS)
        if (lib?.canAddToLibrary ?? false) == false, let u = ref.url { openURL(u) }
        #endif
        adding = true; errorText = nil
        Task {
            await rips.discoverAddAlbum(hit, library: lib, intent: .libraryOnly)
            if let e = rips.discoverError { errorText = e }
            adding = false
        }
    }

    /// Secondary: pull the audio onto the device (what the recognizer's album screen always
    /// did). Separate button, separate wording — adding to the library and downloading are
    /// different promises and must not hide behind one tap. Now that the ＋ captures nothing,
    /// this is the ONLY way to get the audio from this screen, so its state is tracked (the
    /// ids are held so `downloadProgress` can report against BurnStore) rather than the button
    /// flipping back to idle the instant the request is handed off.
    private func downloadToDevice() {
        guard !tracks.isEmpty else { return }
        let payload = tracks.map { t -> BurnStore.RipBurnTrack in
            // O(1) through the revision-keyed Apple Music id memo, with the recognizer's
            // normalized scan only as a fallback for a track no catalog row claims. The scan
            // alone was O(catalog) PER TRACK — ~93k rows × a full album, on the main actor.
            let catalogID = app.songId(forAppleMusicId: t.storeID)
                ?? AppleMusicRecognition.indexSong(storeID: t.storeID, title: t.title,
                                                   artist: t.artist, in: app.songs)?.id
            let id = AppleMusicRecognition.burnSongID(catalogSongID: catalogID, storeID: t.storeID)
            return BurnStore.RipBurnTrack(id: id, title: t.title, artist: t.artist,
                                          appleMusicId: t.storeID,
                                          lengthMs: t.durationSeconds.map { Int(($0 * 1000).rounded()) })
        }
        downloadIds = payload.map(\.id)
        burns.startRipAndBurnAlbum(payload)
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
