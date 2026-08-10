import SwiftUI
import AVFoundation

/// Demuxer ▸ INSTRUMENTAL (chord-comping) — parallel to "Extract drum pattern" (F8 slice A).
///
/// Builds a beat-quantized chord-comping instrumental from the ALREADY-DETECTED chord blocks
/// (`DemuxInstrumental.events` — pure, never re-analyzes), shows it as a SYNCED musical score that
/// scroll-follows the playhead, and hands it to the Instruments tab as a plain, editable/playable
/// `StudioTake` (default pack: Piano — changeable there). One shared `follow` + the shared
/// original-audio `StemPlayer` (the master clock — NOT instrument replay, which would drift) scroll
/// BOTH the drum-pattern bar lattice AND the score's current system, including a scrub WHILE PAUSED
/// (StemPlayer.currentTime returns pausedAt while paused and seek() updates it, so the follow poll
/// has no isPlaying gate). Works off CHORDS ALONE — no stems required.
/// What the panel builds the instrumental from: the chord timeline (comping — full triads) or the
/// monophonic pitch-tracked melody notes (a single voice). Both flow through the SAME synced score
/// + hand-off; only the events converter and the minted take's mode differ.
enum DemuxInstrumentalContent: Equatable {
    case comping(chords: [DemuxChordSegment])
    case melody(notes: [DemuxMelodyNote])

    var isMelody: Bool { if case .melody = self { return true }; return false }
    var mode: String { isMelody ? "melody" : "comping" }
    /// Cheap identity for the rebuild key (contents change ⇒ rebuild).
    var elementCount: Int {
        switch self {
        case .comping(let c): return c.count
        case .melody(let n):  return n.count
        }
    }
}

struct DemuxInstrumentalView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentPackStore.self) private var packs

    let source: DemuxSource
    let content: DemuxInstrumentalContent
    /// The chords-only grid (measured beat lattice when the song has a sidecar, else a constant
    /// grid from `bpm`) — resolved by the caller off the render path.
    let bpm: Double
    let firstDownbeatMs: Int
    let beatsMs: [Int]
    let durationMs: Int
    /// The demuxer's shared original-audio player — the master clock both views follow.
    let player: StemPlayer
    /// The ONE shared demux Follow (lifted to StudioDemuxView) — the SAME toggle that governs the
    /// drum-pattern lane-grid and the timeline, so enabling Follow scrolls the score's system, the
    /// drum grid's bar, AND the strip all to the same playhead time (paused scrub included).
    @Binding var follow: Bool
    /// Song-relative seek (bar-chip taps).
    var onSeek: (Int) -> Void = { _ in }

    @State private var events: [StudioNoteEvent] = []
    @State private var takeBpm: Double = 120
    @State private var pages: [ScorePage] = []
    /// The score's playback geometry, built with the pages (off the main actor) and never on a
    /// playhead tick: every note head's page-space position, grouped by page, plus the onset
    /// timeline the cursor maps against.
    @State private var marksByPage: [Int: [ScoreLayout.PlayedMark]] = [:]
    @State private var slots: [ScorePlayhead.Slot] = []
    /// The shared bar lattice (DrumPatternDetector.bars over the chords-only grid) — the drum
    /// pattern's bar chips, scrolled by the same follow that scrolls the score.
    @State private var bars: [DrumPatternDetector.Bar] = []
    @State private var selectedBar = 0
    @State private var currentSystem = 0
    @State private var notice: String?

    private var grid: DemuxInstrumental.Grid { (bpm, firstDownbeatMs, beatsMs) }
    private var rebuildKey: String {
        "\(content.mode)#\(content.elementCount)#\(bpm)#\(firstDownbeatMs)#\(beatsMs.count)#\(durationMs)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            extractBar
            if !bars.isEmpty { barChips }
            FollowScoreView(pages: pages, bpm: takeBpm, firstDownbeatMs: firstDownbeatMs,
                            player: player, follow: follow, currentSystem: currentSystem,
                            marksByPage: marksByPage, slots: slots, onSeek: onSeek,
                            onTapSystem: { currentSystem = $0 })
        }
        .task(id: rebuildKey) { await rebuild() }
        // ONE shared follow poll: read the non-Observable player clock and advance BOTH the bar
        // chips and the score system — ALWAYS (playing or a paused scrub), no isPlaying gate, so a
        // scrub while paused scrolls both (the bar-granularity writes are cheap; the score's fast
        // playhead line lives in a TimelineView overlay off Observation).
        .task(id: follow) {
            guard follow else { return }
            while !Task.isCancelled {
                let ms = Int(player.currentTime * 1_000)
                if !bars.isEmpty, let bi = DrumPatternDetector.barIndex(forMs: ms, bars: bars),
                   bi != selectedBar {
                    selectedBar = bi
                }
                let sys = FollowScoreView.systemIndex(playheadMs: ms, firstDownbeatMs: firstDownbeatMs,
                                                      bpm: takeBpm, systemCount: pages.count)
                if sys != currentSystem { currentSystem = sys }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Build the events + score pages + bar lattice OFF the main actor (all pure `nonisolated`
    /// statics) so a long/dense score's quantize + layout never blocks the UI — the drum-bars
    /// Task.detached discipline (StudioDemuxView.resolveDrumBars). Results assign back on the
    /// MainActor; a stale run (the key changed while we computed) drops its result.
    private func rebuild() async {
        let content = content, grid = grid
        let firstDownbeatMs = firstDownbeatMs, durationMs = durationMs
        let built = await Task.detached(priority: .userInitiated) {
            () -> (events: [StudioNoteEvent], bpm: Double,
                   pages: [ScorePage], bars: [DrumPatternDetector.Bar],
                   marks: [Int: [ScoreLayout.PlayedMark]], slots: [ScorePlayhead.Slot]) in
            let (ev, b): ([StudioNoteEvent], Double)
            switch content {
            case .comping(let chords): (ev, b) = DemuxInstrumental.events(chords: chords, grid: grid)
            case .melody(let notes):   (ev, b) = DemuxInstrumental.melodyEvents(notes: notes, grid: grid)
            }
            let doc = ScoreQuantizer.quantize(events: ev, bpm: b, instrument: .piano)
            let pages = ScoreLayout.systems(score: doc, instrument: .piano)
            let bars = DrumPatternDetector.bars(downbeatsMs: [], bpm: b,
                                                firstDownbeatMs: firstDownbeatMs, durationMs: durationMs)
            // Playback geometry rides along with the layout — same inputs, same off-main pass, so
            // the follow overlay never derives it in a body (or, worse, per 10 Hz tick).
            let marks = Dictionary(grouping: ScoreLayout.playedMarks(events: ev, bpm: b,
                                                                     plan: doc.clefPlan, pages: pages),
                                   by: \.page)
            return (ev, b, pages, bars, marks, ScorePlayhead.timeline(events: ev, bpm: b))
        }.value
        guard !Task.isCancelled else { return }
        events = built.events
        takeBpm = built.bpm
        pages = built.pages
        bars = built.bars
        marksByPage = built.marks
        slots = built.slots
    }

    // MARK: Header (shared follow toggle)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button { follow.toggle() } label: {
                Image(systemName: follow ? "location.fill" : "location")
                    .font(.caption)
                    .frame(width: 28, height: 26)
                    .background(follow ? Theme.accent.opacity(0.22) : Theme.bgOverlay,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(follow ? Theme.accent : Theme.border, lineWidth: 1))
                    .foregroundStyle(follow ? Theme.accent : Theme.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(follow ? "Following playback" : "Follow playback")
            .accessibilityIdentifier("demux-sync-follow")
            .help("Follow playback — the bars and the score both track the playhead (even while paused)")
            Text("Synced playback — bars + score follow the playhead")
                .font(.caption2).foregroundStyle(Theme.fgDim)
            Spacer(minLength: 0)
        }
    }

    // MARK: Extract (chords → StudioTake, routed to the Instruments tab)

    private var extractBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Text(notice).font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-instrumental-notice")
            }
            Button { extract() } label: {
                HStack(spacing: 8) {
                    Image(systemName: content.isMelody ? "waveform.path" : "pianokeys")
                    Text(content.isMelody ? "Extract melody" : "Extract instrumental")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(events.isEmpty)
            .accessibilityIdentifier(content.isMelody ? "demux-melody-extract" : "demux-instrumental-extract")
            Text(content.isMelody
                 ? "A single-voice melody line → Instruments ▸ Instrumentals, where you can edit it, "
                   + "play it with a different sound pack, or switch it to chord comping."
                 : "A chord-comping instrumental (full triads) → Instruments ▸ Instrumentals, "
                   + "where you can edit it or play it with a different sound pack.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    /// Mint a `StudioTake` from the converted events (mirrors StudioInstrumentsView.saveLiveAsTake):
    /// a silent placeholder file so reconcile keeps the record, then relocate + render the real
    /// audio in the background so it's audible everywhere, not just on Replay.
    private func extract() {
        guard !events.isEmpty else {
            notice = content.isMelody ? "No melody to build from." : "No chords to build an instrumental from."
            return
        }
        guard let takesDir = try? StudioFolders.appRoot(.takes) else {
            notice = "Couldn’t save — the instrumentals folder isn’t reachable."
            return
        }
        let takeId = StudioFactory.newTakeId()
        let fileName = StudioFolders.fileName(.takes, id: takeId)
        let dur = max(500, events.map(\.offMs).max() ?? 500)
        writePlaceholderTakeAudio(to: takesDir.appendingPathComponent(fileName), durationMs: dur)
        // Record the Demux provenance so the take's context-menu switch (Instruments ▸
        // Instrumentals) can re-extract the OTHER mode from the same source.
        studio.addTakeRelocating(StudioTake(id: takeId,
                                            name: "\(source.displayName) · \(content.isMelody ? "melody" : "instrumental")",
                                            instrument: .piano,
                                            fileName: fileName, bpm: takeBpm, events: events,
                                            durationMs: dur,
                                            createdAt: Date().timeIntervalSince1970 * 1000,
                                            demuxSourceKey: source.key, demuxMode: content.mode))
        Task { await StudioTakeRenderer.ensureRendered(takeId: takeId, studio: studio, packs: packs) }
        notice = "Saved to Instruments ▸ Instrumentals — edit it, change its sound pack, or switch modes there."
    }

    /// A silent AAC placeholder so the take file exists (reconcile keeps it; replay uses events) —
    /// the StudioInstrumentsView.saveLiveAsTake idiom.
    private func writePlaceholderTakeAudio(to url: URL, durationMs: Int) {
        let sr = 44_100.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                        AVSampleRateKey: sr, AVNumberOfChannelsKey: 1]
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(sr * Double(durationMs) / 1000))
        else { return }
        buf.frameLength = buf.frameCapacity
        try? file.write(from: buf)
    }

    // MARK: Bar chips (the shared drum-pattern lattice — scrolled by follow, tap to seek)

    private var barChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(bars) { bar in
                        Button {
                            selectedBar = bar.index
                            onSeek(bar.startMs)
                        } label: {
                            Text("\(bar.index + 1)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 26)
                                .padding(.vertical, 5)
                                .background(bar.index == selectedBar ? Theme.accent.opacity(0.25)
                                            : Theme.bgOverlay,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(bar.index == selectedBar ? Theme.accent : Theme.border,
                                                  lineWidth: 1))
                                .foregroundStyle(Theme.fg)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Bar \(bar.index + 1)")
                        .accessibilityIdentifier("demux-instrumental-bar-\(bar.index)")
                        .id(bar.index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 34)
            .accessibilityIdentifier("demux-instrumental-bars")
            .onChange(of: selectedBar) { _, bar in
                withAnimation { proxy.scrollTo(bar, anchor: .center) }
            }
        }
    }
}

// MARK: - Follow-scroll score

/// The instrumental's musical SCORE, one SYSTEM per row (real layout cells via
/// `ScoreLayout.systems`), scroll-following the playhead. The current system is scrolled to on a
/// `ScrollViewReader` by its `.id` — NEVER an `.offset`-anchored target, whose layout frame
/// collapses to the origin so scrollTo jumps to 0 (the documented demux scroll bug). The moving
/// playhead line rides a `TimelineView(.periodic)` host-clock overlay so its ~10 Hz ticks never
/// thrash the score layout (off Observation, the drum-pattern highlight doctrine) — the SAME
/// `ScorePlaybackCanvas` the saved instrumental's score uses, so the cursor, the played-behind
/// notes, and the current/last-played note look and behave identically in both places.
struct FollowScoreView: View {
    let pages: [ScorePage]
    let bpm: Double
    let firstDownbeatMs: Int
    let player: StemPlayer
    let follow: Bool
    let currentSystem: Int
    /// Precomputed playback geometry (built with `pages` in `rebuild`): note-head positions per
    /// page + the onset timeline. Empty ⇒ the score renders with no playback paint.
    var marksByPage: [Int: [ScoreLayout.PlayedMark]] = [:]
    var slots: [ScorePlayhead.Slot] = []
    /// SONG-relative seek — the same callback the bar chips use, so tapping the score and tapping
    /// a bar mean the same thing. Default no-op keeps a read-only follower read-only.
    var onSeek: (Int) -> Void = { _ in }
    /// A system was TAPPED (index): the host moves `currentSystem` there so the single playback
    /// overlay follows the tap. Matters with Follow OFF, where the follow poll is parked and the
    /// system the user has hand-scrolled to is exactly the one that isn't painted — without this a
    /// tap out there would move the song with no visible cursor.
    var onTapSystem: (Int) -> Void = { _ in }

    /// Map a playhead time (original-audio clock, ms) to a score system index. Re-anchors to
    /// `firstDownbeatMs` (0 ms = beat 1, the score's own anchor), then measure → system. Pure +
    /// testable.
    static func systemIndex(playheadMs: Int, firstDownbeatMs: Int, bpm: Double,
                            systemCount: Int) -> Int {
        guard systemCount > 0 else { return 0 }
        let step = ScoreQuantizer.sixteenthMs(bpm: bpm)
        let scoreMs = max(0.0, Double(playheadMs - firstDownbeatMs))
        let measure = Int(scoreMs / step) / 16
        return min(systemCount - 1, max(0, measure / ScoreLayout.Metrics.a4.measuresPerSystem))
    }

    var body: some View {
        if pages.isEmpty {
            Text("No chords to build an instrumental from.")
                .font(.caption).foregroundStyle(Theme.fgDim)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    // LazyVStack (FIX 3): off-screen systems aren't drawn — a long score no longer
                    // realizes dozens of ScorePageViews (and, with the single playhead below, no
                    // longer runs one 10 Hz clock per system).
                    LazyVStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { i in
                            systemRow(i).id("score-system-\(i)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 300)
                // FIX 2 (gesture trap): while Follow is on, the APP drives the scroll — so turn
                // OFF this inner scroll's user drag, and a drag over the score falls through to the
                // outer page scroll instead of being trapped here. Programmatic scrollTo (the
                // follow below) still works. Follow off ⇒ hand-scrolling the score returns.
                .scrollDisabled(follow)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("demux-instrumental-score")
                // Follow: scroll the current system to center whenever it advances (a playback tick
                // OR a paused scrub — both flow through `currentSystem`). onChange only fires on a
                // real change, so a paused hold never re-scrolls.
                .onChange(of: currentSystem) { _, sys in
                    guard follow else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("score-system-\(sys)", anchor: .center)
                    }
                }
            }
        }
    }

    private func systemRow(_ i: Int) -> some View {
        let page = pages[i]
        // FIX 3: ONE clocked overlay for the whole score — only the CURRENT system carries the
        // playback paint, so a long score runs a single 10 Hz host clock instead of one per
        // system. `currentSystem` is the follow poll's output (playing OR paused scrub).
        //
        // The SEEK is wired on every system regardless (it costs nothing — no clock, no timer):
        // with Follow off, the system the user has hand-scrolled to is precisely the one that is
        // NOT painted, and that is exactly when they tap it to jump there.
        return ScorePageView(page: page, playback: i == currentSystem ? layer(for: i) : nil,
                             seekTarget: seekTarget(for: i))
            .aspectRatio(page.size.width / page.size.height, contentMode: .fit)
            .accessibilityIdentifier("score-system-\(i)")
    }

    /// Tap the score → seek the SONG: score clock (0 ms = beat 1) back through the same
    /// `firstDownbeatMs` anchor the playhead uses, into `onSeek` — the very callback the bar chips
    /// call, so tapping the sheet and tapping a bar mean the same thing, just at note resolution.
    /// The tapped system also becomes the painted one, so the cursor appears where the finger went.
    private func seekTarget(for i: Int) -> ScorePageView.SeekTarget {
        let firstDownbeatMs = firstDownbeatMs, onSeek = onSeek, onTapSystem = onTapSystem
        return ScorePageView.SeekTarget(bpm: bpm) { scoreMs in
            onTapSystem(i)
            onSeek(max(0, scoreMs + firstDownbeatMs))
        }
    }

    /// The current system's playback layer: cursor + played-behind + current/last-played note,
    /// drawn by the SHARED `ScorePlaybackCanvas` the saved instrumental's score uses. The x now
    /// comes from `ScoreLayout.playhead` — the note heads' own `xPosition` — instead of a
    /// system-wide linear interpolation, which drifted off the heads by the per-measure padding.
    private func layer(for i: Int) -> ScorePlaybackLayer {
        let firstDownbeatMs = firstDownbeatMs
        return ScorePlaybackLayer(
            pageIndex: i, pages: pages, marks: marksByPage[i] ?? [], slots: slots, bpm: bpm,
            // PAINT only — the tap is wired per row by `seekTarget` (see `systemRow`), because a
            // system that isn't painted must still be tappable.
            clock: ScorePlaybackClock(
                positionMs: {
                    // Song clock → score clock (0 ms = beat 1). `currentTime` returns
                    // pausedAt while paused, so a paused scrub follows too. Clamped
                    // before Int(): a NaN/absurd clock read must degrade, never trap.
                    let ms = player.currentTime * 1_000
                    guard ms.isFinite else { return 0 }
                    return Int(min(max(ms, 0), 86_400_000)) - firstDownbeatMs
                }))
    }
}
