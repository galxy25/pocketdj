import SwiftUI

/// The Demuxer's scrubbable, time-synced timeline: a zoomable horizontal strip with the
/// WAVEFORM lane over the CHORD lane, a playhead that tracks the (non-observed, host-clock)
/// player position, drag-anywhere scrubbing, and tap-a-chord detail. Auto-follows the playhead
/// while playing (a drag or manual scroll disables follow; the ⌖ button re-arms it).
///
/// Rendering budget: the strip redraws inside a `TimelineView` (the StemAuditionPanel scrubber
/// pattern) so 4×/s playhead ticks never invalidate the surrounding controls; the lanes
/// themselves depend only on (peaks, chords, zoom) and stay cached.
struct DemuxTimelineView: View {
    let durationMs: Int
    let peaks: [Float]
    let chords: [DemuxChordSegment]
    /// Sampled for the playhead (currentTime is deliberately non-Observable).
    let player: StemPlayer
    /// Song-relative seek (the player owns any file offset mapping upstream).
    var onSeek: (Int) -> Void
    var onChordTap: (DemuxChordSegment) -> Void

    /// Zoom: points per second. The stepper walks the ladder; "fit" derives from width.
    @State private var pxPerSec: CGFloat = 10
    @State private var follow = true
    /// Mid-drag scrub target (ms) — the playhead renders here while the finger is down.
    @GestureState private var scrubMs: Int?

    private static let zoomLadder: [CGFloat] = [4, 10, 25, 60]
    private static let waveHeight: CGFloat = 44
    private static let chordHeight: CGFloat = 34

    /// Live strip width — feeds the fit-to-width zoom floor (zoom-out must always be
    /// able to show the WHOLE track, portrait included).
    @State private var containerW: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                strip(containerWidth: geo.size.width)
                    .onAppear { containerW = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in containerW = w }
            }
            .frame(height: Self.waveHeight + Self.chordHeight + 18)
            controls
        }
    }

    /// Points-per-second at which the whole track exactly fits the strip — the true
    /// zoom-out floor. Falls back to the ladder floor before layout has a width.
    private var fitPx: CGFloat {
        let seconds = max(Double(durationMs) / 1_000, 0.01)
        guard containerW > 0 else { return Self.zoomLadder.first! }
        return containerW / CGFloat(seconds)
    }

    // MARK: - The strip

    private func strip(containerWidth: CGFloat) -> some View {
        let seconds = max(Double(durationMs) / 1_000, 0.01)
        let width = max(containerWidth, CGFloat(seconds) * pxPerSec)
        let effectivePx = width / CGFloat(seconds)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let nowMs = scrubMs ?? Int(player.currentTime * 1_000)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 2) {
                            waveformLane(width: width)
                            chordLane(width: width, pxPerSec: effectivePx)
                        }
                        // Playhead.
                        Rectangle()
                            .fill(Theme.accent2)
                            .frame(width: 2, height: Self.waveHeight + Self.chordHeight + 2)
                            .offset(x: CGFloat(nowMs) / 1_000 * effectivePx - 1)
                        // Invisible per-second anchors for the auto-follow scroll.
                        followAnchors(seconds: seconds, pxPerSec: effectivePx)
                    }
                    .frame(width: width, alignment: .topLeading)
                }
                .contentShape(Rectangle())
                // Drag anywhere = scrub (position preview while down, seek on release).
                .gesture(scrubGesture(pxPerSec: effectivePx))
            }
            .accessibilityIdentifier("demux-timeline")
            // Zoom anchors at the PLAYHEAD (Levi): changing zoom re-centers the current
            // second, so zoom-in dives into the part you're at instead of drifting off.
            .onChange(of: pxPerSec) { _, _ in
                proxy.scrollTo("demux-sec-\(Int(player.currentTime))", anchor: .center)
            }
            .task(id: followTaskKey) {
                // Auto-follow: center the playhead's current second while playing. A polling
                // task (not onChange) because currentTime is deliberately non-Observable.
                while !Task.isCancelled {
                    if follow, player.isPlaying {
                        let sec = Int(player.currentTime)
                        withAnimation(.linear(duration: 0.3)) {
                            proxy.scrollTo("demux-sec-\(sec)", anchor: .center)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    /// Restart the follow task when zoom changes (anchor spacing moved).
    private var followTaskKey: String { "\(pxPerSec)-\(follow)" }

    private func followAnchors(seconds: Double, pxPerSec: CGFloat) -> some View {
        ForEach(0...Int(seconds), id: \.self) { sec in
            Color.clear
                .frame(width: 1, height: 1)
                .offset(x: CGFloat(sec) * pxPerSec)
                .id("demux-sec-\(sec)")
        }
    }

    private func scrubGesture(pxPerSec: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($scrubMs) { value, state, _ in
                state = clampMs(value.location.x, pxPerSec: pxPerSec)
            }
            .onEnded { value in
                follow = false
                onSeek(clampMs(value.location.x, pxPerSec: pxPerSec))
            }
    }

    private func clampMs(_ x: CGFloat, pxPerSec: CGFloat) -> Int {
        min(max(0, Int(x / pxPerSec * 1_000)), durationMs)
    }

    // MARK: - Lanes

    private func waveformLane(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            guard !peaks.isEmpty else {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: mid))
                p.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(p, with: .color(Theme.fgDim.opacity(0.5)), lineWidth: 1)
                return
            }
            let barW = size.width / CGFloat(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let h = max(1.5, CGFloat(min(max(peak, 0), 1)) * size.height)
                let r = CGRect(x: CGFloat(i) * barW, y: mid - h / 2,
                               width: max(barW - 1, 0.8), height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(Theme.accent.opacity(0.55)))
            }
        }
        .frame(width: width, height: Self.waveHeight)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func chordLane(width: CGFloat, pxPerSec: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.bgRaised)
            ForEach(chords) { seg in
                chordBlock(seg, pxPerSec: pxPerSec)
            }
        }
        .frame(width: width, height: Self.chordHeight, alignment: .topLeading)
    }

    private func chordBlock(_ seg: DemuxChordSegment, pxPerSec: CGFloat) -> some View {
        let x = CGFloat(seg.startMs) / 1_000 * pxPerSec
        let w = max(CGFloat(seg.endMs - seg.startMs) / 1_000 * pxPerSec - 1, 2)
        return Button { onChordTap(seg) } label: {
            Text(w > 16 ? seg.name : "")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fg)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: w, height: Self.chordHeight - 6)
                .background(Self.chordColor(seg), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: 3)
        .accessibilityIdentifier("demux-chord-\(seg.startMs)")
        .accessibilityLabel("\(seg.name), \(StemAuditionPanel.clock(Double(seg.startMs) / 1_000))")
    }

    /// One hue per root pitch class around the wheel (minor = dimmer) — the chord lane reads
    /// harmonically at a glance, matching the star-map "color = tonality" instinct.
    static func chordColor(_ seg: DemuxChordSegment) -> Color {
        Color(hue: Double(seg.rootPC) / 12, saturation: 0.55,
              brightness: seg.minor ? 0.42 : 0.62)
    }

    // MARK: - Controls (zoom + follow)

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Zoom").font(.caption2).foregroundStyle(Theme.fgDim)
            Button { stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .disabled(pxPerSec <= fitPx + 0.01)
                .accessibilityIdentifier("demux-zoom-out")
            Button { stepZoom(+1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .disabled(pxPerSec >= Self.zoomLadder.last!)
                .accessibilityIdentifier("demux-zoom-in")
            Spacer()
            Button {
                follow.toggle()
            } label: {
                Image(systemName: follow ? "scope" : "scope")
                    .symbolVariant(follow ? .fill : .none)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(follow ? Theme.accent : Theme.fgDim)
            .help("Follow the playhead")
            .accessibilityIdentifier("demux-follow")
        }
        .padding(.horizontal, 2)
    }

    /// Walk the ladder — and BELOW its floor, land on fit-to-width, so zoom-out always
    /// reaches "the whole track on screen" even for a long song in portrait. Zooming
    /// back in from the fit stop returns to the ladder.
    private func stepZoom(_ dir: Int) {
        let ladder = Self.zoomLadder
        if dir < 0 {
            if let lower = ladder.last(where: { $0 < pxPerSec }), lower > fitPx {
                pxPerSec = lower
            } else {
                pxPerSec = fitPx
            }
        } else {
            pxPerSec = ladder.first(where: { $0 > pxPerSec }) ?? ladder.last!
        }
    }
}
