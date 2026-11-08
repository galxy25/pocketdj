import SwiftUI

#if !os(tvOS)
/// The WHOLE vinyl side as one waveform on the album page (Levi, 2026-11-07): every song's
/// region marked on the record, a live playhead while the side plays, and direct editing.
///
///   • tap / drag on the waveform — play from that point (the song under it becomes Now
///     Playing; the album file keeps playing through every boundary from there),
///   • drag a marker's handle (the dots above the waveform) — move where that song STARTS
///     (= where the previous one ends); the last handle is the side's END,
///   • tap a handle — select it for fine nudges (±0.1 s / ±1 s) or "Set to playhead",
///   • double-tap a song's region — rename the track.
///
/// Boundaries save as `AlbumEdit.audioTracks` deltas (the synced edits document) and re-time
/// playback through `SegmentOverrides`; renames save as `SongEdit.name`. Both re-overlay the
/// catalog at once, so Now Playing shows the new title / boundary on the next song.
struct AlbumWaveformEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(SetlistPlayer.self) private var sequencer

    let album: IndexAlbum
    /// Start the album at track `index`, `atMs` into that track (the view isn't the album's
    /// player yet — the album page owns how a play is launched).
    let playFrom: (_ index: Int, _ atMs: Int) -> Void

    @State private var image: Image?
    @State private var scrubMs: Int?
    /// A handle being dragged: (boundary index, live position ms).
    @State private var dragging: (index: Int, ms: Int)?
    /// The handle selected for nudging (boundary index; `trackList.count` = the side's end).
    @State private var selected: Int?
    @State private var renaming: IndexSong?
    /// The current pan was judged VERTICAL (a page scroll that started on the waveform) — it
    /// neither scrubs nor plays.
    @State private var panIsVertical = false
    @State private var renameText = ""

    private static let handleBand: CGFloat = 22
    private static let waveHeight: CGFloat = 96
    /// Two songs can never be closer than this (a boundary can't be dragged past its neighbour).
    private static let minGapMs = 1_000

    // MARK: Model

    /// Song `i` of the track list (by id, so a missing catalog row can't shift the pairing).
    private func song(_ i: Int) -> IndexSong? {
        i < album.trackList.count ? app.songsById[album.trackList[i]] : nil
    }
    private func name(_ i: Int) -> String { song(i)?.name ?? "Track \(i + 1)" }
    /// Song `i`'s key color — its Camelot hue, the same color its key chip shows in the track
    /// list (Levi, 2026-11-08: "the individual track section should match whatever the key
    /// color is for that track"). The catalog key wins; the album analysis's per-segment key
    /// fills in; unknown keys tint neutral grey.
    private func keyColor(_ i: Int) -> Color {
        let seg = album.audioTracks.flatMap { i < $0.count ? $0[i] : nil }
        return Camelot.color(song(i)?.camelot ?? seg?.camelot)
    }

    /// The shared file's manifest key, when any song of the album is ripped as a side.
    private var fileKey: String? {
        album.trackList.lazy.compactMap { id in
            rips.manifest[id].flatMap { $0.startMs != nil ? $0.key : nil }
        }.first
    }

    /// Per-song starts in track order: the user's edit, else the rip manifest (what playback
    /// seeks to), else the indexer's detected segment. nil when any song has no known start.
    private var starts: [Int]? {
        let ov = SegmentOverrides.shared.snapshot
        let segs = album.audioTracks ?? []
        let ids = album.trackList
        guard !ids.isEmpty else { return nil }
        var out: [Int] = []
        for (i, id) in ids.enumerated() {
            guard let s = rips.effectiveStartMs(id) ?? ov.startMs[id]
                    ?? (segs.count == ids.count ? segs[i].startMs : nil) else { return nil }
            out.append(s)
        }
        return out
    }

    /// The side's total length (ms): the loaded file's real duration when the AVPlayer plays it
    /// (an engaged DSP's duration is one song's slice), else the indexer's measured length,
    /// else past the last segment's end.
    private func totalMs(starts: [Int]) -> Int {
        if isLoaded, sequencer.playerOwnsSideClock, player.duration > 0 { return Int(player.duration * 1000) }
        if let d = album.audioDurationSec, d > 0 { return Int(d * 1000) }
        let lastEnd = album.audioTracks?.last?.endMs ?? 0
        return max(lastEnd, (starts.last ?? 0) + 240_000)
    }

    /// The same layout playback uses (`AlbumFileTimeline`) over the displayed starts.
    private func timeline(starts: [Int]) -> AlbumFileTimeline {
        let layout = SegmentOverrides.shared.snapshot
        return AlbumFileTimeline(key: fileKey ?? album.id,
                                 segments: zip(album.trackList, starts).map { .init(songId: $0, startMs: $1) },
                                 exactEndMs: layout.endMs, detectedEndMs: layout.detectedEndMs)
    }

    /// Where song `i` stops playing (what playback does): its edited / detected(+grace) end,
    /// never past the next start; the side's end for the last song when nothing is known.
    private func endMs(_ i: Int, starts: [Int], total: Int) -> Int {
        guard i < album.trackList.count else { return total }
        let next = i + 1 < starts.count ? starts[i + 1] : total
        return min(timeline(starts: starts).endMs(of: album.trackList[i]) ?? next, total)
    }

    /// The last song's END on the record (the side's end handle).
    private func lastEndMs(starts: [Int], total: Int) -> Int {
        endMs(starts.count - 1, starts: starts, total: total)
    }

    /// The playhead inside the side (absolute ms): the running set's own reading (correct with
    /// an engaged Mix/Lock DSP), else a single-row play's AVPlayer clock.
    private func playheadMs() -> Int? {
        guard isLoaded else { return nil }
        if let p = sequencer.albumFilePositionMs() { return p }
        return sequencer.isRunning ? nil : Int(player.clock.currentTime * 1000)
    }

    /// The player has THIS side loaded (a song of this album playing from its shared file).
    private var isLoaded: Bool {
        guard let np = rips.nowPlaying, !np.live, np.startMs != nil else { return false }
        return album.trackList.contains(SongVariant.baseId(np.songId))
    }

    /// Boundary edits need the detected segments to pair 1:1 with the track list.
    private var editable: Bool {
        let raw = app.rawAlbum(album.id) ?? album
        return (raw.audioTracks?.count ?? 0) == album.trackList.count && !album.trackList.isEmpty
    }

    private var waveformURL: URL? {
        album.trackList.lazy.compactMap { RipsStore.waveformURL(for: rips.manifest[$0], ripsBase: Config.ripsBase) }.first
    }

    private func index(atMs ms: Int, starts: [Int]) -> Int {
        starts.lastIndex { $0 <= ms } ?? 0
    }

    // MARK: Body

    var body: some View {
        if let starts {
            let total = max(1, totalMs(starts: starts))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Album Waveform").font(.headline).foregroundStyle(Theme.fg)
                    Spacer()
                    Text(readout(starts: starts, total: total))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    canvas(width: geo.size.width, starts: starts, total: total)
                }
                .frame(height: Self.handleBand + Self.waveHeight + 18)
                .accessibilityIdentifier("album-waveform")
                if let sel = selected, editable { nudgeBar(sel, starts: starts, total: total) }
                Text(editable
                     ? "Tap to play from any point · drag a dot to move a song boundary · double-tap a song to rename it"
                     : "Tap to play from any point · double-tap a song to rename it")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
            .task(id: waveformURL) { await loadImage() }
            .alert("Rename track", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $renameText)
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func canvas(width: CGFloat, starts: [Int], total: Int) -> some View {
        let w = max(width, 1)
        let x: (Int) -> CGFloat = { ms in CGFloat(min(max(ms, 0), total)) / CGFloat(total) * w }
        let ms: (CGFloat) -> Int = { px in Int((min(max(px, 0), w) / w) * CGFloat(total)) }
        let effStarts = starts.enumerated().map { i, s in dragging?.index == i ? dragging!.ms : s }
        let sideEnd = dragging?.index == starts.count ? dragging!.ms : lastEndMs(starts: starts, total: total)
        // Each song's region runs to where it STOPS playing (a gap / the run-out stays untinted).
        let ends: [Int] = effStarts.indices.map { i in
            if i == effStarts.count - 1 { return sideEnd }
            if dragging?.index == i + 1 { return effStarts[i + 1] }   // a moved start ends the previous song
            return min(endMs(i, starts: starts, total: total), effStarts[i + 1])
        }
        return ZStack(alignment: .topLeading) {
            // The waveform image itself (fills the whole side's width).
            Group {
                if let image {
                    image.resizable().frame(width: w, height: Self.waveHeight)
                } else {
                    Rectangle().fill(Theme.bgOverlay.opacity(0.5)).frame(width: w, height: Self.waveHeight)
                        .overlay(Text(fileKey == nil ? "Waveform appears after the album's first play" : "Loading waveform…")
                            .font(.caption2).foregroundStyle(Theme.fgDim))
                }
            }
            .offset(y: Self.handleBand)
            .allowsHitTesting(false)
            // Song regions — each tinted with its track's KEY color OVER the waveform, with a
            // solid key-colored edge along the top — and their titles.
            ForEach(Array(effStarts.enumerated()), id: \.offset) { i, s in
                let rx = x(s), rw = max(1, x(ends[i]) - x(s))
                Rectangle()
                    .fill(keyColor(i).opacity(0.26))
                    .overlay(alignment: .top) { Rectangle().fill(keyColor(i)).frame(height: 3) }
                    .frame(width: rw, height: Self.waveHeight)
                    .offset(x: rx, y: Self.handleBand)
                Text(name(i))
                    .font(.caption2).foregroundStyle(Theme.fg).lineLimit(1)
                    .frame(width: max(0, rw - 6), alignment: .leading)
                    .offset(x: rx + 3, y: Self.handleBand + Self.waveHeight + 2)
            }
            // Boundary markers + their drag handles (the last one is the side's end).
            ForEach(0...effStarts.count, id: \.self) { i in
                let m = i < effStarts.count ? effStarts[i] : sideEnd
                marker(i, at: x(m), selected: selected == i)
            }
            // Playhead / scrub position.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let pos = scrubMs ?? playheadMs()
                if let pos {
                    Rectangle().fill(Theme.fg).frame(width: 2, height: Self.waveHeight)
                        .offset(x: x(pos) - 1, y: Self.handleBand)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: w, alignment: .topLeading)
        .contentShape(Rectangle())
        // Scrub: a HORIZONTAL drag on the waveform; a handle drag starts in the band above it.
        // Simultaneous with the page's ScrollView: a vertical pan that starts here still scrolls
        // the page and is ignored by the waveform (it neither scrubs nor plays).
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { v in
                    if dragging == nil, scrubMs == nil, !panIsVertical,
                       abs(v.translation.height) > abs(v.translation.width) {
                        panIsVertical = true
                    }
                    if panIsVertical { return }
                    if dragging == nil, v.startLocation.y < Self.handleBand, editable,
                       let i = nearestHandle(to: v.startLocation.x, starts: starts, total: total, w: w) {
                        dragging = (i, ms(v.location.x))
                    }
                    if let d = dragging {
                        dragging = (d.index, clamp(d.index, ms(v.location.x), starts: starts, total: total))
                    } else {
                        scrubMs = ms(v.location.x)
                    }
                }
                .onEnded { v in
                    if panIsVertical { panIsVertical = false; return }
                    if let d = dragging {
                        dragging = nil
                        selected = d.index
                        saveBoundary(d.index, d.ms, starts: starts)
                    } else {
                        let at = ms(v.location.x)
                        scrubMs = nil
                        play(atFileMs: at, starts: starts)
                    }
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { v in
                guard v.location.y >= Self.handleBand else { return }
                guard let song = song(index(atMs: ms(v.location.x), starts: starts)) else { return }
                renameText = song.name
                renaming = song
            }
            .exclusively(before: SpatialTapGesture().onEnded { v in
                if v.location.y < Self.handleBand {
                    selected = editable ? nearestHandle(to: v.location.x, starts: starts, total: total, w: w) : nil
                } else {
                    selected = nil
                    play(atFileMs: ms(v.location.x), starts: starts)
                }
            })
        )
    }

    private func marker(_ i: Int, at px: CGFloat, selected sel: Bool) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(sel ? Theme.accent : Theme.fg.opacity(0.55))
                .frame(width: sel ? 2 : 1, height: Self.waveHeight)
                .offset(y: Self.handleBand)
            if editable {
                Circle().fill(sel ? Theme.accent : Theme.fgDim)
                    .frame(width: 12, height: 12)
                    .offset(y: Self.handleBand - 14)
            }
        }
        .offset(x: px - 6)
        .frame(width: 12, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityIdentifier("album-wave-marker-\(i)")
    }

    private func nudgeBar(_ i: Int, starts: [Int], total: Int) -> some View {
        let isEnd = i == starts.count
        let current = isEnd ? lastEndMs(starts: starts, total: total) : starts[i]
        let label = isEnd ? "End of side" : "Start of \(name(i))"
        return HStack(spacing: 8) {
            Text("\(label) · \(Self.clock(current))")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg).lineLimit(1)
            Spacer()
            ForEach([-1000, -100, 100, 1000], id: \.self) { d in
                Button(d > 0 ? "+\(Self.step(d))" : "−\(Self.step(-d))") {
                    saveBoundary(i, clamp(i, current + d, starts: starts, total: total), starts: starts)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if let pos = playheadMs() {
                Button("Set to playhead") {
                    saveBoundary(i, clamp(i, pos, starts: starts, total: total), starts: starts)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Button { selected = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .accessibilityIdentifier("album-wave-nudge")
    }

    // MARK: Actions

    private func play(atFileMs at: Int, starts: [Int]) {
        if isLoaded, sequencer.seekAlbumFile(toFileMs: at) { return }
        let i = index(atMs: at, starts: starts)
        guard i < album.trackList.count else { return }
        let into = max(0, at - starts[i])
        if into > 0 { sequencer.cueNextStart(songId: album.trackList[i], atMs: into) }
        playFrom(i, into)
    }

    /// The nearest handle within reach of `px` (boundary index; `starts.count` = the end).
    private func nearestHandle(to px: CGFloat, starts: [Int], total: Int, w: CGFloat) -> Int? {
        let all = starts + [lastEndMs(starts: starts, total: total)]
        let xs = all.map { CGFloat($0) / CGFloat(total) * w }
        guard let best = xs.indices.min(by: { abs(xs[$0] - px) < abs(xs[$1] - px) }),
              abs(xs[best] - px) <= 22 else { return nil }
        return best
    }

    /// Keep boundary `i` strictly between its neighbours.
    private func clamp(_ i: Int, _ ms: Int, starts: [Int], total: Int) -> Int {
        let lo = i == 0 ? 0 : (i - 1 < starts.count ? starts[i - 1] + Self.minGapMs : 0)
        let hi = i + 1 < starts.count ? starts[i + 1] - Self.minGapMs
            : (i < starts.count ? lastEndMs(starts: starts, total: total) - Self.minGapMs : total)
        return min(max(ms, lo), max(lo, hi))
    }

    /// Persist boundary `i` at `ms` as an audio-analysis delta (song `i`'s start + song
    /// `i-1`'s end; `i == count` is the last song's end), then re-overlay the catalog.
    private func saveBoundary(_ i: Int, _ ms: Int, starts: [Int]) {
        guard editable else { return }
        let raw = app.rawAlbum(album.id) ?? album
        let segs = raw.audioTracks ?? []
        var edit = edits.albumEdit(album.id) ?? AlbumEdit()
        let old = edit.audioTracks ?? []
        // One delta per detected segment, aligned by index (existing ones carried over).
        var deltas: [AudioTrackEdit] = segs.enumerated().map { j, seg in
            if let n = seg.trackNumber, let d = old.first(where: { $0.trackNumber == n }) { return d }
            if j < old.count, old[j].trackNumber == nil { var d = old[j]; d.trackNumber = seg.trackNumber; return d }
            return AudioTrackEdit(trackNumber: seg.trackNumber)
        }
        if i < segs.count {
            deltas[i].startMs = ms == segs[i].startMs ? nil : ms
            if i > 0 { deltas[i - 1].endMs = ms == segs[i - 1].endMs ? nil : ms }
        } else if let last = segs.indices.last {
            deltas[last].endMs = ms == segs[last].endMs ? nil : ms
        }
        edit.audioTracks = deltas.contains { !$0.isEmpty } ? deltas : nil
        edits.setAlbum(album.id, edit)
        app.applyEdits()
        DiagLog.shared.telemetry("action", "album boundary edit album=\(album.id) index=\(i) ms=\(ms)")
    }

    private func saveRename() {
        guard let song = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var e = edits.songEdit(song.id) ?? SongEdit()
        e.name = name == (app.rawSong(song.id)?.name ?? song.name) ? nil : name
        edits.setSong(song.id, e)
        app.applyEdits()
    }

    private func loadImage() async {
        guard let url = waveformURL else { image = nil; return }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return }
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { image = Image(uiImage: ui) }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) { image = Image(nsImage: ns) }
        #endif
    }

    // MARK: Formatting

    private func readout(starts: [Int], total: Int) -> String {
        if let d = dragging { return "\(d.index == starts.count ? "End" : "Boundary") \(Self.clock(d.ms))" }
        if let s = scrubMs {
            let i = index(atMs: s, starts: starts)
            return "\(Self.clock(s)) · \(name(i))"
        }
        return "\(starts.count) tracks · \(Self.clock(total))"
    }

    static func clock(_ ms: Int) -> String {
        let t = max(0, ms) / 100
        let tenths = t % 10, s = (t / 10) % 60, m = t / 600
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    private static func step(_ ms: Int) -> String { ms >= 1000 ? "\(ms / 1000)s" : "0.\(ms / 100)s" }
}
#endif
