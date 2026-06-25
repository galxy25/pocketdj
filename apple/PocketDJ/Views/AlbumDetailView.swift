import SwiftUI

/// Single-album close-up: cover + metadata header and the track table with the
/// DJ-relevant columns (BPM, key, Camelot) for beat- and key-matching.
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    let album: IndexAlbum
    @Binding var path: NavigationPath
    @State private var showEdit = false
    @State private var showAdd = false
    @State private var showAudioEdit = false
    /// One-shot guard so ▶/🔀 push the reusable Now Playing setlist once per visit; cleared
    /// on reappear so a fresh Play pushes again (mirrors PlaylistDetailView).
    @State private var nowPlayingPushed = false

    /// Latest (possibly edited) album from the catalog.
    private var current: IndexAlbum { app.albumsById[album.id] ?? album }
    private var tracks: [IndexSong] { app.tracks(for: current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                trackTable
                if current.hasAudioAnalysis { audioAnalysis }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(current.name)
        .accessibilityIdentifier("album-detail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Reappears when the user pops back from Now Playing — allow the next Play to push.
        .onAppear { nowPlayingPushed = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
                    .help("Play this album now")
                    .disabled(tracks.isEmpty)
                    .accessibilityIdentifier("album-play")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Shuffle-play this album now")
                    .disabled(tracks.isEmpty)
                    .accessibilityIdentifier("album-shuffle")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus.circle") }
                    .accessibilityIdentifier("add-album-to")
                Button("Edit") { showEdit = true }.accessibilityIdentifier("edit-album")
            }
        }
        .sheet(isPresented: $showEdit) { EditAlbumView(album: current) }
        .sheet(isPresented: $showAdd) { AddToCollectionView(item: .album(current.id)) }
        .sheet(isPresented: $showAudioEdit) { EditAudioAnalysisView(album: current) }
    }

    /// ▶ Play / 🔀 Shuffle the album's tracks into the reusable "Now Playing" setlist
    /// (literal order, or shuffled) and open it autostarting — the same mechanism the
    /// playlist ▶/🔀 use. Re-tapping while it's on screen re-snapshots instead of stacking.
    private func play(shuffle: Bool) {
        collections.playNow(songIds: tracks.map(\.id), name: current.name, shuffle: shuffle)
        if !nowPlayingPushed {
            nowPlayingPushed = true
            path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverImage(album: current)
                .frame(width: 168, height: 168)
            VStack(alignment: .leading, spacing: 8) {
                Text(current.name)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.fg)
                Text(current.artist)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 8) {
                    if let g = current.genre { Tag(text: g, color: Theme.accent) }
                    if let y = current.year { Tag(text: String(y), color: Theme.accent2) }
                    if let c = current.country { Tag(text: c, color: Theme.fgDim) }
                }
                if let src = app.source(ofAlbum: current.id) {
                    Tag(text: src, color: Theme.fgDim)
                        .accessibilityIdentifier("source-tag")
                }
                Text("\(tracks.count) tracks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    private var trackTable: some View {
        VStack(spacing: 0) {
            TrackRowHeader()
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, song in
                VStack(spacing: 0) {
                    NavigationLink(value: song) {
                        TrackRow(index: song.trackNumber ?? (idx + 1), song: song)
                            .background(idx.isMultiple(of: 2) ? Color.clear : Theme.bgRaised.opacity(0.4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("track-\(song.id)")
                    // Inline slide-out player below this track when it's the one playing.
                    InlinePlayerSlot(songId: song.id)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// Album-level audio-analysis segments (BPM/key/Camelot per detected segment).
    private var audioAnalysis: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Audio analysis", systemImage: "waveform").font(.headline).foregroundStyle(Theme.fg)
                Spacer()
                if let d = current.audioDurationSec {
                    Text("\(Int(d) / 60):\(String(format: "%02d", Int(d) % 60)) total")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                Button("Edit") { showAudioEdit = true }
                    .font(.caption)
                    .accessibilityIdentifier("edit-audio")
            }
            VStack(spacing: 0) {
                ForEach(Array((current.audioTracks ?? []).enumerated()), id: \.offset) { i, seg in
                    AudioSegmentRow(index: seg.trackNumber ?? (i + 1), seg: seg)
                        .background(i.isMultiple(of: 2) ? Color.clear : Theme.bgRaised.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

private struct AudioSegmentRow: View {
    let index: Int
    let seg: AudioTrack
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(Theme.fgDim)
                .frame(width: 24, alignment: .trailing)
            Text("\(Fmt.duration(seg.startMs)) – \(Fmt.duration(seg.endMs))")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.bpm(seg.bpm)).font(.callout.monospacedDigit()).foregroundStyle(Theme.fg)
                .frame(width: 48, alignment: .trailing)
            KeyChip(key: seg.key, camelot: seg.camelot).frame(width: 84, alignment: .leading)
            Text(seg.keyStrength.map { "\(Int($0 * 100))%" } ?? "–")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct TrackRowHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("#").frame(width: 24, alignment: .trailing)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("BPM").frame(width: 48, alignment: .trailing)
            Text("Key").frame(width: 84, alignment: .leading)
            Text("Time").frame(width: 48, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(Theme.fgDim)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgOverlay)
    }
}

private struct TrackRow: View {
    let index: Int
    let song: IndexSong

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.fgDim)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.name)
                        .font(.callout)
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    if song.explicit == true {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                    }
                }
                if let kw = song.sentimentKeywords, !kw.isEmpty {
                    Text(kw.prefix(3).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Fmt.bpm(song.bpm))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.fg)
                .frame(width: 48, alignment: .trailing)

            KeyChip(key: song.key, camelot: song.camelot)
                .frame(width: 84, alignment: .leading)

            Text(Fmt.duration(song.length))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.fgDim)
                .frame(width: 48, alignment: .trailing)

            // Same play / download transport as the browser + collection rows.
            RowTransport(song: (id: song.id, title: song.name, artist: song.artist), startMs: nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
