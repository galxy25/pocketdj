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
        let items = releaseFeed?.newReleases() ?? []
        List {
            if items.isEmpty {
                emptyState.listRowBackground(Color.clear)
            } else {
                ForEach(items) { entry in
                    Button { push(entry) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("new-release-\(entry.artistId)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("New")
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

    @ViewBuilder private func row(_ e: ArtistReleaseEntry) -> some View {
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
    static func relative(_ atMs: Double, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let days = Int(((nowMs - atMs) / 86_400_000).rounded())
        if days <= 0 { return "Today" }
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

    let route: ForYouTileRoute
    @Binding var path: NavigationPath

    @State private var songIds: [String] = []
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
            ForEach(songIds, id: \.self) { id in
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
        .task { build() }
        .sheet(item: $addRef) { r in AddToCollectionView(item: .song(r.id)) }
    }

    private var header: some View {
        HStack {
            Text("\(songIds.count) songs").font(.caption).foregroundStyle(Theme.fgDim)
            Spacer()
            Button {
                collections.playNow(songIds: songIds, name: route.title, shuffle: false,
                                    source: .browser, originId: nil)
            } label: {
                Label("Play all", systemImage: "play.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("foryou-play-all")
        }
        .listRowBackground(Color.clear)
    }

    private func build() {
        guard !didBuild else { return }
        didBuild = true
        let tracks = app.zoneTracks
        let counts = playCounts.snapshot()
        switch route.kind {
        case .zone:
            songIds = ZoneEngine.inDaZone(tracks: tracks,
                                          plays: history.recentPlaysForZone(),
                                          playCount: { counts[$0] ?? 0 },
                                          nowMs: Date().timeIntervalSince1970 * 1000)
        case .collection:
            let members = route.collectionId.map { collections.playableIdsForAnyCollection($0) } ?? []
            songIds = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                             playCount: { counts[$0] ?? 0 })
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
                if let a = song?.artist, !a.isEmpty {
                    Text(a).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
            }
            // The identifier lives on the TEXT stack, never the row container — a container id
            // absorbs the nested buttons' identifiers (the propagation trap this project has
            // already been bitten by).
            .accessibilityIdentifier("foryou-song-\(id)")
            Spacer()
            addButton(id)
            if let song {
                RowTransport(song: (id: song.id, title: song.name, artist: song.artist), startMs: nil)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if let song { path.append(song) } }
    }

    /// For a COLLECTION tile the target is unambiguous (this is that collection's suggestion
    /// list), so ＋ adds straight to it — one tap, no sheet. In Da Zone has no implied target, so
    /// it opens the normal Add sheet.
    @ViewBuilder private func addButton(_ id: String) -> some View {
        if added.contains(id) {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("foryou-added-\(id)")
        } else {
            Button {
                if route.kind == .collection, let cid = route.collectionId,
                   let target = collections.addTargetForAnyCollection(cid) {
                    collections.addSong(id, to: target)
                    added.insert(id)
                } else {
                    addRef = AddRef(id: id)
                }
            } label: {
                Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("foryou-add-\(id)")
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
