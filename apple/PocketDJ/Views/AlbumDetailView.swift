import SwiftUI

/// Single-album close-up: cover + metadata header and the track table with the
/// DJ-relevant columns (BPM, key, Camelot) for beat- and key-matching.
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(CollectionsStore.self) private var collections
    @Environment(RipsStore.self) private var rips
    @Environment(StreamingStore.self) private var streaming
    let album: IndexAlbum
    @Binding var path: NavigationPath
    @State private var showEdit = false
    @State private var showAdd = false
    @State private var showAudioEdit = false
    /// "Add to Apple Music again" (provisional Discover albums only) in flight.
    @State private var retryingLibraryWrite = false
    /// Album-level "Stemify each song" — reuses the shared collection controller (progress
    /// pill + over-cap confirm). Per-track Stemify is already free via each row's RowTransport.
    @State private var ripBurn = CollectionRipBurnController()
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
            ToolbarItem(placement: .primaryAction) {
                Button { ripBurn.stemify(tracks.map(\.id), rips: rips, noun: "album") } label: {
                    Label("Stemify", systemImage: "line.3.horizontal")
                }
                .help("Separate every song on this album into stems")
                .disabled(tracks.isEmpty || ripBurn.working || !rips.hasServer)
                .accessibilityIdentifier("album-stemify")
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: ShareText.forAlbum(current),
                          subject: Text("\(current.name) — \(current.artist)")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share this album")
                .accessibilityIdentifier("album-share")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus.circle") }
                    .accessibilityIdentifier("add-album-to")
                Button("Edit") { showEdit = true }.accessibilityIdentifier("edit-album")
            }
        }
        .collectionRipBurn(ripBurn)
        .sheet(isPresented: $showEdit) { EditAlbumView(album: current) }
        .sheet(isPresented: $showAdd) { AddToCollectionView(item: .album(current.id)) }
        .sheet(isPresented: $showAudioEdit) { EditAudioAnalysisView(album: current) }
    }

    /// ▶ Play / 🔀 Shuffle the album's tracks into the reusable "Now Playing" setlist
    /// (literal order, or shuffled) and open it autostarting — the same mechanism the
    /// playlist ▶/🔀 use. Re-tapping while it's on screen re-snapshots instead of stacking.
    private func play(shuffle: Bool) {
        collections.playNow(songIds: tracks.map(\.id), name: current.name, shuffle: shuffle, source: .album,
                            originId: current.id)
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
                // Artist is a HOTLINK to the artist's page (all their albums). Pushes
                // straight onto the shared nav stack — deterministic, and it leaves the
                // album underneath so Back returns here. Both presentations that show this
                // view register the `Artist` destination: RootView's stack, and the Shazam
                // result sheet's stack. (SongDetailView must route via IntentRoute instead
                // because it also appears in sheets that DON'T register `Artist`.)
                Button {
                    path.append(Artist(name: current.artist))
                } label: {
                    Text(current.artist)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("artist-hotlink")
                HStack(spacing: 8) {
                    if let g = current.genre { Tag(text: g, color: Theme.accent) }
                    if let y = current.year { Tag(text: String(y), color: Theme.accent2) }
                    if let c = current.country { Tag(text: c, color: Theme.fgDim) }
                }
                if let src = app.source(ofAlbum: current.id) {
                    Tag(text: src, color: Theme.fgDim)
                        .accessibilityIdentifier("source-tag")
                }
                libraryWriteRetry
                Text("\(tracks.count) tracks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
                // Whole-album queueing sits beside the track count, not in the toolbar — that
                // already carries five primaryAction items and overflows on iPhone.
                if sequencer.isRunning {
                    Menu {
                        QueueMenuItems(songs: tracks, noun: "Album")
                    } label: {
                        Image(systemName: "text.append").font(.caption)
                    }
                    .accessibilityIdentifier("album-queue-menu")
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    /// The provisional Discover entry backing THIS album, when it is one (`amrec_album_…`).
    private var discoverAlbumEntry: DiscoverAddsStore.AlbumEntry? {
        rips.discoverAdds?.albums.first { $0.albumId == current.id }
    }

    /// "Add to Apple Music again" for a provisional Discover album whose Apple Music
    /// library write isn't PROVEN (recorded failure/skip/unconfirmed, or a legacy entry
    /// from before write outcomes were tracked — Levi's four silently-failed albums).
    /// It lives HERE because this is the screen those albums are still reachable from:
    /// the New feed now correctly hides owned albums, so the feed offers no way back to
    /// the failed write. Idempotent on Apple's side, so a legacy entry that DID land is
    /// safe to re-add.
    @ViewBuilder private var libraryWriteRetry: some View {
        if let entry = discoverAlbumEntry,
           AlbumLibraryWriteRetry.needsRetry(
               token: entry.libraryWrite,
               canAddToLibrary: streaming.providers.libraryContributors.first?.canAddToLibrary ?? false) {
            VStack(alignment: .leading, spacing: 4) {
                if let note = entry.libraryWrite {
                    Text(note).font(.caption2).foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("album-am-note")
                }
                Button {
                    retryLibraryWrite(entry)
                } label: {
                    Label {
                        Text(retryingLibraryWrite ? "Adding to Apple Music…" : "Add to Apple Music again")
                    } icon: {
                        if retryingLibraryWrite { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise.circle") }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
                .disabled(retryingLibraryWrite)
                .accessibilityIdentifier("album-am-retry")
            }
        } else if let entry = discoverAlbumEntry,
                  AppleMusicLibraryWriteOutcome.provenByToken(entry.libraryWrite) {
            // The heal's receipt: a PROVEN write reads as such (and the button is gone).
            Label("In your Apple Music library", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
                .accessibilityIdentifier("album-am-confirmed")
        }
    }

    private func retryLibraryWrite(_ entry: DiscoverAddsStore.AlbumEntry) {
        retryingLibraryWrite = true
        Task {
            _ = await rips.retryAlbumLibraryWrite(
                albumId: entry.albumId, appleMusicId: entry.appleMusicId,
                library: streaming.providers.libraryContributors.first)
            retryingLibraryWrite = false
        }
    }

    private var trackTable: some View {
        VStack(spacing: 0) {
            TrackRowHeader()
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, song in
                VStack(spacing: 0) {
                    // The ♥ and the transport are SIBLINGS of the NavigationLink, never inside
                    // its label. Nesting them cost macOS ACCESSIBILITY: AppKit collapses a link's
                    // label into one accessibility element, so `favorite-toggle-…` / `row-play-…`
                    // vanished from the tree entirely — unreachable by VoiceOver, and invisible to
                    // XCUITest, which is why the two FavoritesUITests could not run here. (iOS
                    // keeps them in the tree, which is why it went unnoticed.)
                    //
                    // MOUSE CLICKS WERE NEVER BROKEN — measured, don't re-derive it. A 4pt sweep
                    // across the pre-fix row, resetting the favorite before every click, put the ♥
                    // at screen x≈3259 and clicks there favorited the track without navigating;
                    // only the GAPS between controls fell through to the link, which is correct.
                    // An earlier claim that the click "opened the song instead" came from clicking
                    // the Key/Time columns by mistake and is wrong.
                    HStack(spacing: 10) {
                        NavigationLink(value: song) {
                            TrackRowInfo(index: song.trackNumber ?? (idx + 1), song: song)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("track-\(song.id)")
                        .contextMenu { QueueMenuItems(songs: [song]) }

                        FavoriteToggle(songId: song.id, appleMusicId: song.appleMusicId)
                        RowTransport(song: (id: song.id, title: song.name, artist: song.artist),
                                     startMs: nil)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(idx.isMultiple(of: 2) ? Color.clear : Theme.bgRaised.opacity(0.4))
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

/// The informational columns of a track row — #, title, BPM, key, time. The ♥ and the
/// transport are deliberately NOT here: they are laid out beside this view so they stay
/// outside the row's `NavigationLink` label (see `trackTable`).
private struct TrackRowInfo: View {
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
        }
    }
}
