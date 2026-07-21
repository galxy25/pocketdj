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
struct DemuxInstrumentalView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentPackStore.self) private var packs

    let source: DemuxSource
    let chords: [DemuxChordSegment]
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
    /// The shared bar lattice (DrumPatternDetector.bars over the chords-only grid) — the drum
    /// pattern's bar chips, scrolled by the same follow that scrolls the score.
    @State private var bars: [DrumPatternDetector.Bar] = []
    @State private var selectedBar = 0
    @State private var currentSystem = 0
    @State private var notice: String?

    private var grid: DemuxInstrumental.Grid { (bpm, firstDownbeatMs, beatsMs) }
    private var rebuildKey: String {
        "\(chords.count)#\(bpm)#\(firstDownbeatMs)#\(beatsMs.count)#\(durationMs)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            extractBar
            if !bars.isEmpty { barChips }
            FollowScoreView(pages: pages, bpm: takeBpm, firstDownbeatMs: firstDownbeatMs,
                            player: player, follow: follow, currentSystem: currentSystem)
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
        let chords = chords, grid = grid
        let firstDownbeatMs = firstDownbeatMs, durationMs = durationMs
        let built = await Task.detached(priority: .userInitiated) {
            () -> (events: [StudioNoteEvent], bpm: Double,
                   pages: [ScorePage], bars: [DrumPatternDetector.Bar]) in
            let (ev, b) = DemuxInstrumental.events(chords: chords, grid: grid)
            let doc = ScoreQuantizer.quantize(events: ev, bpm: b, instrument: .piano)
            let pages = ScoreLayout.systems(score: doc, instrument: .piano)
            let bars = DrumPatternDetector.bars(downbeatsMs: [], bpm: b,
                                                firstDownbeatMs: firstDownbeatMs, durationMs: durationMs)
            return (ev, b, pages, bars)
        }.value
        guard !Task.isCancelled else { return }
        events = built.events
        takeBpm = built.bpm
        pages = built.pages
        bars = built.bars
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
                    Image(systemName: "pianokeys")
                    Text("Extract instrumental").font(.callout.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(events.isEmpty)
            .accessibilityIdentifier("demux-instrumental-extract")
            Text("A chord-comping instrumental (full triads) → Instruments ▸ Instrumentals, "
                 + "where you can edit it or play it with a different sound pack.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    /// Mint a `StudioTake` from the converted events (mirrors StudioInstrumentsView.saveLiveAsTake):
    /// a silent placeholder file so reconcile keeps the record, then relocate + render the real
    /// audio in the background so it's audible everywhere, not just on Replay.
    private func extract() {
        guard !events.isEmpty else { notice = "No chords to build an instrumental from."; return }
        guard let takesDir = try? StudioFolders.appRoot(.takes) else {
            notice = "Couldn’t save — the instrumentals folder isn’t reachable."
            return
        }
        let takeId = StudioFactory.newTakeId()
        let fileName = StudioFolders.fileName(.takes, id: takeId)
        let dur = max(500, events.map(\.offMs).max() ?? 500)
        writePlaceholderTakeAudio(to: takesDir.appendingPathComponent(fileName), durationMs: dur)
        studio.addTakeRelocating(StudioTake(id: takeId,
                                            name: "\(source.displayName) · instrumental",
                                            instrument: .piano,
                                            fileName: fileName, bpm: takeBpm, events: events,
                                            durationMs: dur,
                                            createdAt: Date().timeIntervalSince1970 * 1000))
        Task { await StudioTakeRenderer.ensureRendered(takeId: takeId, studio: studio, packs: packs) }
        notice = "Saved to Instruments ▸ Instrumentals — edit it or change its sound pack there."
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
/// thrash the score layout (off Observation, the drum-pattern highlight doctrine).
struct FollowScoreView: View {
    let pages: [ScorePage]
    let bpm: Double
    let firstDownbeatMs: Int
    let player: StemPlayer
    let follow: Bool
    let currentSystem: Int

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
        return ScorePageView(page: page)
            .aspectRatio(page.size.width / page.size.height, contentMode: .fit)
            // FIX 3: ONE playhead for the whole score — only the CURRENT system carries the moving
            // line, so a long score runs a single 10 Hz host-clock overlay instead of one per
            // system. `currentSystem` is the follow poll's output (playing OR paused scrub).
            .overlay { if i == currentSystem { playhead(system: i, page: page) } }
            .accessibilityIdentifier("score-system-\(i)")
    }

    /// A vertical playhead line inside the system the playhead is currently in. Host-clock driven
    /// (TimelineView, off Observation); x interpolates across the system's content width by the
    /// beat fraction, so it glides even between the coarse follow-scroll steps.
    private func playhead(system i: Int, page: ScorePage) -> some View {
        let m = ScoreLayout.Metrics.a4
        let mps = m.measuresPerSystem
        let step = ScoreQuantizer.sixteenthMs(bpm: bpm)
        let sysStartMs = Double(i * mps * 16) * step
        let sysDurMs = Double(mps * 16) * step
        return GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let scoreMs = max(0.0, player.currentTime * 1_000 - Double(firstDownbeatMs))
                let inSystem = scoreMs >= sysStartMs && scoreMs < sysStartMs + sysDurMs
                let scale = geo.size.width / page.size.width
                let contentLeft = (m.margin + m.clefZoneWidth) * scale
                let contentRight = (page.size.width - m.margin) * scale
                let frac = min(max((scoreMs - sysStartMs) / max(sysDurMs, 1), 0), 1)
                let x = contentLeft + (contentRight - contentLeft) * frac
                Rectangle().fill(Theme.accent2)
                    .frame(width: 2, height: geo.size.height)
                    .position(x: x, y: geo.size.height / 2)
                    .opacity(inSystem ? 0.9 : 0)
            }
        }
        .allowsHitTesting(false)
    }
}
