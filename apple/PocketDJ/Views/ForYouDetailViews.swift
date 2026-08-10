import SwiftUI

// ============================================================================
// MARK: - New releases
// ============================================================================

/// The **New** tile's screen: what the artists the owner plays have put out in the last 30 days.
///
/// Rows push `AppleMusicAlbumRef`, which lands on the existing `AlbumPreviewView` — so ownership
/// ticks, the "Add remaining (n)" wording, and the whole add/rip path come for free instead of
/// being reimplemented here. That reuse is the reason this screen is short.
struct NewReleasesView: View {
    @Environment(ReleaseFeedService.self) private var releaseFeed: ReleaseFeedService?
    @Binding var path: NavigationPath

    var body: some View {
        // OUT NOW first: it is the part he can act on. COMING SOON is real news but nothing can
        // be played from it, so it sits underneath rather than at the top.
        let outNow = releaseFeed?.outNow() ?? []
        let soon = releaseFeed?.comingSoon() ?? []
        List {
            if outNow.isEmpty && soon.isEmpty {
                emptyState.listRowBackground(Color.clear)
            } else {
                section(ReleaseStatus.outNow, outNow)
                section(ReleaseStatus.comingSoon, soon)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("New")
    }

    @ViewBuilder
    private func section(_ status: ReleaseStatus, _ items: [ReleaseFeedItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { push(item.entry) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("new-release-\(item.entry.artistId)")
                }
            } header: {
                Text(status.title).font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("new-release-section-\(status.rawValue)")
            }
        }
    }

    /// A release with no store id can't be previewed — the row simply doesn't navigate rather
    /// than pushing a value that would render as SwiftUI's blank screen.
    private func push(_ e: ArtistReleaseEntry) {
        guard let id = e.releaseId else { return }
        path.append(AppleMusicAlbumRef(
            storeID: id,
            title: e.releaseName ?? "",
            artist: e.artistName,
            year: nil,
            artworkURL: e.releaseArtworkUrl.flatMap { ArtworkTemplate.url($0, size: 160) },
            url: URL(string: "https://music.apple.com/us/album/\(id)")))
    }

    @ViewBuilder private func row(_ item: ReleaseFeedItem) -> some View {
        let e = item.entry
        HStack(spacing: 10) {
            artwork(e)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.releaseName ?? "—").font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                Text(e.artistName).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                HStack(spacing: 6) {
                    if let kind = e.releaseKind {
                        Text(kind.capitalized).font(.caption2).foregroundStyle(Theme.accent)
                    }
                    if let at = e.releaseAtMs {
                        Text(Self.relative(at)).font(.caption2).foregroundStyle(Theme.fgDim)
                    }
                    if e.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Theme.fgDim.opacity(0.3)))
                            .foregroundStyle(Theme.fg)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func artwork(_ e: ArtistReleaseEntry) -> some View {
        let url = e.releaseArtworkUrl.flatMap { ArtworkTemplate.url($0, size: 96) }
        AsyncImage(url: url) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 4).fill(Theme.bgOverlay)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Deliberately coarse ("3 days ago"): the feed window is 30 days, so day resolution is all
    /// the precision the screen can use.
    ///
    /// Future dates get their OWN wording. Apple returns pre-orders, so a release date weeks
    /// ahead is routine — and an age-in-days phrasing collapses every one of them to "Today",
    /// which is the screen confidently stating the opposite of the truth.
    static func relative(_ atMs: Double, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let days = Int(((nowMs - atMs) / 86_400_000).rounded())
        if days < 0 {
            let ahead = -days
            return ahead == 1 ? "Tomorrow" : "In \(ahead) days"
        }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days) days ago"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Theme.fgDim)
            Text("Nothing new in the last 30 days").font(.subheadline).foregroundStyle(Theme.fg)
            Text("New releases appear here as you play the artists you follow.")
                .font(.caption).foregroundStyle(Theme.fgDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(30)
        .accessibilityIdentifier("new-releases-empty")
    }
}

/// Apple's artwork URLs are TEMPLATES carrying literal `{w}`/`{h}` placeholders; requesting one
/// unsubstituted returns a 404, so every consumer must fill them in.
enum ArtworkTemplate {
    static func url(_ template: String, size: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{w}", with: String(size))
            .replacingOccurrences(of: "{h}", with: String(size)))
    }
}

// ============================================================================
// MARK: - Song-list tiles (In Da Zone + per-collection suggestions)
// ============================================================================

/// The screen behind **In Da Zone** and behind each collection tile. Both are "a ranked list of
/// catalog songs with a way to act on them", so they are ONE view with a different title, a
/// different id source, and a different add affordance.
struct ForYouSongListView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(PlayHistoryStore.self) private var history
    @Environment(PlayCountService.self) private var playCounts
    @Environment(SetlistPlayer.self) private var sequencer
    /// The accept/reject log. Optional (a preview/test host renders this screen standalone).
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?

    let route: ForYouTileRoute
    @Binding var path: NavigationPath

    @State private var songIds: [String] = []
    /// Pool per song, for the zone route only — drives the "Buried" badge and the header's blend
    /// readout. Empty for collection routes, which have no pools.
    @State private var pools: [String: ZoneEngine.Pool] = [:]
    @State private var didBuild = false
    /// Ids added on THIS screen — the row's ＋ flips to a ✓ so a long suggestion list does not
    /// lose track of what has already been taken.
    @State private var added: Set<String> = []
    /// The song an Add-to-collection sheet is up for (In Da Zone has no implicit target, so it
    /// routes through the normal sheet).
    private struct AddRef: Identifiable { let id: String }
    @State private var addRef: AddRef?

    var body: some View {
        List {
            if !songIds.isEmpty { header }
            ForEach(orderedIds, id: \.self) { id in
                row(id)
            }
            if songIds.isEmpty && didBuild {
                emptyState.listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(route.title)
        .task { await build() }
        .sheet(item: $addRef) { r in AddToCollectionView(item: .song(r.id)) }
    }

    /// PLAY IN ORDER and SHUFFLE — the two affordances every tile now carries, here where the
    /// tile is OPENED (the same pair sits on the card's context menu). Both go through
    /// `ForYouPlayback`, i.e. the existing `CollectionsStore.playNow` -> Now Playing setlist path,
    /// so there is no second queue and no second shuffle.
    ///
    /// Disabled - with the reason in the label - when nothing here can be queued, rather than
    /// present and inert.
    private var header: some View {
        HStack(spacing: 12) {
            // For the zone the blend IS the feature, so the count says what it is made of rather
            // than just how long it is.
            Text(blendSummary).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("foryou-list-summary")
            Spacer()
            Button { play(shuffle: false) } label: {
                Label("Play", systemImage: "play.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(playableIds.isEmpty)
            .foregroundStyle(playableIds.isEmpty ? Theme.fgDim : Theme.accent)
            .accessibilityIdentifier("foryou-play-all")
            Button { play(shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(playableIds.isEmpty)
            .foregroundStyle(playableIds.isEmpty ? Theme.fgDim : Theme.accent)
            .accessibilityIdentifier("foryou-shuffle-all")
        }
        .listRowBackground(Color.clear)
    }

    /// THE displayed order - rejected rows sunk to the bottom, everything else untouched.
    ///
    /// One computed property feeds BOTH the `ForEach` and `play`, which is the whole point: "play
    /// in order" cannot play a rejected song second while the list shows it last, because the two
    /// read the same array. `RecFeedbackOrder.sink` is a pure stable partition (see its doc for
    /// why a rejected row SINKS rather than disappearing).
    private var orderedIds: [String] {
        RecFeedbackOrder.sink(songIds, rejected: rejectedHere)
    }

    /// Rejected ids that are still ON this screen. Scoped to the list rather than read globally so
    /// the fold is over ~90 rows, not over the whole 20k-row log, on a render path.
    private var rejectedHere: Set<String> {
        guard let feedback, !songIds.isEmpty else { return [] }
        return Set(songIds.filter { feedback.isRejected($0) })
    }

    /// What the play/shuffle controls will actually queue. `songIds` here are catalog ids by
    /// construction (both rankers select from the catalog), so this only ever drops an id whose
    /// source was toggled off between the build and the tap.
    private var playableIds: [String] {
        orderedIds.filter { app.songsById[$0] != nil }
    }

    private var blendSummary: String {
        let buried = pools.values.reduce(0) { $1 == .rediscovery ? $0 + 1 : $0 }
        guard route.kind == .zone, buried > 0 else { return "\(songIds.count) songs" }
        return "\(songIds.count) songs · \(buried) buried"
    }

    /// Play the whole tile, in the DISPLAYED order or shuffled.
    private func play(shuffle: Bool) {
        ForYouPlayback.play(playableIds, name: route.title, shuffle: shuffle,
                            collections: collections, path: $path)
    }

    /// Start the queue at `index` and let it run — the ordinary "play from here" a music list
    /// does. Routes through `ForYouPlayback` -> `CollectionsStore.playNow`, the same funnel every
    /// other play entry point in the app uses, so this is a genuine Now Playing setlist (lock
    /// screen, CarPlay, auto-advance, durable session) rather than a one-off sound.
    ///
    /// Indexes into the DISPLAYED order, never the raw build order — tapping the row you can see
    /// has to start on the row you can see, even after a reject has sunk something above it.
    private func play(from index: Int) {
        let ids = playableIds
        guard ids.indices.contains(index) else { return }
        ForYouPlayback.play(Array(ids[index...]), name: route.title, shuffle: false,
                            collections: collections, path: $path)
    }

    /// The ranking runs OFF the main actor for the same reason the tile grid's does: the zone pass
    /// scores the whole catalog (~96k rows) through `PuzzleSimilarity`, and the collection pass
    /// sweeps it once more. On the main actor that is a visible hang — the exact regression this
    /// app has already had to fix once in Browse.
    private func build() async {
        guard !didBuild else { return }
        didBuild = true
        let tracks = app.zoneTracks
        let songs = app.songs
        let genres = app.zoneGenreBySongId
        let counts = playCounts.snapshot()
        let lastPlayed = playCounts.lastPlayedSnapshot()
        let plays = history.recentPlaysForZone()
        let crates = collections.suggestibleCollections().map(\.songIds)
        let now = Date().timeIntervalSince1970 * 1000

        switch route.kind {
        case .zone:
            let queue = await Task.detached(priority: .userInitiated) {
                ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, otherCollections: crates,
                                    plays: plays, playCount: { counts[$0] ?? 0 },
                                    lastPlayedMs: lastPlayed, nowMs: now)
            }.value
            songIds = queue.songIds
            pools = Dictionary(queue.picks.map { ($0.songId, $0.pool) },
                               uniquingKeysWith: { a, _ in a })
        case .collection:
            let members = route.collectionId.map { collections.playableIdsForAnyCollection($0) } ?? []
            songIds = await Task.detached(priority: .userInitiated) {
                ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                       playCount: { counts[$0] ?? 0 })
            }.value
        case .new, .suggested:
            // Both have their own screens (`NewReleasesView` / `RecSuggestionsListView`) and are
            // never routed here; the case exists so adding a tile kind is a compile error rather
            // than a silently empty list.
            songIds = []
        }
    }

    @ViewBuilder private func row(_ id: String) -> some View {
        let song = app.songsById[id]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.name ?? id).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                HStack(spacing: 5) {
                    if let a = song?.artist, !a.isEmpty {
                        Text(a).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    // Only the rediscovery half is labelled. Badging both would just be noise on
                    // every row; badging the buried ones is the point — it is what tells him this
                    // is not a replay of his week.
                    if pools[id] == .rediscovery {
                        Text("Buried")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.accent2.opacity(0.22)))
                            .foregroundStyle(Theme.accent2)
                            .accessibilityIdentifier("foryou-buried-\(id)")
                    }
                }
            }
            // The identifier lives on the TEXT stack, never the row container — a container id
            // absorbs the nested buttons' identifiers (the propagation trap this project has
            // already been bitten by).
            .accessibilityIdentifier("foryou-song-\(id)")
            Spacer()
            // The ASYNC half of the tuning loop: come back to the tile and work the list. The
            // SAME store the now-playing surfaces write to, so a decision made in the car is
            // already reflected here (and vice versa).
            //
            // A fresh accept ALSO takes the add action, so on a collection tile one thumbs-up
            // both files the song and tells the engine why — two taps for one intention would be
            // the wrong loop.
            RecFeedbackControls(songId: id, surface: .tile, context: feedbackContext,
                                onAccepted: { addSong(id) })
            addButton(id)
            if let song {
                RowTransport(song: (id: song.id, title: song.name, artist: song.artist), startMs: nil)
            }
        }
        .padding(.vertical, 2)
        // A rejected row stays visible and readable but recedes — it has been sunk, not deleted,
        // and the listener has to be able to find it again to undo.
        .opacity(feedback?.isRejected(id) == true ? 0.45 : 1)
        .contentShape(Rectangle())
        // In Da Zone is a QUEUE, so a tap plays it from here — the ordinary music-list gesture.
        // A collection tile's list is an ADD list, not a queue, so there a tap still opens the
        // song. Same view, two purposes, and the gesture follows the purpose.
        .onTapGesture {
            if route.kind == .zone {
                play(from: playableIds.firstIndex(of: id) ?? 0)
            } else if let song {
                path.append(song)
            }
        }
    }

    /// The tile identity recorded with a decision made here, so the engine (and a later review of
    /// this feature) can tell "rejected from In Da Zone" from "rejected from a crate's tile".
    private var feedbackContext: String {
        switch route.kind {
        case .zone: return "zone"
        case .collection: return route.collectionId.map { "col-\($0)" } ?? "collection"
        case .new: return "new"
        case .suggested: return "suggested"
        }
    }

    /// For a COLLECTION tile the target is unambiguous (this is that collection's suggestion
    /// list), so ＋ adds straight to it — one tap, no sheet. In Da Zone has no implied target, so
    /// it opens the normal Add sheet.
    @ViewBuilder private func addButton(_ id: String) -> some View {
        if added.contains(id) {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("foryou-added-\(id)")
        } else {
            Button { addSong(id) } label: {
                Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("foryou-add-\(id)")
        }
    }

    /// The one add action, shared by the row's plus and by a fresh accept. Idempotent: a second
    /// call for an id already added does nothing, so accept-then-plus cannot file it twice.
    private func addSong(_ id: String) {
        guard !added.contains(id) else { return }
        if route.kind == .collection, let cid = route.collectionId,
           let target = collections.addTargetForAnyCollection(cid) {
            collections.addSong(id, to: target)
            added.insert(id)
        } else {
            addRef = AddRef(id: id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(Theme.fgDim)
            Text("Nothing to suggest yet").font(.subheadline).foregroundStyle(Theme.fg)
            Text("Play a few more songs and this fills in.")
                .font(.caption).foregroundStyle(Theme.fgDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(30)
        .accessibilityIdentifier("foryou-songlist-empty")
    }
}

// ============================================================================
// MARK: - Playing a tile
// ============================================================================

/// The ONE way a For You tile reaches audio.
///
/// ── WHY THIS IS A FUNNEL AND NOT TWO CALL SITES ──────────────────────────────────────────────
/// The tile card's context menu and the opened tile's header both play the same thing, and the
/// owner's requirement is that shuffle behave like the app's shuffle rather than an
/// `Array.shuffled()` invented here. So both go through `CollectionsStore.playNow(songIds:…)`,
/// which is the same entry point playlists, pockets, albums, artists, CarPlay and every App
/// Intent already use — including its `shuffle` flag, which is the app's shuffle semantics by
/// definition. No second queue, no second shuffle, no second Now Playing document.
///
/// The push is the pattern `PlaylistsView.play` established: `playNow` UPSERTS the reserved Now
/// Playing setlist and bumps its restart token, and `SetlistLaunch(autoplay: true)` is what makes
/// the sound start. Doing only the first half builds a setlist nobody plays — which is what this
/// screen's old "Play all" did.
enum ForYouPlayback {
    @MainActor
    static func play(_ songIds: [String], name: String, shuffle: Bool,
                     collections: CollectionsStore, path: Binding<NavigationPath>) {
        // Nothing playable ⇒ do nothing AND navigate nowhere. Every caller disables its control
        // in this case; this is the belt to that braces, so a stale tile can never push an empty
        // deck.
        guard !songIds.isEmpty else { return }
        guard let set = collections.playNow(songIds: songIds, name: name, shuffle: shuffle,
                                            source: .browser, originId: nil),
              !set.tracks.isEmpty else { return }
        path.wrappedValue.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
    }
}
