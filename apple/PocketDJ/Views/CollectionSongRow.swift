import SwiftUI

/// The ONE shared, PWA-style song row used EVERYWHERE a song reads as a list row:
/// the Browser song list, collection details (playlists / pockets / index playlists),
/// and the frozen Setlist. Every surface gets the identical look + the identical info.
///
/// Content, left → right:
///   • LEFT: album-art thumbnail (resolved via `app.albumsById`; graceful music-note
///     placeholder when the album is missing/unknown — e.g. a setlist snapshot whose
///     catalog song is gone),
///   • PRIMARY line: song title (+ explicit "E" badge),
///   • SECONDARY line: "artist · year · genre" (size-gated — see below),
///   • MIDDLE music cluster: BPM as tiered play-icons (+ numeric), a Camelot KeyChip
///     (always populated — black-box "U" when unknown), and the length (`Fmt.duration`),
///   • ♥ FAVORITE toggle (`FavoriteToggle`) immediately left of the transport,
///   • RIGHT: ▶ play / ⤓ download transport (`RowTransport`) — rip-on-demand wired to
///     `RipsStore` + `PlayerEngine`; ▶ reveals the inline slide-out player below the row.
///
/// Responsive: on COMPACT width (iPhone) the year + genre are dropped from the
/// secondary line to keep it uncluttered; on regular width (iPad) and macOS (where
/// `horizontalSizeClass` is nil) they SHOW. Title, the music cluster, and transport
/// are visible at every size.
///
/// Presentation only — wrap in a `NavigationLink` for tap-through and attach
/// swipe / move / delete / notes / context-menus on the enclosing row.
/// Measures the row's own width so the artist can be capped at a share of it. SwiftUI has no
/// "half the parent" frame, and `GeometryReader` in the layout path would fight the List's row
/// sizing — reading the width through a preference off a background is the non-invasive way.
private struct RowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SongRowView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(RipsStore.self) private var rips
    @State private var rowWidth: CGFloat = 0
    let data: SongRowData
    /// Optional trailing accessory (e.g. a setlist source/sequence badge column) shown
    /// to the left of the play/download buttons.
    var trailing: AnyView?
    /// Whether the row ends in the ▶/⤓ `RowTransport`. Off for surfaces whose row tap
    /// means something else entirely — the queue builder, where a preview-play button
    /// beside the ＋ reads as "add" and silently isn't. Defaulted on: every existing
    /// call site keeps the transport it has always had.
    var showsTransport = true

    /// Show year/genre only when there's room: regular width (iPad) or macOS (nil).
    private var showsExtra: Bool { hSize != .compact }

    /// Is the row WIDE enough to sit the artist beside the title rather than under it?
    ///
    /// Landscape on iPhone reports `hSize == .compact` — the horizontal class alone can't tell
    /// portrait from landscape there — so the vertical class is what distinguishes them: it goes
    /// `.compact` exactly when the device is on its side. macOS/visionOS report nil for both and
    /// fall through to wide, which is right.
    private var isWide: Bool { hSize != .compact || vSize == .compact }

    /// The TITLE's floor — how the artist's "up to half" ceiling is actually enforced.
    ///
    /// The obvious spelling, `.frame(maxWidth: half)` on the artist, does NOT work: a maxWidth
    /// frame is a RESERVATION, not a ceiling. Measured, it occupies the full cap whether the artist
    /// is "ABBA" (27pt of text) or a 63-character name — so the title was squeezed to half the row
    /// even when the artist needed almost none of it, which is the opposite of the intent.
    ///
    /// Constraining the OTHER side gets it right. The artist is left unconstrained with
    /// `layoutPriority(1)`, so it takes exactly the width it needs and is FULLY SHOWN; the title
    /// carries a minimum width, which SwiftUI must honour, so a very long artist can never squeeze
    /// the song name past the halfway mark and truncates itself instead.
    ///
    /// Measured against the TEXT column, not the whole row: `rowWidth` includes the 42pt thumbnail
    /// and the 10pt gap beside it, so using it raw would hand the artist ~53% rather than half.
    private var titleMinWidth: CGFloat {
        let inner = rowWidth - 52          // thumbnail (42) + HStack spacing (10)
        return inner > 0 ? max(96, inner * 0.5) : 120
    }

    // Rip-analyzed bpm/key/camelot (computed from the actual ripped audio, kept in the rips
    // manifest) overlays the catalog index values — so once a song is ripped the row shows
    // the latest analysis. The manifest carries these only for analyzed (digital) rips;
    // analog rips leave them nil and the row keeps the catalog values.
    private var ripped: RipsStore.ManifestEntry? { rips.manifest[data.songId] }
    private var effBpm: Double? { ripped?.bpm ?? data.bpm }
    private var effKey: String? { ripped?.musicalKey ?? data.key }
    private var effCamelot: String? { ripped?.camelot ?? data.camelot }

    /// The bottom line's text half — "year · genre", size-gated. The ARTIST is no longer here:
    /// it moved to the top line, right-aligned opposite the title.
    private var secondary: String {
        guard showsExtra else { return "" }
        var parts: [String] = []
        if let y = data.year { parts.append(String(y)) }
        if let g = data.genre, !g.isEmpty { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    /// The artist label, identical in both arrangements — only WHERE it sits changes.
    private var artistText: some View {
        Text(data.artist)
            .font(.caption).foregroundStyle(Theme.fgDim)
            .lineLimit(1).truncationMode(.tail)
            .accessibilityIdentifier("row-artist-\(data.songId)")
    }

    var body: some View {
        HStack(spacing: 10) {
            SongThumbnail(album: data.album, studioId: data.songId).frame(width: 42, height: 42)

            // TWO LINES, each with its own left/right pairing (Levi 2026-08-02):
            //   top    — what it IS: title on the left, artist hard right
            //   bottom — what it's LIKE + what you can DO: metadata left, actions hard right
            // The old layout ran everything across one line, which pushed the music cluster and
            // the transport into a fight for width on iPhone and truncated the title first.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(data.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                        .frame(minWidth: isWide ? titleMinWidth : nil, alignment: .leading)
                    if data.explicit {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                            .accessibilityIdentifier("explicit-badge")
                    }
                    // WIDE (landscape, iPad, Mac): the artist sits opposite the title, taking the
                    // width it needs — fully shown — and the title's floor (see `titleMinWidth`) is
                    // what stops it past half. `layoutPriority(1)` is what makes "fully shown" real:
                    // without it the artist is the first thing SwiftUI truncates.
                    if isWide {
                        Spacer(minLength: 8)
                        artistText.layoutPriority(1)
                    }
                }
                // PORTRAIT: there isn't room to put a full artist name beside the title, so it
                // goes on its own line underneath — where it has the whole row to itself and
                // never competes with the title for space.
                if !isWide { artistText }

                HStack(spacing: 8) {
                    // Everything else about the song: year · genre (size-gated) then the music
                    // analysis — BPM tiers · Camelot key · length.
                    if !secondary.isEmpty {
                        Text(secondary).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    BPMTier(bpm: effBpm)
                    KeyChip(key: effKey, camelot: effCamelot)
                    Text(Fmt.duration(data.lengthMs))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    PlayCountBadge(songId: data.songId)

                    Spacer(minLength: 8)

                    if let trailing { trailing }

                    // "Not backed up to Apple Music" — no confident catalog match, so a linked
                    // collection can't push it to the real Apple Music playlist (it stays local).
                    if data.unsyncable {
                        Image(systemName: "xmark.icloud")
                            .font(.caption)
                            .foregroundStyle(Theme.fgDim)
                            .help("Not on Apple Music — stays in your local copy; it won’t be added to the linked playlist.")
                            .accessibilityLabel("Not backed up to Apple Music")
                            .accessibilityIdentifier("unsyncable-badge-\(data.songId)")
                    }

                    FavoriteToggle(songId: data.songId, appleMusicId: data.appleMusicId)

                    if showsTransport {
                        RowTransport(song: (id: data.songId, title: data.title, artist: data.artist),
                                     startMs: data.startMs,
                                     cleanOnlyCollection: data.cleanOnlyCollection)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear.preference(key: RowWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(RowWidthKey.self) { w in
            // Only react to real changes — a rotation or a window resize, not every re-layout.
            if abs(w - rowWidth) > 1 { rowWidth = w }
        }
    }
}

/// LIFETIME plays as `#NN`, exactly the shorthand Levi asked for ("see the play count as #NN per
/// item"). Lives inside the SHARED `SongRowView`, so it appears wherever a song row does — the
/// Browser, collections, setlists — and reads identically in all of them.
///
/// HIDDEN AT ZERO, deliberately: most of a 90k-row catalog has never been played, and rendering
/// `#0` on forty thousand rows would be noise on every screen instead of information. Absent means
/// zero here, matching how `PlayCountService` and the "Plays" sort field already read it.
///
/// The service is OPTIONAL in the environment: a preview or a host that hasn't injected it renders
/// nothing rather than trapping (the `FavoritesStore` precedent one field up).
struct PlayCountBadge: View {
    @Environment(PlayCountService.self) private var playCounts: PlayCountService?
    let songId: String

    /// Reads `revision` FIRST so the badge re-renders the instant a play or a capture lands:
    /// `combinedPlayCount` reaches into dictionaries behind a function call, which `@Observable`
    /// cannot see into on its own.
    private var count: Int {
        guard let playCounts else { return 0 }
        _ = playCounts.revision
        // The memoized snapshot, not `combinedPlayCount`: the latter reaches into the raw
        // observed dictionaries, so 150 mounted badges each re-rendered per DICTIONARY
        // mutation (twice per play). The snapshot is revision-keyed — one invalidation per
        // revision bump, O(1) per badge after the shared build — and is defined to agree
        // with `combinedPlayCount` (see `PlayCountService.snapshot`).
        return playCounts.snapshot()[songId] ?? 0
    }

    @ViewBuilder var body: some View {
        if count > 0 {
            Text("#\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
                .help("Played \(count) time\(count == 1 ? "" : "s")")
                .accessibilityLabel("Played \(count) time\(count == 1 ? "" : "s")")
                .accessibilityIdentifier("play-count-\(songId)")
        }
    }
}

/// Feeds a `BrowseState` the lifetime play counts its "Plays" sort/filter needs.
///
/// Lifetime plays are the one field whose value is NOT on the row — it lives in a store — so the
/// pure, off-main filter/sort can only see it if a snapshot is pushed in. EVERY surface that
/// offers the sort must apply this, or the option appears in the sheet and quietly does nothing
/// (which is worse than not offering it): the Browser, and every collection detail view that
/// mounts `CollectionSortFilterSheets`.
///
/// `initial: true` seeds on first appearance; each later capture or play bumps the service's
/// revision and re-seeds. `applyPlayCounts` ignores an unchanged revision, so this can never churn
/// the results memo per render.
struct PlayCountsFeed: ViewModifier {
    @Environment(PlayCountService.self) private var playCounts: PlayCountService?
    let browse: BrowseState

    func body(content: Content) -> some View {
        content.onChange(of: playCounts?.revision ?? 0, initial: true) { _, _ in
            guard let playCounts else { return }
            browse.applyPlayCounts(playCounts.snapshot(), revision: playCounts.revision)
        }
    }
}

extension View {
    /// See `PlayCountsFeed` — required on any surface whose sort/filter offers "Plays".
    func playCountsFeed(_ browse: BrowseState) -> some View {
        modifier(PlayCountsFeed(browse: browse))
    }
}

/// The inline slide-out player rendered at LIST level, immediately AFTER a song row's
/// `NavigationLink`, when that row's song is the now-playing one. It MUST live outside the
/// nav-link label so its buttons (play/pause, close, chevron) receive taps instead of the
/// link swallowing them. Drop this directly after each song-row `NavigationLink`, passing
/// the row's song id; it shows the panel only for the matching now-playing row and keeps
/// the slide-in/out animation.
struct InlinePlayerSlot: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlaybackCoordinator.self) private var coordinator
    /// The id of the song whose row this slot trails.
    let songId: String

    private var isRipNowPlaying: Bool { rips.nowPlaying?.songId == songId }
    private var isAppleMusicNowPlaying: Bool { coordinator.isAppleMusicNowPlaying(songId) }

    var body: some View {
        // Apple Music streaming is the active backend for this row → show the
        // Apple-Music-flavoured panel (position-only scrubber + "via Apple Music", no
        // waveform). Otherwise the rip path keeps its EXACT verified panel.
        //
        // Item 8 — iOS ONLY: wrap the conditional panel in an asymmetric slide/collapse
        // transition (insert: push-from-top + fade; remove: fade) so a row's player slides
        // in below it and collapses away. The CONDITIONAL insertion/removal itself (driven by
        // `rips.nowPlaying` / the coordinator) gives collapse-A/expand-B for free — no manual
        // nil-then-await staging (CRITIC-E). NO explicit `.id` on the slot (CRITIC-F).
        //
        // macOS stays STRICTLY PLAIN — NO transition/animation: an animating/transitioning
        // container in a macOS `ScrollView`+`LazyVStack` drops hit-testing on its child
        // buttons (the documented "dead slide-out play/pause · ✕ · chevron" bug). The
        // slide-in is sacrificed there for a working player.
        Group {
            if isAppleMusicNowPlaying {
                AppleMusicInlinePanel()
                    .panelTransition()
            } else if isRipNowPlaying {
                InlinePlayerPanel()
                    .panelTransition()
            }
        }
        #if os(iOS)
        .animation(.easeInOut(duration: 0.22), value: isRipNowPlaying)
        .animation(.easeInOut(duration: 0.22), value: isAppleMusicNowPlaying)
        #endif
    }
}

private extension View {
    /// Item 8 — the per-row inline-player insert/remove transition. iOS: asymmetric
    /// push-from-top + opacity on insert, opacity on removal. macOS: identity (plain) —
    /// the documented hit-test bug forbids a transitioning container there.
    @ViewBuilder func panelTransition() -> some View {
        #if os(iOS)
        self.transition(.asymmetric(
            insertion: .push(from: .top).combined(with: .opacity),
            removal: .opacity))
        #else
        self
        #endif
    }
}

/// The primitives that feed `SongRowView`. Both `IndexSong` (browser / collections)
/// and `SetlistTrack` (frozen setlist snapshot) project into this, so every surface
/// renders identically. Genre / year / thumbnail resolve from the song's album.
struct SongRowData {
    var songId: String
    var title: String
    var artist: String
    var year: Int?
    var genre: String?
    var bpm: Double?
    var key: String?
    var camelot: String?
    var lengthMs: Int?
    var explicit: Bool
    /// Optional analog start offset (ms) within the album rip — when nil the rips
    /// store falls back to the manifest entry's own `startMs`.
    var startMs: Int?
    /// The album behind the song (for cover art + genre/year fallback); nil → placeholder.
    var album: IndexAlbum?
    /// Apple Music catalog id, carried so the row's ♥ can hand it to `FavoritesStore` for a
    /// later outbound push. Nil for vinyl / "My Digital" / Studio songs — they have no Apple
    /// Music identity and stay local-only favorites forever.
    var appleMusicId: String?
    /// In a source-linked collection, TRUE when the write-back queue has determined this song
    /// can't be added to the linked Apple Music playlist (no confident catalog match). Drives the
    /// `xmark.icloud` "not backed up" badge. Always false on non-linked surfaces (Browse, setlists).
    var unsyncable: Bool = false
    /// Rule 1 of `EditionPolicy`: is the collection this row is shown in clean-versions-only?
    /// Set by the pocket / playlist detail views so a single-row ▶ obeys the same restriction
    /// the ▶ Play sequencer does — without it, prefer-explicit could play an explicit cut from
    /// inside a clean-only collection. False everywhere else (Browse, search, setlists).
    var cleanOnlyCollection: Bool = false

    /// Project a catalog song. Pass the song's resolved album for art + genre/year.
    /// Year prefers the song's own value, falling back to the album's.
    init(song: IndexSong, album: IndexAlbum?) {
        self.songId = song.id
        self.title = song.name
        self.artist = song.artist
        self.year = song.year ?? album?.year
        self.genre = Self.cleanGenre(album?.genre)
        self.bpm = song.bpm
        self.key = song.key
        self.camelot = song.camelot
        self.lengthMs = song.length
        self.explicit = song.explicit == true
        self.startMs = nil   // analog offset resolves from the rips manifest entry
        self.album = album
        self.appleMusicId = song.appleMusicId
    }

    /// Project a frozen setlist track (its snapshot) — resolve year/genre/art from the
    /// live catalog album when the backing song still exists, else fall back to the snapshot.
    init(track: SetlistTrack, song: IndexSong?, album: IndexAlbum?) {
        self.songId = track.songId.isEmpty ? track.id : track.songId
        self.title = track.name
        self.artist = track.artist
        self.year = song?.year ?? album?.year
        self.genre = Self.cleanGenre(album?.genre)
        self.bpm = track.bpm
        self.key = nil                 // snapshot carries camelot only
        self.camelot = track.camelot
        self.lengthMs = track.shownMs
        self.explicit = song?.explicit == true
        self.startMs = nil
        self.album = album
        // The frozen snapshot carries no catalog id — resolve it from the live song when it
        // still exists; a setlist whose backing song is gone favorites local-only.
        self.appleMusicId = song?.appleMusicId
    }

    private static func cleanGenre(_ g: String?) -> String? {
        let t = g?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty == false) ? t : nil
    }
}

/// Convenience: the shared row driven straight from an `IndexSong`, resolving the
/// album from the environment's catalog. Used by the Browser + collection details.
struct CollectionSongRow: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?
    let song: IndexSong
    /// Optional trailing accessory shown left of the transport buttons.
    var trailing: AnyView?
    /// Set by a SOURCE-LINKED collection (a converted pocket / duplicated playlist that syncs to
    /// Apple Music). When true, the row surfaces the `xmark.icloud` badge for a song the write-back
    /// queue has flagged `.unresolvable`. Off everywhere else (Browse, unlinked collections).
    var syncsToSource: Bool = false
    /// Set by a CLEAN-VERSIONS-ONLY collection, so this row's ▶ resolves the same edition the
    /// collection's ▶ Play would (`EditionPolicy` rule 1 beats the global preference).
    var cleanOnlyCollection: Bool = false

    private var album: IndexAlbum? { song.albumId.flatMap { app.albumsById[$0] } }
    private var unsyncable: Bool { syncsToSource && (writeBack?.isUnsyncable(song.id) ?? false) }

    var body: some View {
        var data = SongRowData(song: song, album: album)
        data.unsyncable = unsyncable
        data.cleanOnlyCollection = cleanOnlyCollection
        return SongRowView(data: data, trailing: trailing)
    }
}

/// BPM rendered as 1–4 `play.fill` icons (tempo tiers) plus the small numeric BPM.
/// nil/0 bpm → a dash, no icons. The tier mapping is a pure function (`BPMTier.tier`)
/// so the boundaries are unit-testable.
struct BPMTier: View {
    let bpm: Double?

    /// Map a BPM to a tempo tier 1…4 (slow→hyper), or nil when bpm is missing/zero.
    ///   0–90 = 1 (slow), 90–120 = 2 (medium), 120–160 = 3 (fast), 160–400 = 4 (hyper).
    /// Upper bound is exclusive of the next tier (e.g. exactly 120 → fast).
    static func tier(_ bpm: Double?) -> Int? {
        guard let bpm, bpm > 0 else { return nil }
        switch bpm {
        case ..<90:   return 1
        case ..<120:  return 2
        case ..<160:  return 3
        default:      return 4   // 160…400+ → hyper
        }
    }

    var body: some View {
        if let t = BPMTier.tier(bpm) {
            // BPM number above the tempo-tier play icons.
            VStack(spacing: 1) {
                Text(Fmt.bpm(bpm)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                HStack(spacing: 1) {
                    ForEach(0..<t, id: \.self) { _ in
                        Image(systemName: "play.fill").font(.system(size: 7))
                    }
                }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("bpm-tier-\(t)")
            }
        } else {
            Text("–").font(.caption2).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("bpm-tier-none")
        }
    }
}

/// The shared LEFT album-art thumbnail — the resolved album's cover, or a graceful
/// music-note placeholder when the album is unknown (e.g. a setlist snapshot whose
/// catalog song is gone).
struct SongThumbnail: View {
    let album: IndexAlbum?
    /// The row's song id — when it's a STUDIO performance item (no album), the PocketDJ icon is
    /// its default artwork instead of the generic music-note placeholder.
    var studioId: String? = nil
    var body: some View {
        if let album {
            CoverImage(album: album, corner: 6)
        } else if let studioId, StudioFactory.isStudioId(studioId) {
            PocketDJArtwork(corner: 6)
        } else {
            ZStack {
                LinearGradient(colors: [Theme.bgOverlay, Theme.bgRaised],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(Theme.fgDim)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

/// ♥ — the ONE favorite control, shared by every song surface: the shared `SongRowView`
/// (Browse / collections / setlists / History), the album track table, and the song detail
/// page. Filled `heart.fill` + accent when on, outline `heart` + `Theme.fgDim` when off.
///
/// One tap = one `FavoritesStore.toggle`; the store owns everything downstream (tombstones,
/// persistence, and whether the change is even eligible to reach Apple Music). Callers pass
/// the song's catalog id when it has one — vinyl / "My Digital" / Studio songs pass nil and
/// are favorited local-only, which the store handles by construction.
struct FavoriteToggle: View {
    @Environment(FavoritesStore.self) private var favorites
    let songId: String
    var appleMusicId: String?
    /// Glyph size — rows keep the compact default; the detail page's action cluster bumps it
    /// so the ♥ reads as a primary action rather than row furniture.
    var font: Font = .caption

    private var on: Bool { favorites.isFavorite(songId) }

    var body: some View {
        Button { favorites.toggle(songId, appleMusicId: appleMusicId) } label: {
            Image(systemName: on ? "heart.fill" : "heart").font(font)
                .contentShape(Rectangle())
        }
        // `.borderless` — the SAME style the row's working ▶/⤓ transport uses, and for the
        // same two reasons: it keeps the enclosing `NavigationLink` from swallowing the tap,
        // AND it survives macOS hit-testing inside a `ScrollView`+`LazyVStack`, where a
        // `.plain` button silently drops its press (the documented "dead slide-out buttons"
        // bug — the press hit-tests but the action never fires).
        .buttonStyle(.borderless)
        .foregroundStyle(on ? Theme.accent : Theme.fgDim)
        .accessibilityIdentifier("favorite-toggle-\(songId)")
        .accessibilityLabel(on ? "Unfavorite" : "Favorite")
    }
}

/// ▶ / ⤓ — the real rip-on-demand transport (replaces the old placeholders). ▶ rips
/// (or plays the cached mp3), loads the `PlayerEngine`, and reveals the inline player
/// for this row; ⤓ SAVES the durable mp3 (ripping on demand if needed) straight into the
/// burnt-music folder from Settings — or the app-managed burns directory when none is set —
/// and the glyph then becomes a ✓ whose menu deletes the file or reveals it. The
/// button area shows the live rip phase (Searching… / Ripping mm:ss / ● Streaming live /
/// Uploading…, ⚠ on error), matching the PWA's `RipButtons`.
struct RowTransport: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settings
    @Environment(BurnStore.self) private var burns
    @Environment(ProfileSourceStore.self) private var profileSource: ProfileSourceStore?
    /// For the streamability check only (the row carries a lean id/title/artist tuple —
    /// `appleMusicId` lives on the catalog row).
    @Environment(AppModel.self) private var app
    let song: (id: String, title: String, artist: String)
    var startMs: Int?
    /// Rule 1 of `EditionPolicy`: is the collection this row is being shown in
    /// clean-versions-only? Set by the pocket/playlist detail views; false everywhere else
    /// (Browser, search, Discover), where the global preference decides alone.
    var cleanOnlyCollection: Bool = false
    /// SongDetail-only: when set AND this song is already stemmed, tapping the stem glyph runs
    /// THIS (slides out the audition panel) instead of kicking off Stemify. nil everywhere else
    /// (the glyph always stemifies there), so no other surface gains the panel.
    var onStemGlyph: (() -> Void)? = nil

    @State private var busy: Busy?
    @State private var alertMessage: String?

    enum Busy { case play, download }

    /// The current rip job, only while it's actively in flight (not ready/error).
    private var activeJob: RipsStore.Job? {
        guard let j = rips.jobs[song.id], j.phase != .ready, j.phase != .error else { return nil }
        return j
    }
    private var errored: Bool { rips.jobs[song.id]?.phase == .error }
    private var cached: Bool { rips.cachedURL(song.id) != nil }
    /// This song has been separated into stems (accent-tint the line.3.horizontal glyph).
    private var stemmed: Bool {
        rips.isStemmed(song.id)
            || (ProfileSourceStore.isProfileSongId(song.id) && profileSource?.stemURLs(id: song.id) != nil)
    }
    /// The stem job's phase only while actively working (not ready/error/ineligible).
    private var stemJobPhase: RipsStore.StemPhase? {
        // Already stemmed (per the manifest) ⇒ NOT busy, even if a stale collection-stemify job
        // entry still says "queued" (the batch path seeds .queued and never per-row updates it;
        // the manifest is the source of truth for completion).
        if stemmed { return nil }
        guard let j = rips.stemJobs[song.id], j.phase != .ready, j.phase != .error, j.phase != .ineligible else { return nil }
        return j.phase
    }
    private var stemBusy: Bool { stemJobPhase != nil }
    private var stemPhaseLabel: String {
        switch stemJobPhase {
        case .queued:   return "Queued…"
        case .ripping:  return "Ripping first…"
        case .stemming: return "Stemming…"
        default:        return ""
        }
    }
    /// A burned local file exists for this song (device-mode playable with no server).
    private var hasBurnedFile: Bool { burns.localURL(forSong: song.id) != nil }
    /// The user asked for this download and it hasn't landed yet — persisted in `BurnStore`, so the
    /// row shows the same truth after a relaunch as it did the moment they tapped.
    private var awaitingBurn: Bool { burns.isAwaitingBurn(song.id) }
    /// Actionable when already ripped, there's a (configured) server to rip it, or a burned
    /// local file is present (so device mode can play it even with no rip server). Gates the
    /// DOWNLOAD/stemify halves — streaming can't satisfy those.
    private var canAct: Bool { cached || rips.hasServer || hasBurnedFile }
    /// The ▶ additionally enables for a STREAMABLE row (catalog id + Apple Music ready) — the
    /// public-user audit fix: a user's own "Apple Music" library rows play via their
    /// subscription with no rip server at all (doPlay already routes through the coordinator).
    private var canPlay: Bool {
        canAct || (app.songsById[song.id]?.appleMusicId != nil && coordinator.canStreamAppleMusic)
    }

    /// True when THIS row's song is the live now-playing one — on EITHER backend: the rip
    /// path (keyed off `RipsStore.nowPlaying`, unchanged) OR Apple Music streaming (keyed
    /// off the coordinator). The ▶ then becomes a pause/resume toggle instead of replaying.
    private var isNowPlaying: Bool {
        rips.nowPlaying?.songId == song.id || coordinator.isAppleMusicNowPlaying(song.id)
    }
    /// Is the Apple Music streaming backend the active one for this row? (Selects the
    /// glyph/toggle source — `coordinator` vs. the rip `PlayerEngine`.)
    private var isAppleMusic: Bool { coordinator.isAppleMusicNowPlaying(song.id) }

    var body: some View {
        Group {
            if let job = activeJob {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    // While a download is waiting on this rip, say what it's FOR — "Ripping…" alone
                    // doesn't tell the user their ⤓ was heard.
                    Text(awaitingBurn ? "\(RowTransport.phaseLabel(job)) → download"
                                      : RowTransport.phaseLabel(job))
                        .font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                .accessibilityIdentifier("rip-status-\(song.id)")
            } else if awaitingBurn {
                // Rip finished (or hasn't reported a phase yet) and the burn is the outstanding
                // half. Durable: this state comes from the STORE, not view state, so it survives
                // scrolling the row away, leaving the screen, and relaunching the app.
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading…").font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                .accessibilityIdentifier("burn-status-\(song.id)")
            } else {
                HStack(spacing: 2) {
                    Button { doPlay() } label: {
                        Image(systemName: rowPlayIcon).font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle((canPlay || isNowPlaying) ? Theme.accent : Theme.fgDim)
                    .disabled((!canPlay && !isNowPlaying) || busy != nil)
                    .accessibilityIdentifier("row-play-\(song.id)")

                    // DOWNLOAD → ✓. A download now SAVES (into the burn folder from Settings, or
                    // the app-managed folder when none is set) instead of opening a save panel per
                    // track, and the glyph becomes a checkmark once the file is on disk. Tapping
                    // the checkmark is how you manage that file — delete it, or go look at it.
                    if hasBurnedFile, busy == nil {
                        Menu {
                            Button(role: .destructive) { burns.removeBurns(songIds: [song.id]) } label: {
                                Label("Delete download", systemImage: "trash")
                            }
                            if let url = burns.localURL(forSong: song.id) {
                                #if os(macOS)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                                #else
                                // iOS/visionOS have no "reveal"; the share sheet is the honest
                                // equivalent — it carries "Save to Files" and a Files preview.
                                ShareLink(item: url) { Label("Show in Files", systemImage: "folder") }
                                #endif
                            }
                        } label: {
                            Image(systemName: "checkmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Downloaded")
                        .accessibilityIdentifier("row-download-\(song.id)")
                    } else {
                        Button { doDownload() } label: {
                            Image(systemName: busy == .download ? "ellipsis" : "arrow.down.circle").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(canAct ? Theme.fgDim : Theme.fgDim.opacity(0.4))
                        .disabled(!canAct || busy != nil)
                        .accessibilityIdentifier("row-download-\(song.id)")
                    }

                    // Stemify (line.3.horizontal): separate this song into stems on the server.
                    // A busy stem job shows a distinct ProgressView + phase label (Ripping first…/
                    // Stemming…), NOT the download ellipsis — minutes-long work warrants real
                    // feedback. "Stemmed" is the accent tint; the glyph stays line.3.horizontal.
                    if stemBusy {
                        HStack(spacing: 3) {
                            ProgressView().controlSize(.mini)
                            Text(stemPhaseLabel).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        .accessibilityIdentifier("row-stemify-\(song.id)")
                    } else {
                        Button { stemGlyphTapped() } label: {
                            Image(systemName: "line.3.horizontal").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(stemmed ? Theme.accent : (canAct ? Theme.fgDim : Theme.fgDim.opacity(0.4)))
                        // Toggling the SongDetail audition panel (stemmed + `onStemGlyph` set)
                        // needs no server — only kicking off a NEW stemify requires `canAct`.
                        .disabled((!canAct && !(stemmed && onStemGlyph != nil)) || busy != nil)
                        .accessibilityIdentifier("row-stemify-\(song.id)")
                    }
                }
            }
        }
        .alert("Couldn’t play", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }

    /// Pure phase → label mapping (mirrors the PWA's `RipButtons` switch).
    static func phaseLabel(_ job: RipsStore.Job) -> String {
        switch job.phase {
        case .queued:    return "Queued…"
        case .searching: return "Searching…"
        case .uploading: return "Uploading…"
        case .streaming: return "● Streaming live"
        case .ripping:
            if let total = job.progress?.totalMs {
                return "Ripping \(clock(job.progress?.elapsedMs)) / \(clock(total))"
            }
            return "Ripping…"
        case .ready, .error: return ""
        }
    }

    /// mm:ss for a millisecond value (matches the PWA's `clock`).
    static func clock(_ ms: Int?) -> String {
        guard let ms else { return "" }
        let s = Int((Double(ms) / 1000).rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// ▶ icon: while busy → ellipsis; on error → warning; when THIS song is the live
    /// now-playing one → pause/play mirroring the ACTIVE backend (Apple Music streaming via
    /// the coordinator, else the rip `PlayerEngine`); otherwise the plain ▶.
    private var rowPlayIcon: String {
        if busy == .play { return "ellipsis" }
        if isNowPlaying {
            let playing = isAppleMusic ? coordinator.isPlaying : player.isPlaying
            return playing ? "pause.fill" : "play.fill"
        }
        if errored { return "exclamationmark.triangle" }
        return "play.fill"
    }

    /// LAZY RIP ON MISS for the single-row ▶ — the same one-song, on-demand enqueue the
    /// sequencer uses (`RipsStore.requestEditionRipIfNeeded` → the existing durable queue +
    /// dedup under the variant id), fired when this tap had to degrade onto a legacy or
    /// other-edition file. Owner-gated like every other passive fan-out; idempotent, so
    /// repeated taps while the rip is in flight enqueue once.
    private func lazyRipWantedEdition(_ decision: EditionPolicy.Decision) {
        guard decision.edition != nil, coordinator.isCatalogOwner() else { return }
        Task { await rips.requestEditionRipIfNeeded(base: song.id, decision: decision) }
    }

    private func doPlay() {
        // Now-playing row: toggle the ACTIVE backend (pause / resume) — don't replay. Apple
        // Music pauses/resumes via the coordinator; everything else (a rip stream AND a BURNED
        // local file) toggles the shared `PlayerEngine` directly. A burned file has NO
        // coordinator backend (`activeBackend == nil`), so `coordinator.togglePlayPause()` would
        // no-op — the row's pause button was dead for burned songs until this split.
        if isNowPlaying { isAppleMusic ? coordinator.togglePlayPause() : player.toggle(); return }
        // The EDITION this tap should play — the SAME `EditionPolicy` decision the Play-All
        // sequencer stamps, so a single tap and Play-All can never play different cuts of the
        // same song. `cleanOnlyCollection` is rule 1's input (set by the collection detail
        // views); Browser rows pass false and ride the global preference alone.
        let decision = EditionPolicy.decide(song: app.songsById[song.id],
                                            collectionCleanOnly: cleanOnlyCollection,
                                            preferExplicitRaw: settings.preferExplicitVersionsRaw)
        // OFFLINE-FIRST: prefer a BURNED local file whenever one exists — zero-latency AND works
        // with NO network — in BOTH device and cloud mode (mirroring the Play-All sequencer's
        // burned-first rule, so single taps and Play-All agree). The lookup walks the edition
        // ladder: the wanted edition, then (preference only) the legacy burn, then the other
        // edition. Only when there's NO local file does cloud stream / device fall back to
        // cloud for this single tap.
        if let res = burns.localURLForPlayback(forSong: song.id, decision: decision) {
            if !res.isWanted { lazyRipWantedEdition(decision) }
            playLocalFile(res.url, songId: song.id, title: song.title, artist: song.artist,
                          startMs: burns.startMs(forSong: res.id), rips: rips, player: player,
                          release: res.release)
            return
        }
        busy = .play
        Task {
            // Hand the song to the matching engine: it tries Apple Music streaming FIRST for
            // an Apple Music (Local) song (when ready), else falls back to the rip server —
            // which rips/streams on demand and loads the SAME `PlayerEngine` the inline
            // waveform/scrubber binds to, EXACTLY as before. `variant` carries the edition
            // decision, so the stream resolves that edition's catalog id and any rip is keyed
            // under the variant id. A surfaced failure (no rip server / rip error) comes back
            // on `coordinator.lastErrorMessage`.
            await coordinator.play(id: song.id, title: song.title, artist: song.artist,
                                   variant: decision.edition)
            if let msg = coordinator.lastErrorMessage { alertMessage = msg }
            busy = nil
        }
    }

    /// SAVE, don't prompt. This used to resolve the bytes and then present `.fileExporter`, so
    /// every single track download meant a save panel and a decision about where to put it.
    /// `BurnStore.burn` already resolves the destination the way the rest of the app does — the
    /// folder from Settings when one is set, the app-managed burns directory when not — so a
    /// download now just lands there and the row flips to a checkmark.
    private func doDownload() {
        // NOTHING TO BURN YET ⇒ RIP IT, don't refuse. Tapping ⤓ on a track that hasn't been ripped
        // used to answer "there's nothing to save", which is a chore disguised as an error: the
        // user asked for the song, so get the song. The intent is recorded durably and the rip's
        // own phases render in this row; the burn finishes on its own whenever the file lands,
        // even if the app was closed in between.
        if !cached, burns.localURL(forSong: song.id) == nil {
            burns.burnWhenRipped(songId: song.id, title: song.title, artist: song.artist)
            Task {
                _ = await rips.requestRip(songId: song.id, title: song.title, artist: song.artist,
                                          appleMusicId: app.songsById[song.id]?.appleMusicId,
                                          lengthMs: app.songsById[song.id]?.length)
                // Already cached (a rip that finished elsewhere) ⇒ burn immediately.
                await burns.drainPendingAfterRip()
            }
            return
        }
        busy = .download
        Task {
            let r = await burns.burn([(id: song.id, title: song.title, artist: song.artist)])
            // Report the reasons that are actionable; a plain success says nothing (the row's
            // checkmark IS the confirmation).
            if r.outOfSpace {
                alertMessage = "There isn’t enough space to save “\(song.title)”."
            } else if r.folderUnavailable {
                alertMessage = "Your burnt-music folder couldn’t be written to. Check it in Settings — the download wasn’t saved."
            } else if r.failed > 0 {
                alertMessage = "“\(song.title)” couldn’t be saved."
            }
            busy = nil
        }
    }

    /// Stem-glyph tap: in SongDetail a stemmed song slides out the audition panel (`onStemGlyph`);
    /// otherwise (any other surface, or a not-yet-stemmed song) it kicks off Stemify.
    private func stemGlyphTapped() {
        if stemmed, let onStemGlyph { onStemGlyph() } else { doStemify() }
    }

    /// Fire-and-forget Stemify for THIS song. The server rips/cuts first if needed, then
    /// separates; the row reflects the live phase off `rips.stemJobs` and flips to the
    /// accent-tinted "stemmed" state once the manifest refresh lands.
    private func doStemify() {
        Task { await rips.stemify(song.id) }
    }
}

/// The inline slide-out player rendered directly below the now-playing row: play/pause,
/// a scrubber bound to `PlayerEngine` time (drag to seek), elapsed / duration labels, the
/// waveform image (or a "● live" badge for a live stream), and a chevron to collapse /
/// expand the panel. Lives inside `SongRowView`, so it works wherever a song row appears.
struct InlinePlayerPanel: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @State private var collapsed = false

    private var now: RipsStore.NowPlaying? { rips.nowPlaying }

    var body: some View {
        if let now {
            VStack(spacing: 8) {
                header(now)
                if !collapsed { InlinePlayerExpanded(now: now) }
            }
            .padding(10)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            // The border is a `RoundedRectangle` shape drawn in an `.overlay` — i.e. ON TOP
            // of the panel's controls. A Shape is hit-testable by default, so on macOS this
            // border was swallowing every click to the play/pause · chevron · ✕ buttons
            // beneath it (their actions never fired — the "dead slide-out buttons" bug).
            // `.allowsHitTesting(false)` lets clicks pass through to the controls.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .padding(.vertical, 4)
            // IMPORTANT: do NOT put an `.accessibilityIdentifier` on this container — on
            // macOS SwiftUI PROPAGATES a container id down to every descendant, clobbering
            // the children's own ids (`player-toggle` / `player-chevron` / `player-close` /
            // `player-seek`) so they all read back as "inline-player" and become
            // unaddressable. The panel's presence is instead detected via those child
            // controls. (This was why the slide-out buttons looked "dead" to any driver.)
        }
    }

    /// Always-visible header: play/pause · title · collapse chevron · close.
    ///
    /// The controls use `.buttonStyle(.borderless)` — NOT `.plain`. On macOS a `.plain`
    /// button hosted inside a panel that lives in a `ScrollView` + `LazyVStack` (this
    /// inline player) silently drops its tap: the press hit-tests onto the button frame
    /// but the action never fires (the user's "slide-out play/pause · ✕ · chevron are
    /// dead" bug, confirmed by a UI test reading a toggle-count probe). `.borderless`
    /// — the same style the row's working ▶/⤓ transport uses — fires reliably there.
    private func header(_ now: RipsStore.NowPlaying) -> some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("player-toggle")

            VStack(alignment: .leading, spacing: 1) {
                Text(now.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(now.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if now.live {
                Text("● live").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("player-live")
            }
            Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("player-chevron")

            Button { player.stop(); rips.setNowPlaying(nil) } label: {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("player-close")
        }
    }

}

/// The time-updating part of the panel — waveform + scrubber + time labels. Extracted
/// into its OWN view so reading `player.currentTime` (updates ~4×/s) re-renders only this
/// subview, NOT `InlinePlayerPanel`'s control buttons. On macOS those buttons would
/// otherwise be rebuilt 4×/s and intermittently drop clicks (the "freeze until you click
/// the slide-out" bug); isolating the churn here keeps play/pause · ✕ · chevron responsive.
private struct InlinePlayerExpanded: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppModel.self) private var app
    @State private var scrubbing: Double?
    let now: RipsStore.NowPlaying

    /// The song's length (seconds) from the catalog INDEX metadata — used as the scrubber's
    /// end-timestamp fallback when the audio file's real duration isn't known yet (still
    /// loading, or it couldn't be read), so the panel always shows a sensible "/ m:ss".
    private var catalogDurationSec: Double {
        Double(app.songsById[now.songId]?.length ?? 0) / 1000
    }

    var body: some View {
        if now.live {
            // A live HLS stream has no static duration to scrub against — show a live state.
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent2)
                Text("Streaming live as it rips").font(.caption2).foregroundStyle(Theme.fgDim)
                Spacer()
            }
            .frame(height: 36)
            .accessibilityIdentifier("player-wave-live")
        } else {
            VStack(spacing: 8) {
                if let wave = now.waveform {
                    // The waveform thumbnail. We do NOT use `AsyncImage`: on macOS its
                    // internal phase-transition churn, sitting next to the inline player's
                    // control buttons, makes those buttons drop clicks (the "dead slide-out
                    // play/pause · chevron · ✕" bug — proven by a UI test toggle-count
                    // probe). `WaveformView` loads the bytes once via URLSession and shows
                    // the result with a single state update, so the controls stay live.
                    WaveformView(url: wave)
                }
                scrubber
            }
        }
    }

    private var scrubber: some View {
        // The live position is SAMPLED on a `TimelineView` schedule rather than observed:
        // `player.clock.currentTime` is a plain, non-`@Observable` value, so a tick redraws
        // ONLY this TimelineView's content and never invalidates Observation state in the
        // panel — keeping the sibling control buttons' identity stable so their clicks
        // aren't dropped. Duration is observable (changes once per track) → slider range.
        // Fall back to the catalog index length so the END timestamp shows even when the audio
        // file's real duration isn't known (still loading, or the file couldn't be read).
        let duration = max(player.duration, catalogDurationSec, 0.01)
        return TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = scrubbing ?? player.clock.currentTime
            // Full-width slider so it lines up edge-to-edge with the waveform above it;
            // the elapsed / duration labels sit BELOW, flanking the two ends.
            VStack(spacing: 2) {
                Slider(value: Binding<Double>(get: { now }, set: { scrubbing = $0 }),
                       in: 0...duration) { editing in
                    if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                }
                .accessibilityIdentifier("player-seek")
                HStack {
                    Text(Self.clock(now))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Text(Self.clock(duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// The waveform thumbnail. Loads the image bytes ONCE with `URLSession` into a single
/// `@State`, rather than using `AsyncImage` — whose phase-transition churn, hosted next
/// to the inline player's control buttons, dropped their clicks on macOS (the dead
/// slide-out-buttons bug). A placeholder shows until the one-shot load resolves; the
/// resulting single state update doesn't disturb the sibling buttons' hit-testing.
private struct WaveformView: View {
    let url: URL
    @State private var image: Image?

    var body: some View {
        // A FIXED-SIZE container whose content swaps via `.overlay` (not an `if/else`
        // structural branch). Loading the image therefore neither resizes nor restructures
        // this view, so the enclosing panel never re-lays-out — and the sibling control
        // buttons keep their identity (their clicks aren't dropped) when the waveform
        // resolves. This is why we avoid `AsyncImage`, whose phase swaps DID restructure.
        // The image is the BACKGROUND of a fixed 36-pt container, scaled to FILL so it spans
        // the panel EDGE-TO-EDGE (lining up with the full-width scrubber below it), with any
        // vertical overflow CLIPPED to the fixed container by the `.clipShape`. The container
        // is non-interactive and can't resize the panel or reach the control buttons above —
        // so edge-to-edge fill does NOT reintroduce the slide-out-button breakage.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .background {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.bgOverlay)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .allowsHitTesting(false)
            .accessibilityIdentifier("player-wave")
            .task(id: url) {
                guard image == nil else { return }
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    #if canImport(UIKit)
                    if let ui = UIImage(data: data) { image = Image(uiImage: ui) }
                    #elseif canImport(AppKit)
                    if let ns = NSImage(data: data) { image = Image(nsImage: ns) }
                    #endif
                }
            }
    }
}

// MARK: - Studio performance-item row (playlists + pockets)

/// A collection row for a studio PERFORMANCE ITEM (sample/loop/sequence/instrumental) that rides
/// the collection's `songIds` but has no catalog `IndexSong`. Title + length resolve live from
/// `StudioStore` via `collections.studioLookup`; the kind comes from the id prefix. Shows a kind
/// badge, a repeat-count badge when it loops, and a context menu to set the repeat count / remove —
/// the in-collection editor (spec: repeat count via long-press / right-click). Playlists render
/// this where they used to show "(missing song)"; pockets where they rendered nothing.
struct StudioCollectionRow: View {
    @Environment(CollectionsStore.self) private var collections
    @Environment(StudioStore.self) private var studio
    let id: String
    let repeatCount: Int
    var onSetRepeat: (Int) -> Void
    var onRemove: () -> Void

    static let repeatPresets = [1, 2, 3, 4, 6, 8, 16]

    /// The item's waveform peaks (loaded async from its local file); empty ⇒ flat placeholder.
    @State private var peaks: [Float] = []

    private var info: (title: String, lengthMs: Int, bpm: Double?, camelot: String?)? {
        collections.studioLookup?(id)
    }
    private var kindLabel: String {
        if id.hasPrefix("lp_") { return "Loop" }
        if id.hasPrefix("ptn_") { return "Sequence" }
        if id.hasPrefix("tk_") { return "Instrumental" }
        return "Sample"
    }

    var body: some View {
        HStack(spacing: 10) {
            PocketDJArtwork().frame(width: 44, height: 44)   // default artwork for a studio item
            VStack(alignment: .leading, spacing: 3) {
                Text(info?.title ?? "Studio item").font(.callout.weight(.medium))
                    .foregroundStyle(Theme.fg).lineLimit(1)
                HStack(spacing: 6) {
                    badge(kindLabel, tint: Theme.accent2)
                    repeatMenu            // a TAPPABLE chip — the in-row repeat-count editor
                    if let bpm = info?.bpm { Text(Fmt.bpm(bpm) + " BPM").font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim) }
                    Spacer(minLength: 6)
                    // The item's own waveform (its playback audio) — a compact strip.
                    MixWaveformView(peaks: peaks, color: Theme.accent2, background: .clear)
                        .frame(width: 96, height: 18)
                }
            }
            Spacer(minLength: 0)
            if let ms = info?.lengthMs, ms > 0 {
                Text(Fmt.duration(ms)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityIdentifier("studio-collection-row-\(id)")
        .task(id: id) { peaks = await StudioWaveform.peaks(forStudioId: id, studio: studio) }
        .contextMenu {
            Menu {
                ForEach(StudioCollectionRow.repeatPresets, id: \.self) { n in
                    Button { onSetRepeat(n) } label: {
                        if n == repeatCount { Label(repeatLabel(n), systemImage: "checkmark") }
                        else { Text(repeatLabel(n)) }
                    }
                }
            } label: {
                Label("Repeat count", systemImage: "repeat")
            }
            Button(role: .destructive) { onRemove() } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func repeatLabel(_ n: Int) -> String { n == 1 ? "Play once" : "\(n)×" }

    /// The in-row repeat-count editor: an always-visible, tappable chip (a `Menu`, so it works
    /// reliably inside a List row — unlike a nested submenu in a long-press context menu). Shows
    /// the current count; tap to pick a new one.
    private var repeatMenu: some View {
        Menu {
            Text("Repeat count")
            ForEach(StudioCollectionRow.repeatPresets, id: \.self) { n in
                Button { onSetRepeat(n) } label: {
                    Label(repeatLabel(n), systemImage: n == repeatCount ? "checkmark" : "repeat")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "repeat").font(.system(size: 8, weight: .bold))
                Text("\(repeatCount)×").font(.caption2.weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.accent.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio-repeat-menu-\(id)")
    }

    @ViewBuilder
    private func badge(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// The default cover art for a studio PERFORMANCE ITEM (which has no album): the PocketDJ app icon,
/// loaded from the in-app `PocketDJIcon` imageset (the AppIcon sets aren't `Image()`-loadable).
/// Used wherever a studio item needs artwork — collection rows + Now Playing.
struct PocketDJArtwork: View {
    var corner: CGFloat = 6
    var body: some View {
        Image("PocketDJIcon")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
