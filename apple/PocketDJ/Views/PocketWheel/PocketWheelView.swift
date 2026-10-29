#if !os(tvOS)
import SwiftUI

/// History ▸ Pockets ▸ Wheel (§2). The clock face: midnight at 12 o'clock, clockwise; Monday the
/// innermost ring, Sunday the outermost; today's ring 1.8× thicker (tap a weekday to move the
/// fisheye). Colour = the cell's dominant SOURCE collection (stable synced palette). Tap or scrub
/// to inspect a cell; the centre ▶ plays the pocket that best matches now.
struct PocketWheelScreen: View {
    @Environment(PocketMomentCache.self) private var cache
    @Environment(PocketPaletteStore.self) private var palette
    @Environment(ListeningLocationStore.self) private var location: ListeningLocationStore?
    @Environment(\.pocketWheelActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var modeFilter: PocketMode?
    @State private var focusedDow: Int = ProcessInfo.processInfo.environment["PDJ_WHEEL_FOCUS_DOW"].flatMap(Int.init)
        .map { min(7, max(1, $0)) } ?? PocketWheelScreen.todayDow()
    @State private var selected: PocketMomentKey?
    @State private var highlighted: String?
    @State private var memo = WheelLayoutMemo()

    static func todayDow(_ date: Date = Date()) -> Int {
        PocketClock.local(atMs: date.timeIntervalSince1970 * 1000,
                          tzOffsetMin: TimeZone.current.secondsFromGMT(for: date) / 60).dow
    }

    var body: some View {
        let snapshot = cache.snapshot
        let index = memo.index(for: snapshot, revision: cache.revision)
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            ScrollView {
                if snapshot.isEmpty {
                    emptyState
                } else if wide {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 12) {
                            modeChips
                            wheel(side: min(520, geo.size.width * 0.55), snapshot: snapshot, index: index)
                            weekdayRow
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            caption
                            PocketWheelLegend(snapshot: snapshot, highlighted: $highlighted)
                            card(index: index, snapshot: snapshot)
                        }
                        .frame(maxWidth: 380)
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 12) {
                        modeChips
                        wheel(side: min(geo.size.width - 32, 520), snapshot: snapshot, index: index)
                        weekdayRow
                        caption
                        PocketWheelLegend(snapshot: snapshot, highlighted: $highlighted)
                        card(index: index, snapshot: snapshot)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(Theme.bg)
        .accessibilityIdentifier("pocket-wheel-screen")
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.dashed").font(.system(size: 64)).foregroundStyle(Theme.fgDim)
            Text("Play for a week to paint your wheel.").font(.headline).foregroundStyle(Theme.fg)
            Text("Each ring is a day and each slice an hour. As you listen, PocketDJ colours them by the playlist or pocket the music came from.")
                .font(.subheadline).foregroundStyle(Theme.fgDim).multilineTextAlignment(.center)
            if let play = actions.playBest {
                Button { play() } label: { Label("Play something for now", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pocket-wheel-empty-play")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("pocket-wheel-empty")
    }

    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", symbol: "circle.grid.cross", on: modeFilter == nil, id: "all") { modeFilter = nil }
                ForEach(PocketMode.precedence, id: \.self) { m in
                    chip(label: m.label, symbol: m.symbol, on: modeFilter == m, id: m.rawValue) {
                        modeFilter = modeFilter == m ? nil : m
                    }
                }
            }
        }
    }

    private func chip(label: String, symbol: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Theme.accent.opacity(0.25) : Theme.bgRaised, in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.accent : Theme.border, lineWidth: 1))
                .foregroundStyle(on ? Theme.fg : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pocket-wheel-mode-\(id)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { d in
                Button {
                    if reduceMotion { focusedDow = d } else { withAnimation(.easeInOut(duration: 0.2)) { focusedDow = d } }
                } label: {
                    Text(PocketMomentKey.weekdayAbbrev[d - 1])
                        .font(.caption2.weight(d == focusedDow ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(d == focusedDow ? Theme.bgOverlay : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(d == focusedDow ? Theme.fg : Theme.fgDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Focus \(PocketMomentKey.weekdayNames[d - 1])")
                .accessibilityIdentifier("pocket-wheel-day-\(d)")
            }
        }
        .frame(maxWidth: 520)
    }

    private func wheel(side: CGFloat, snapshot: PocketWheelSnapshot, index: [PocketMomentKey: PocketMoment]) -> some View {
        let layout = memo.layout(radius: max(60, side / 2 - 22), focusedDow: focusedDow, filter: modeFilter,
                                 snapshot: snapshot, revision: cache.revision)
        return PocketWheelCanvas(layout: layout, index: index, palette: palette, paletteRevision: palette.revision,
                                 selected: $selected, highlighted: highlighted, names: snapshot.collectionNames,
                                 actions: actions)
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var caption: some View {
        if let best = actions.bestMatch {
            VStack(spacing: 2) {
                Text(best.caption).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                Text(best.detail).font(.caption).foregroundStyle(Theme.fgDim)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pocket-wheel-caption")
        }
    }

    @ViewBuilder private func card(index: [PocketMomentKey: PocketMoment], snapshot: PocketWheelSnapshot) -> some View {
        if let key = selected, let m = index[key] {
            PocketMomentCard(moment: m, names: snapshot.collectionNames, palette: palette, location: location,
                             actions: actions, onClose: { selected = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Text("Tap or drag across the wheel to see a pocket.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}

/// Memoises the layout + the moment index so the body never rebuilds them per frame.
@MainActor
final class WheelLayoutMemo {
    private var layoutKey: (CGFloat, Int, PocketMode?, Int)?
    private var cachedLayout: WheelLayout?
    private var indexRevision = -1
    private var cachedIndex: [PocketMomentKey: PocketMoment] = [:]

    func layout(radius: CGFloat, focusedDow: Int, filter: PocketMode?, snapshot: PocketWheelSnapshot,
                revision: Int) -> WheelLayout {
        if let k = layoutKey, let l = cachedLayout, k.0 == radius, k.1 == focusedDow, k.2 == filter, k.3 == revision {
            return l
        }
        let l = WheelLayout(radius: radius, focusedDow: focusedDow, modeFilter: filter, moments: snapshot.moments)
        layoutKey = (radius, focusedDow, filter, revision)
        cachedLayout = l
        return l
    }

    func index(for snapshot: PocketWheelSnapshot, revision: Int) -> [PocketMomentKey: PocketMoment] {
        if revision != indexRevision || (cachedIndex.isEmpty && !snapshot.isEmpty) {
            cachedIndex = snapshot.index()
            indexRevision = revision
        }
        return cachedIndex
    }
}

// MARK: - The canvas

/// The Canvas + its gestures (tap / scrub with a magnifier callout) + the centre ▶ + the
/// accessibility representation. Draws only from the precomputed `WheelLayout`.
struct PocketWheelCanvas: View {
    let layout: WheelLayout
    let index: [PocketMomentKey: PocketMoment]
    let palette: PocketPaletteStore
    let paletteRevision: Int
    @Binding var selected: PocketMomentKey?
    let highlighted: String?
    let names: [String: String]
    let actions: PocketWheelActions

    @State private var scrub: (point: CGPoint, key: PocketMomentKey?, dow: Int, hour: Int)?
    @State private var haptic = 0
    @State private var showAlternatives = false

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                TimelineView(.periodic(from: .now, by: 60)) { tl in
                    Canvas { ctx, _ in draw(&ctx, center: c, now: tl.date) }
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(center: c))
                .accessibilityRepresentation {
                    PocketWheelAccessibility(layout: layout, index: index, names: names,
                                             onOpen: { selected = $0 })
                }
                centerButton
                    .frame(width: layout.holeRadius * 1.7, height: layout.holeRadius * 1.7)
                    .position(c)
                if let s = scrub {
                    callout(for: s)
                        .position(x: min(max(90, s.point.x), geo.size.width - 90), y: max(24, s.point.y - 64))
                        .allowsHitTesting(false)
                }
            }
        }
        .modifier(WheelHaptic(trigger: haptic))
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, center c: CGPoint, now: Date) {
        // Ring tracks (empty cells read as the surface colour).
        for ring in layout.rings {
            ctx.fill(Self.sector(c, ring.inner, ring.outer, 0, 2 * .pi), with: .color(Theme.bgRaised))
        }
        // Cells.
        for cell in layout.cells {
            guard let ring = layout.ring(cell.dow) else { continue }
            for s in cell.slivers {
                guard let m = index[s.key] else { continue }
                let swatch = palette.swatch(for: m.dominantCollectionId)
                let dimmed = highlighted != nil && m.dominantCollectionId != highlighted
                let fill = PocketWheelPaint.fill(moment: m, swatch: swatch, dimmed: dimmed)
                let path = Self.sector(c, ring.inner, ring.outer, s.start, s.end)
                ctx.fill(path, with: .color(fill))
                if swatch == .mixed || swatch.isHatched {
                    // Fine stripe: a radial hairline through the sliver's middle.
                    var line = Path()
                    let mid = (s.start + s.end) / 2
                    line.move(to: WheelLayout.point(radius: ring.inner + 1, angle: mid, center: c))
                    line.addLine(to: WheelLayout.point(radius: ring.outer - 1, angle: mid, center: c))
                    ctx.stroke(line, with: .color(Theme.bg.opacity(0.6)), lineWidth: 1)
                }
                if ring.focused, ring.thickness >= 20, s.end - s.start >= WheelLayout.angle(forHour: 0.55),
                   layout.modeFilter == nil {
                    let p = WheelLayout.point(radius: ring.mid, angle: (s.start + s.end) / 2, center: c)
                    ctx.draw(Text(Image(systemName: s.key.mode.symbol)).font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.bg.opacity(0.85)), at: p)
                }
            }
        }
        // Hairline separators between hours on every ring (keeps the clock legible).
        for h in 0..<24 {
            var p = Path()
            let a = WheelLayout.angle(forHour: Double(h))
            p.move(to: WheelLayout.point(radius: layout.holeRadius, angle: a, center: c))
            p.addLine(to: WheelLayout.point(radius: layout.radius, angle: a, center: c))
            ctx.stroke(p, with: .color(Theme.bg), lineWidth: h % 6 == 0 ? 1.5 : 0.75)
        }
        // Selection outline.
        if let key = selected, let ring = layout.ring(key.dow),
           let s = layout.cell(dow: key.dow, hour: key.hour)?.slivers.first(where: { $0.key == key }) {
            ctx.stroke(Self.sector(c, ring.inner, ring.outer, s.start, s.end), with: .color(Theme.fg), lineWidth: 2)
        }
        // Hour labels (0/6/12/18) outside the rim, dots elsewhere.
        for h in 0..<24 {
            let a = WheelLayout.angle(forHour: Double(h))
            let p = WheelLayout.point(radius: layout.radius + 11, angle: a, center: c)
            if h % 6 == 0 {
                ctx.draw(Text(Self.hourTick(h)).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.fgDim), at: p)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)), with: .color(Theme.fgDim.opacity(0.6)))
            }
        }
        // Weekday letters at each ring's 12 o'clock end.
        for ring in layout.rings {
            let p = WheelLayout.point(radius: ring.mid, angle: -0.06, center: c)
            ctx.draw(Text(PocketMomentKey.weekdayShort[ring.dow - 1])
                        .font(.system(size: ring.focused ? 10 : 8, weight: ring.focused ? .bold : .regular))
                        .foregroundColor(ring.focused ? Theme.fg : Theme.fgDim), at: p, anchor: .trailing)
        }
        // The "now" needle.
        let nowLocal = PocketClock.local(atMs: now.timeIntervalSince1970 * 1000,
                                         tzOffsetMin: TimeZone.current.secondsFromGMT(for: now) / 60)
        let a = WheelLayout.angle(forHour: nowLocal.fractionalHour)
        var needle = Path()
        needle.move(to: WheelLayout.point(radius: layout.holeRadius, angle: a, center: c))
        needle.addLine(to: WheelLayout.point(radius: layout.radius + 4, angle: a, center: c))
        ctx.stroke(needle, with: .color(Theme.accent2), lineWidth: 1.5)
    }

    static func hourTick(_ h: Int) -> String {
        switch h { case 0: return "12a"; case 6: return "6a"; case 12: return "12p"; default: return "6p" }
    }

    /// An annular sector as a polygon (arcs sampled every ~3°) — angle convention is the layout's.
    static func sector(_ c: CGPoint, _ inner: CGFloat, _ outer: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        let steps = max(2, Int(ceil((a1 - a0) / (3 * .pi / 180))))
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            let pt = WheelLayout.point(radius: outer, angle: a, center: c)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            p.addLine(to: WheelLayout.point(radius: inner, angle: a, center: c))
        }
        p.closeSubpath()
        return p
    }

    // MARK: Gestures

    private func scrubGesture(center c: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                switch layout.hit(v.location, center: c) {
                case .cell(let dow, let hour, let key):
                    if scrub?.key != key || scrub?.hour != hour || scrub?.dow != dow { haptic &+= 1 }
                    scrub = (v.location, key, dow, hour)
                default:
                    scrub = nil
                }
            }
            .onEnded { v in
                defer { scrub = nil }
                if case .cell(_, _, let key?) = layout.hit(v.location, center: c) {
                    selected = key
                    haptic &+= 1
                }
            }
    }

    private func callout(for s: (point: CGPoint, key: PocketMomentKey?, dow: Int, hour: Int)) -> some View {
        let title = s.key?.shortLabel
            ?? "\(PocketMomentKey.weekdayAbbrev[s.dow - 1]) \(PocketMomentKey.hourLabel(s.hour))"
        let m = s.key.flatMap { index[$0] }
        let sub = m.map { m in
            (m.dominantCollectionId.flatMap { names[$0] } ?? "Mixed") + " · \(m.directPlays) plays"
        } ?? "Nothing yet"
        return VStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
            Text(sub).font(.caption2).foregroundStyle(Theme.fgDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .accessibilityHidden(true)
    }

    // MARK: Centre ▶

    @ViewBuilder private var centerButton: some View {
        let best = actions.bestMatch
        let ringColor = palette.swatch(for: best?.collectionId).color(dark: true)
        Button {
            if actions.runProgress != nil, let pause = actions.pauseRun { pause() } else { actions.playBest?() }
        } label: {
            ZStack {
                Circle().fill(Theme.bgOverlay)
                Circle().stroke(best == nil ? Theme.border : ringColor, lineWidth: 4)
                if let run = actions.runProgress {
                    Circle()
                        .trim(from: 0, to: CGFloat(run.done) / CGFloat(max(1, run.total)))
                        .stroke(Theme.accent2, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(5)
                    VStack(spacing: 0) {
                        Image(systemName: "pause.fill").font(.system(size: 22, weight: .bold))
                        Text("\(run.done)/\(run.total)").font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Theme.fg)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 28, weight: .bold))
                        .foregroundStyle(best == nil && actions.playBest == nil ? Theme.fgDim : Theme.fg)
                        .offset(x: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(actions.playBest == nil && actions.runProgress == nil)
        .accessibilityLabel(centerA11yLabel)
        .accessibilityIdentifier("pocket-wheel-play")
        .contextMenu {
            if !actions.alternatives.isEmpty, let alt = actions.playAlternative {
                Section("Not this?") {
                    ForEach(actions.alternatives) { a in
                        Button { alt(a) } label: { Text("\(a.caption) · \(a.detail)") }
                    }
                }
            }
        }
    }

    private var centerA11yLabel: String {
        if let run = actions.runProgress { return "Pause the pocket, \(run.done) of \(run.total) songs played" }
        guard let b = actions.bestMatch else { return "Play the pocket for now" }
        return "Play the pocket for now: \(b.detail), \(b.caption)"
    }
}

/// Selection haptic on scrub / select (no haptics API on visionOS before 26).
private struct WheelHaptic: ViewModifier {
    let trigger: Int
    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        content.sensoryFeedback(.selection, trigger: trigger)
        #endif
    }
}

/// Colour encoding (§2.4): opacity 0.25 + 0.75·confidence; one-offs at 50 % saturation;
/// highlight-dimming for the legend.
enum PocketWheelPaint {
    static func fill(moment m: PocketMoment, swatch: PocketSwatch, dimmed: Bool) -> Color {
        var (r, g, b) = swatch.rgb(dark: true)
        if !m.isRecurring {
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = (r + l) / 2; g = (g + l) / 2; b = (b + l) / 2
        }
        let opacity = (0.25 + 0.75 * m.confidence) * (dimmed ? 0.18 : 1)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
#endif
