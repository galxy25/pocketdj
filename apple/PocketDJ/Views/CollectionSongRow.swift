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
///   • RIGHT: ▶ play / ⤓ download VISUAL PLACEHOLDERS (`TransportPlaceholders`) — the
///     native app has no rip-on-demand client yet (reserved seam).
///
/// Responsive: on COMPACT width (iPhone) the year + genre are dropped from the
/// secondary line to keep it uncluttered; on regular width (iPad) and macOS (where
/// `horizontalSizeClass` is nil) they SHOW. Title, the music cluster, and transport
/// are visible at every size.
///
/// Presentation only — wrap in a `NavigationLink` for tap-through and attach
/// swipe / move / delete / notes / context-menus on the enclosing row.
struct SongRowView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    let data: SongRowData
    /// Optional trailing accessory (e.g. a setlist source/sequence badge column) shown
    /// to the left of the play/download buttons.
    var trailing: AnyView?

    /// Show year/genre only when there's room: regular width (iPad) or macOS (nil).
    private var showsExtra: Bool { hSize != .compact }

    /// Secondary descriptor — "artist · year · genre"; year/genre size-gated.
    private var descriptor: String {
        var parts: [String] = []
        if !data.artist.isEmpty { parts.append(data.artist) }
        if showsExtra {
            if let y = data.year { parts.append(String(y)) }
            if let g = data.genre, !g.isEmpty { parts.append(g) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            SongThumbnail(album: data.album).frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(data.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                    if data.explicit {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                            .accessibilityIdentifier("explicit-badge")
                    }
                }
                Text(descriptor.isEmpty ? "—" : descriptor)
                    .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Middle music cluster: BPM tiers · KeyChip · length. The prominent
            // "what does this sound like" block, right-aligned ahead of transport.
            HStack(spacing: 8) {
                BPMTier(bpm: data.bpm)
                KeyChip(key: data.key, camelot: data.camelot)
                Text(Fmt.duration(data.lengthMs))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }

            if let trailing { trailing }

            TransportPlaceholders(songId: data.songId)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
    /// The album behind the song (for cover art + genre/year fallback); nil → placeholder.
    var album: IndexAlbum?

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
        self.album = album
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
        self.album = album
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
    let song: IndexSong
    /// Optional trailing accessory shown left of the transport buttons.
    var trailing: AnyView?

    private var album: IndexAlbum? { song.albumId.flatMap { app.albumsById[$0] } }

    var body: some View {
        SongRowView(data: SongRowData(song: song, album: album), trailing: trailing)
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
    var body: some View {
        if let album {
            CoverImage(album: album, corner: 6)
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

/// ▶ / ⤓ — VISUAL PLACEHOLDERS ONLY, intentionally non-functional.
/// reserved seam: wire to a future rip-on-demand client (RipServerService today
/// only exposes health(); there is no native stream/download path yet).
struct TransportPlaceholders: View {
    let songId: String
    var body: some View {
        HStack(spacing: 2) {
            Button {
                // reserved seam: wire to a future rip-on-demand client
            } label: {
                Image(systemName: "play.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("row-play-\(songId)")

            Button {
                // reserved seam: wire to a future rip-on-demand client
            } label: {
                Image(systemName: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("row-download-\(songId)")
        }
    }
}
