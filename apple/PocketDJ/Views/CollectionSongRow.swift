import SwiftUI

/// A rich, PWA-style song row for collection detail views (playlists, pockets,
/// setlists, index playlists). Mirrors the PWA's song row:
///   • LEFT: album-art thumbnail (resolved via app.albumsById[song.albumId];
///     graceful placeholder when the album is missing/unknown),
///   • MIDDLE: title, then "artist · album", then BPM + a Camelot KeyChip,
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
    private var resolvedAlbumName: String { albumName ?? album?.name ?? "" }

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
                Text("\(song.artist)\(resolvedAlbumName.isEmpty ? "" : " · \(resolvedAlbumName)")")
                    .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(Fmt.bpm(song.bpm)) BPM").font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    KeyChip(key: song.key, camelot: song.camelot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
