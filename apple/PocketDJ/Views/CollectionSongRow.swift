import SwiftUI

/// A rich, PWA-style song row for collection detail views (playlists, pockets,
/// setlists, index playlists). The MUSIC INFO is the prominent middle cluster:
///   • LEFT: album-art thumbnail (resolved via app.albumsById[song.albumId];
///     graceful placeholder when the album is missing/unknown),
///   • PRIMARY line: song title (+ explicit "E" badge),
///   • SECONDARY line: "year · genre" (genre resolved from the song's album),
///   • MIDDLE music cluster: BPM as tiered play-icons (+ numeric), a Camelot
///     KeyChip (always populated — "U" box when unknown), and the song length,
///   • RIGHT: ▶ play / ⤓ download VISUAL PLACEHOLDERS (the native app has no
///     rip-on-demand client — see reserved seam below).
///
/// This is presentation only — wrap it in a NavigationLink for tap-through to the
/// song detail, and attach swipe/move/delete on the enclosing row.
struct CollectionSongRow: View {
    @Environment(AppModel.self) private var app
    let song: IndexSong
    /// Optional pre-resolved album name (avoids a second lookup when the caller has it).
    var albumName: String?
    /// Optional trailing accessory (e.g. a setlist source badge column) shown left of
    /// the play/download buttons.
    var trailingNote: String?

    private var album: IndexAlbum? { song.albumId.flatMap { app.albumsById[$0] } }
    /// Genre resolves from the song's album (songs carry no genre of their own).
    private var genre: String? {
        let g = album?.genre?.trimmingCharacters(in: .whitespaces)
        return (g?.isEmpty == false) ? g : nil
    }
    /// Year prefers the song's own year, falling back to the album's.
    private var year: Int? { song.year ?? album?.year }

    /// "year · genre" — the secondary descriptor line (em-dash when neither known).
    private var descriptor: String {
        [year.map(String.init), genre].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.name).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                    if song.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                    }
                }
                Text(descriptor.isEmpty ? "—" : descriptor)
                    .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Middle music cluster: BPM tiers · KeyChip · length. The prominent
            // "what does this sound like" block, right-aligned ahead of transport.
            HStack(spacing: 8) {
                BPMTier(bpm: song.bpm)
                KeyChip(key: song.key, camelot: song.camelot)
                Text(Fmt.duration(song.length))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }

            if let trailingNote, !trailingNote.isEmpty {
                Text(trailingNote).font(.caption2).foregroundStyle(Theme.fgDim)
            }

            transportButtons
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View { SongThumbnail(album: album) }
    private var transportButtons: some View { TransportPlaceholders(songId: song.id) }
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
        HStack(spacing: 4) {
            if let t = BPMTier.tier(bpm) {
                HStack(spacing: 1) {
                    ForEach(0..<t, id: \.self) { _ in
                        Image(systemName: "play.fill").font(.system(size: 7))
                    }
                }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("bpm-tier-\(t)")
                Text(Fmt.bpm(bpm)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            } else {
                Text("–").font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("bpm-tier-none")
            }
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
