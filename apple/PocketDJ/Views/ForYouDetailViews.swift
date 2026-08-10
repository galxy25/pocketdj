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
    /// The 👍/👎 log. A NEW RELEASE IS A RECOMMENDATION — the owner asked for a reject beside the
    /// add on each one, and this tile is one of the two pinned at the top of For You, so leaving
    /// it as the one untunable surface would have been the most visible gap in the feature.
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    @Binding var path: NavigationPath

    /// The reserved scope for this tile — the same string `ForYouTileRoute.feedbackContext`
    /// produces for `.new`, so a verdict given here and one given anywhere else about the New tile
    /// land in one place.
    private var scope: String { ForYouTileRoute.Kind.new.rawValue }

    var body: some View {
        // OUT NOW first: it is the part he can act on. COMING SOON is real news but nothing can
        // be played from it, so it sits underneath rather than at the top.
        let outNow = sunkLast(releaseFeed?.outNow() ?? [])
        let soon = sunkLast(releaseFeed?.comingSoon() ?? [])
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

    /// A rejected release SINKS to the bottom of its section — the same rule every other
    /// recommendation surface follows, and for the same reason: the row must stay on screen so the
    /// lit 👎 that undoes it stays reachable. Applied at RENDER, so a verdict given elsewhere while
    /// this screen was closed is simply already in the right place when it opens.
    private func sunkLast(_ items: [ReleaseFeedItem]) -> [ReleaseFeedItem] {
        guard let feedback else { return items }
        let sunk = feedback.activeTombstones(scope: scope)
        guard !sunk.isEmpty else { return items }
        return items.filter { sunk[$0.feedbackId] == nil } + items.filter { sunk[$0.feedbackId] != nil }
    }

    @ViewBuilder
    private func section(_ status: ReleaseStatus, _ items: [ReleaseFeedItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Button { push(item.entry) } label: { row(item) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("new-release-\(item.entry.artistId)")
                        // The reject half of the pair. There is no ADD here — the row already
                        // pushes `AlbumPreviewView`, which owns the whole add/rip path — so a 👍
                        // is pure feedback ("more releases like this"), which is exactly what the
                        // tuning loop wants it to be.
                        RecFeedbackButtons(songId: item.feedbackId, scope: scope, surface: .tile)
                    }
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

    /// AN EMPTY TILE THAT CANNOT EXPLAIN ITSELF READS AS A BROKEN FEATURE — which is precisely how
    /// this one was reported ("my new tile is still empty"). Four genuinely different causes hid
    /// behind one blank screen: the seed still running, Apple Music not authorized, the network
    /// refusing, and the honest "nobody released anything". Each now says which it is.
    private var emptyState: some View {
        let reason = releaseFeed?.emptyReason() ?? .notAuthorized
        return VStack(spacing: 8) {
            Image(systemName: Self.emptySymbol(reason))
                .font(.system(size: 34)).foregroundStyle(Theme.fgDim)
            Text(Self.emptyTitle(reason)).font(.subheadline).foregroundStyle(Theme.fg)
            Text(Self.emptyDetail(reason))
                .font(.caption).foregroundStyle(Theme.fgDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(30)
        .accessibilityIdentifier("new-releases-empty")
        .accessibilityValue(Self.emptyTitle(reason))
    }

    /// Pure copy tables — a unit test asserts every case is distinguishable without driving the UI.
    static func emptySymbol(_ r: ReleaseFeedService.EmptyReason) -> String {
        switch r {
        case .checking:       return "arrow.triangle.2.circlepath"
        case .notAuthorized:  return "person.crop.circle.badge.exclamationmark"
        case .unreachable:    return "wifi.exclamationmark"
        case .notCheckedYet:  return "hourglass"
        case .nothingNew:     return "sparkles"
        }
    }

    static func emptyTitle(_ r: ReleaseFeedService.EmptyReason) -> String {
        switch r {
        case .checking:       return "Checking for new releases…"
        case .notAuthorized:  return "Apple Music isn’t connected"
        case .unreachable:    return "Couldn’t reach Apple Music"
        case .notCheckedYet:  return "Nothing checked yet"
        case .nothingNew:     return "Nothing new in the last 30 days"
        }
    }

    static func emptyDetail(_ r: ReleaseFeedService.EmptyReason) -> String {
        switch r {
        case .checking:
            return "Looking up what the artists you’ve played in the last 30 days have put out."
        case .notAuthorized:
            return "Turn on Apple Music in Settings so PocketDJ can look up new releases."
        case .unreachable(let e):
            return "\(e) This retries by itself the next time you play something."
        case .notCheckedYet:
            return "Play something — the artists you listen to get checked for new releases."
        case .nothingNew:
            return "The artists you’ve played lately haven’t released anything this month."
        }
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
    /// The 👍/👎 log. Optional like the other late-added stores so a preview host that renders
    /// this screen standalone degrades to "no feedback controls" rather than trapping.
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    /// The FROZEN feed. This screen renders the very ids the tile card counted, so the card's
    /// promise and the list cannot disagree — and so nothing re-ranks under the reader between
    /// two visits. Only History's tab menu ▸ Refresh changes it.
    @Environment(ForYouFeedStore.self) private var feed: ForYouFeedStore?

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

    /// HOW THIS LIST RECONCILES A DECISION MADE ELSEWHERE.
    ///
    /// It does not synchronize, because there is nothing to synchronize: `RecFeedbackStore` is
    /// `@Observable` and is the ONLY copy of a verdict, so a 👎 given in the car (or on the lock
    /// screen, or in a widget) is already in the store by the time this body runs. The ordering is
    /// applied HERE, at render, rather than baked into `songIds` at build time — that is what makes
    /// a rejection given while this view is open sink immediately, one given while it was closed
    /// already in place when it re-appears, and an undo put the row straight back without a
    /// re-rank.
    ///
    /// SINK, never filter. `rankedIds` moves a tombstoned row to the bottom and RE-ADDS it if the
    /// engine dropped it — which the engine did, because the same tombstones were passed in as
    /// `ZoneEngine.Feedback.suppressed`. Filtering instead would take the lit 👎 off screen with
    /// the row, leaving a mis-tap undoable only by hunting that exact song down somewhere else.
    private var visibleIds: [String] { partition.live + partition.sunk }
    /// The live picks and the sunk tail, kept apart — `RecFeedbackOrder.sink`, the one
    /// implementation of the rule. ▶ Play takes the live half; ▶▶ Play All takes both.
    private var partition: (live: [String], sunk: [String]) {
        feedback?.partition(songIds, scope: route.feedbackContext) ?? (songIds, [])
    }
    /// The song an Add-to-collection sheet is up for (In Da Zone has no implicit target, so it
    /// routes through the normal sheet).
    private struct AddRef: Identifiable { let id: String }
    @State private var addRef: AddRef?

    var body: some View {
        List {
            if !visibleIds.isEmpty { header }
            ForEach(visibleIds, id: \.self) { id in
                row(id)
            }
            if visibleIds.isEmpty && didBuild {
                emptyState.listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(route.title)
        .task { await build() }
        // The 👍's add for In Da Zone (no implied target ⇒ the normal sheet). `onAdded` is what
        // turns the row's ✓ on, so a thumbs-up that opened a sheet and a thumbs-up that added
        // straight to a crate leave the row in the SAME state.
        .sheet(item: $addRef) { r in
            AddToCollectionView(item: .song(r.id), onAdded: { _ in added.insert(r.id) })
        }
    }

    private var header: some View {
        HStack {
            // For the zone the blend IS the feature, so the count says what it is made of rather
            // than just how long it is.
            Text(blendSummary).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("foryou-list-summary")
            Spacer()
            // A TILE IS A SETLIST — the same Play / Play All / Shuffle menu a collection row
            // carries, from `CollectionPlayMenuItems`, not a screen-specific copy.
            playMenu
        }
        .listRowBackground(Color.clear)
    }

    private var playMenu: some View {
        Menu {
            CollectionPlayMenuItems(title: route.title,
                                    songIds: partition.live, sunkIds: partition.sunk,
                                    idPrefix: "foryou",
                                    onStarted: { queue in
                                        // STAMP THE SCOPE. From here the deck, the mini bar, the
                                        // lock screen, CarPlay and the widgets all know what is
                                        // playing is a recommendation FROM THIS TILE and can file
                                        // a verdict without the listener leaving playback.
                                        feedback?.beginPlayback(scope: route.feedbackContext,
                                                                songIds: queue)
                                    })
        } label: {
            Label("Play", systemImage: "play.fill").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Theme.accent)
        .accessibilityIdentifier("foryou-play-menu")
    }

    /// The header count is `visibleCount`, the SAME function the tile card uses — so the card's
    /// promise and what the list opens on cannot disagree. Sunk rows are excluded from both (they
    /// are the tail the listener already said no to, not part of the offer).
    private var blendSummary: String {
        let n = feedback?.visibleCount(songIds, scope: route.feedbackContext) ?? songIds.count
        let live = Set(visibleIds.prefix(n))
        let buried = pools.reduce(0) { $1.value == .rediscovery && live.contains($1.key) ? $0 + 1 : $0 }
        guard route.kind == .zone, buried > 0 else { return "\(n) songs" }
        return "\(n) songs · \(buried) buried"
    }

    /// Start the queue at `index` and let it run — the ordinary "play from here" a music list
    /// does. Routes through `CollectionsStore.playNow`, the same funnel every other ▶ in the app
    /// uses, so this is a genuine Now Playing setlist (lock screen, CarPlay, auto-advance,
    /// durable session) rather than a one-off sound.
    private func play(from index: Int) {
        let ids = visibleIds
        guard ids.indices.contains(index) else { return }
        let queue = Array(ids[index...])
        collections.playNow(songIds: queue, name: route.title,
                            shuffle: false, source: .browser, originId: nil)
        // STAMP THE SCOPE. This is what turns the SYNC half of the loop on: from here the deck,
        // the mini bar, the lock screen, CarPlay and the widgets all know that what is playing is
        // a recommendation FROM THIS TILE, and can file a verdict against it without the listener
        // leaving playback. `playNow` clears any previous stamp, so a queue started from anywhere
        // else (a playlist, an album, Browse) leaves the controls hidden rather than guessing.
        feedback?.beginPlayback(scope: route.feedbackContext, songIds: queue)
    }

    /// Load the list.
    ///
    /// ── THE FROZEN FEED IS THE FIRST ANSWER ──────────────────────────────────────────────────
    /// The tile card counted a specific set of ids at the last refresh; this screen renders THAT
    /// set. Reading it back is a dictionary hit, so the list paints instantly and — the point of
    /// the whole change — a song the owner glanced at ten minutes ago is still in the same place
    /// when he comes back for it. Only History's tab menu ▸ Refresh moves it.
    ///
    /// ── THE FALLBACK, AND WHY IT IS STILL OFF THE MAIN ACTOR ─────────────────────────────────
    /// A snapshot that predates this tile (a collection that earned one after the last refresh, a
    /// preview host with no store) has nothing cached, and an empty list would be a worse answer
    /// than a slightly-out-of-band ranking. So it computes — and that pass scores the whole
    /// catalog (~96k rows) through `PuzzleSimilarity`, which on the main actor is a visible hang,
    /// the exact regression this app has already had to fix once in Browse.
    private func build() async {
        guard !didBuild else { return }
        didBuild = true
        if let frozen = feed?.songIds(forTileId: route.tileId) {
            songIds = frozen
            if route.kind == .zone {
                let buried = Set(feed?.snapshot.zoneBuriedIds ?? [])
                pools = Dictionary(uniqueKeysWithValues: frozen.filter(buried.contains)
                    .map { ($0, ZoneEngine.Pool.rediscovery) })
            }
            return
        }
        let tracks = app.zoneTracks
        let songs = app.songs
        let genres = app.zoneGenreBySongId
        let counts = playCounts.snapshot()
        let lastPlayed = playCounts.lastPlayedSnapshot()
        let plays = history.recentPlaysForZone()
        let crates = collections.suggestibleCollections().map(\.songIds)
        let now = Date().timeIntervalSince1970 * 1000
        // Snapshot the verdicts ON the main actor (the store is @Observable) and hand the pure
        // engine a value type — the same hop every other input here makes. The SCOPE is this
        // route's, so only rejects given in THIS list suppress rows in it; the taste half is
        // global and rides along regardless.
        let fb = feedback?.zoneFeedback(scope: route.feedbackContext, nowMs: now)
            ?? ZoneEngine.Feedback()

        switch route.kind {
        case .zone:
            let queue = await Task.detached(priority: .userInitiated) {
                ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, otherCollections: crates,
                                    plays: plays, playCount: { counts[$0] ?? 0 },
                                    lastPlayedMs: lastPlayed, feedback: fb, nowMs: now)
            }.value
            songIds = queue.songIds
            pools = Dictionary(queue.picks.map { ($0.songId, $0.pool) },
                               uniquingKeysWith: { a, _ in a })
        case .collection:
            let members = route.collectionId.map { collections.playableIdsForAnyCollection($0) } ?? []
            songIds = await Task.detached(priority: .userInitiated) {
                ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                       playCount: { counts[$0] ?? 0 }, feedback: fb)
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
            // TWO CONTROLS, NOT THREE. Owner, verbatim: the thumbs-up "should both send positive
            // signal to recommendation engine and add the song to the collection". So 👍 IS the
            // add — the separate ＋ that used to sit beside it is gone, because a row offering
            // both made the same act look like two different ones. 👎 is its pair.
            RecFeedbackButtons(songId: id, scope: route.feedbackContext, surface: .tile,
                               onAccept: { accept(id) })
            // Ownership READOUT, not a control: the row states it is now in the collection. It
            // renders only after the add lands, so it can never sit beside a ＋ offering to do
            // what has already been done.
            if added.contains(id) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("foryou-added-\(id)")
            }
            if let song {
                RowTransport(song: (id: song.id, title: song.name, artist: song.artist), startMs: nil)
            }
        }
        .padding(.vertical, 2)
        // A sunk row reads as sunk. Dimmed rather than hidden: it is still playable, still
        // addable, and its lit 👎 is the control that puts it back.
        .opacity(feedback?.isSuppressed(songId: id, scope: route.feedbackContext) == true ? 0.45 : 1)
        .contentShape(Rectangle())
        // In Da Zone is a QUEUE, so a tap plays it from here — the ordinary music-list gesture.
        // A collection tile's list is an ADD list, not a queue, so there a tap still opens the
        // song. Same view, two purposes, and the gesture follows the purpose.
        .onTapGesture {
            if route.kind == .zone {
                play(from: visibleIds.firstIndex(of: id) ?? 0)
            } else if let song {
                path.append(song)
            }
        }
    }

    /// The ADD half of a 👍 — the SAME route the ＋ used, not a reimplementation. For a COLLECTION
    /// tile the target is unambiguous (this is that collection's suggestion list), so it adds
    /// straight to it through `CollectionsStore.addSong`; In Da Zone has no implied target, so it
    /// opens the normal `AddToCollectionView` sheet, which is also the door to the Discover /
    /// ad-hoc add for an id this catalog cannot resolve. Never touches the transport: accepting a
    /// suggestion while a song is playing must not stop, skip or re-queue anything.
    private func accept(_ id: String) {
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
