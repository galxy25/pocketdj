import SwiftUI

/// The four score-editor interaction modes. ENTER places a new note on every tap (the pen sets
/// length / accidental); SELECT snaps each tap to the CLOSEST note (or a whole bar) to build a
/// selection; MOVE nudges or duplicates it; EDIT bulk-applies length / accidental / delete.
enum ScoreEditMode: String, CaseIterable { case enter, select, move, edit }
/// In SELECT mode, a tap picks a single note or every note in the tapped bar.
enum ScoreSelectGranularity { case note, bar }

/// The reusable editable-score surface (spec §7). Renders an event stream as notation and — when
/// `editing` — offers three explicit modes (I2): SELECT (tap notes or bars; tap empty staff to
/// place a note), MOVE (nudge ±semitone / ±step, or Duplicate a bar later), and EDIT (set length /
/// accidental, or Delete). Every edit commits through `onEdit` and pushes an Undo snapshot. Shared
/// by the saved-take Score screen and the Instruments LIVE staff, so both edit identically.
struct ScoreEditorView: View {
    var events: [StudioNoteEvent]
    var bpm: Double
    var instrument: InstrumentKey
    var title: String
    var editing: Bool
    /// Commit an edited event stream (take → setTakeEvents; live → setLiveEvents).
    var onEdit: ([StudioNoteEvent]) -> Void

    /// The "pen" for newly placed notes (and the last-touched note's values); EDIT chips also set it.
    @State private var editLength: NoteDuration = .quarter
    @State private var editAccidental: Accidental = .natural
    @State private var mode: ScoreEditMode = .enter
    @State private var granularity: ScoreSelectGranularity = .note
    /// The selection, keyed by VALUE (StudioNoteEvent is Hashable) and resolved to indices each
    /// render. Value-based on purpose: the live-staff host re-sorts events on commit, so an
    /// index-based selection would move/edit the WRONG notes afterward. View-local; no schema.
    @State private var selection: Set<StudioNoteEvent> = []
    /// Multi-step Undo (live-commit + undo). Each committed edit pushes the PRE-edit stream; Undo
    /// pops and re-commits it. View-local + session-scoped; both hosts get Undo, only the saved-take
    /// host adds Cancel.
    @State private var undoStack: [[StudioNoteEvent]] = []
    /// SELECT-mode cursor (absolute 16th index), navigated by ◀ / ▶; and the minimum bar count so
    /// the editor can show + navigate into empty trailing bars. Both view-local, no schema.
    @State private var cursor = 0
    @State private var minBars = 0

    private var step: Double { ScoreQuantizer.sixteenthMs(bpm: bpm) }

    var body: some View {
        let doc = ScoreQuantizer.quantize(events: events, bpm: bpm, instrument: instrument,
                                          minMeasures: minBars)
        let pages = ScoreLayout.paginate(score: doc, title: title, instrument: instrument)
        let points = selectionPoints(pages: pages)
        // The ＋ / − bar controls live in SELECT mode only, so they never sit under a note-placing
        // tap in Enter or a selection tap in Move/Edit.
        let lastBar = (editing && mode == .select) ? lastBarOverlay(pages: pages) : nil
        VStack(spacing: 12) {
            if editing { editToolbar() }
            if events.isEmpty {
                Text(editing ? "Tap the staff to place a note." : "No notes yet.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            ForEach(pages.indices, id: \.self) { i in
                ScorePageView(page: pages[i], editing: editing,
                              highlights: points.filter { $0.page == i }.map(\.point),
                              barControls: lastBar?.page == i ? lastBar?.controls : nil,
                              onTap: editing ? { p in handleTap(at: p, pageIndex: i, page: pages[i], pages: pages) } : nil)
                    .aspectRatio(pages[i].size.width / pages[i].size.height, contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .accessibilityIdentifier("score-page-\(i)")
            }
        }
        .onChange(of: editing) {
            if !editing { selection = []; undoStack.removeAll(); mode = .enter; minBars = 0 }
        }
        .onChange(of: mode) {
            // Entering SELECT with nothing selected: default the cursor to the LAST note and
            // select it (the "last played / edited note" starting point).
            if mode == .select, selection.isEmpty, let last = lastNote {
                cursor = onset(last); selectAtOnset(cursor)
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder private func editToolbar() -> some View {
        VStack(spacing: 8) {
            modeRow
            switch mode {
            case .enter:  enterRow
            case .select: selectRow
            case .move:   moveRow
            case .edit:   editRow
            }
            Text(hintText).font(.caption2).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(ScoreEditMode.allCases, id: \.self) { m in
                chip(modeLabel(m), on: mode == m, id: "score-mode-\(m.rawValue)") { mode = m }
            }
            Spacer(minLength: 0)
            Button { undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward").lineLimit(1).fixedSize()
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .disabled(undoStack.isEmpty)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("score-undo")
        }
    }

    /// ENTER mode: the note "pen" — length + accidental for notes you place. Sets the pen only
    /// (unlike EDIT's identical chips, which apply to the selection).
    private var enterRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Length").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([NoteDuration.eighth, .quarter, .half, .whole], id: \.self) { d in
                    chip(lengthLabel(d), on: editLength == d, id: "score-pen-length-\(lengthTag(d))") {
                        editLength = d
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("Accidental").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([Accidental.natural, .sharp, .flat], id: \.self) { a in
                    chip(accidentalLabel(a), on: editAccidental == a, id: "score-pen-acc-\(a.rawValue)") {
                        editAccidental = a
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var selectRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Select").font(.caption2).foregroundStyle(Theme.fgDim)
                chip("Notes", on: granularity == .note, id: "score-gran-note") { granularity = .note }
                chip("Bars", on: granularity == .bar, id: "score-gran-bar") { granularity = .bar }
                Spacer(minLength: 0)
                if !selection.isEmpty {
                    Button("Deselect") { selection = [] }
                        .font(.caption).accessibilityIdentifier("score-deselect")
                }
            }
            // The CURSOR row (under the switcher): ◀ / ▶ move the cursor one note (Note mode) or one
            // bar (Bar mode) and select it — distinct from Move's steppers, which move the notes.
            HStack(spacing: 6) {
                Text("Cursor").font(.caption2).foregroundStyle(Theme.fgDim)
                navBtn("◀", "score-cursor-prev", enabled: true) { moveCursor(-1) }
                navBtn("▶", "score-cursor-next", enabled: true) { moveCursor(1) }
                Text("Add / remove bars with the ＋ / − on the last bar.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
                Spacer(minLength: 0)
            }
        }
    }

    private func navBtn(_ text: String, _ id: String, enabled: Bool,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.callout.weight(.semibold)).frame(minWidth: 30)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.fgDim.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.fg)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    private var moveRow: some View {
        HStack(spacing: 6) {
            stepBtn("♯+", "score-move-up") { moveSemitone(1) }
            stepBtn("♭−", "score-move-down") { moveSemitone(-1) }
            Divider().frame(height: 18)
            stepBtn("◀", "score-move-left") { moveStep(-1) }
            stepBtn("▶", "score-move-right") { moveStep(1) }
            Divider().frame(height: 18)
            Button { duplicateSelection() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square").lineLimit(1).fixedSize()
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("score-duplicate")
            Spacer(minLength: 0)
        }
    }

    private var editRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Length").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([NoteDuration.eighth, .quarter, .half, .whole], id: \.self) { d in
                    chip(lengthLabel(d), on: editLength == d, id: "score-length-\(lengthTag(d))") {
                        setLength(d)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("Accidental").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([Accidental.natural, .sharp, .flat], id: \.self) { a in
                    chip(accidentalLabel(a), on: editAccidental == a, id: "score-acc-\(a.rawValue)") {
                        setAccidental(a)
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { deleteSelected() } label: {
                    Label("Delete", systemImage: "trash").lineLimit(1).fixedSize()
                }
                .buttonStyle(.bordered).tint(Theme.danger)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("score-delete")
            }
        }
    }

    private var hintText: String {
        let n = selection.count
        let notes = "\(n) note\(n == 1 ? "" : "s")"
        switch mode {
        case .enter:
            return "Tap the staff to place a note (length / accidental above)."
        case .select:
            if granularity == .bar {
                return n == 0 ? "Tap a bar to select all its notes." : "\(notes) selected."
            }
            return n == 0 ? "Tap near a note to select it — it snaps to the closest."
                          : "\(notes) selected — tap more, or switch to Move / Edit."
        case .move:
            return n == 0 ? "Select notes first, then nudge or duplicate them."
                          : "Nudge the selected \(notes) by a semitone or a step, or duplicate a bar later."
        case .edit:
            return n == 0 ? "Select notes first, then set length / accidental or delete."
                          : "Length, accidental, and delete apply to the selected \(notes)."
        }
    }

    // MARK: Chips

    private func chip(_ text: String, on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 34)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background((on ? Theme.accent : Theme.fgDim).opacity(on ? 0.22 : 0.10), in: Capsule())
                .foregroundStyle(on ? Theme.accent : Theme.fg)
                .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func stepBtn(_ text: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 34)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.fgDim.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.fg)
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
        .accessibilityIdentifier(id)
    }

    private func modeLabel(_ m: ScoreEditMode) -> String {
        switch m {
        case .enter: return "Enter"; case .select: return "Select"
        case .move: return "Move"; case .edit: return "Edit"
        }
    }
    private func lengthLabel(_ d: NoteDuration) -> String {
        switch d { case .eighth: return "1/8"; case .quarter: return "1/4"
        case .half: return "1/2"; case .whole: return "○"; default: return "\(d.sixteenths)" }
    }
    private func lengthTag(_ d: NoteDuration) -> String {
        switch d { case .eighth: return "8"; case .quarter: return "4"
        case .half: return "2"; case .whole: return "1"; default: return "x" }
    }
    private func accidentalLabel(_ a: Accidental) -> String {
        switch a { case .natural: return "♮"; case .sharp: return "♯"; case .flat: return "♭" }
    }

    // MARK: Commit / undo

    private func commit(_ next: [StudioNoteEvent]) {
        undoStack.append(events)
        onEdit(next)
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        onEdit(prev)         // re-commit the prior snapshot WITHOUT pushing
        selection = []        // the events changed underneath the value-keyed selection
    }

    /// Mutate every selected event in place → new events + a selection updated to the new VALUES,
    /// so Move/Edit keep the same notes highlighted (and it survives a host re-sort).
    private func mutateSelected(_ transform: (StudioNoteEvent) -> StudioNoteEvent) {
        guard !selection.isEmpty else { return }
        var newSel = Set<StudioNoteEvent>()
        let next = events.map { e -> StudioNoteEvent in
            guard selection.contains(e) else { return e }
            let m = transform(e); newSel.insert(m); return m
        }
        commit(next)
        selection = newSel
    }

    // MARK: Tap (SELECT places/selects · MOVE/EDIT adjust the selection)

    private func handleTap(at pagePoint: CGPoint, pageIndex: Int, page: ScorePage, pages: [ScorePage]) {
        switch mode {
        case .enter:
            // Every tap places a new note at the tapped staff position, using the pen.
            guard let loc = ScoreLayout.locate(point: pagePoint, page: page) else { return }
            let natural = ScoreLayout.naturalMidi(position: loc.position, clef: loc.staff)
            let (midi, acc): (Int, Accidental?)
            switch editAccidental {
            case .natural: (midi, acc) = (natural, nil)
            case .sharp:   (midi, acc) = (natural + 1, .sharp)
            case .flat:    (midi, acc) = (natural - 1, .flat)
            }
            let onMs = Int((Double(loc.measureIndex * 16 + loc.onset16ths) * step).rounded())
            // A note already lives at this time + pitch: SELECT it rather than stack an INVISIBLE
            // duplicate (the quantizer merges same-onset heads into one, but the persisted stream
            // would play + MIDI/audio-export doubled).
            if let existing = events.first(where: { $0.onMs == onMs && $0.note == midi }) {
                selection = [existing]; syncPen(to: existing); return
            }
            let offMs = onMs + Int((Double(editLength.sixteenths) * step).rounded())
            let newNote = StudioNoteEvent(onMs: onMs, offMs: offMs, note: midi, velocity: 96, accidental: acc)
            commit(events + [newNote])
            selection = [newNote]
        case .select:
            if granularity == .bar {
                guard let loc = ScoreLayout.locate(point: pagePoint, page: page) else { return }
                toggleBar(loc.measureIndex)
            } else if let e = nearestNote(to: pagePoint, pageIndex: pageIndex, pages: pages) {
                toggle(e)                                 // snap to the closest note
            } else {
                selection = []                            // tapped empty space → clear the selection
            }
        case .move, .edit:
            // A tap adjusts what you're operating on: snap to the closest note and toggle it.
            if let e = nearestNote(to: pagePoint, pageIndex: pageIndex, pages: pages) { toggle(e) }
        }
    }

    /// The note whose rendered position is closest to `pagePoint` on page `pageIndex`, or nil if
    /// none lands on that page. Powers SELECT's snap-to-closest and MOVE/EDIT's tap-to-adjust.
    private func nearestNote(to pagePoint: CGPoint, pageIndex: Int, pages: [ScorePage]) -> StudioNoteEvent? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let plan = ClefPlan.plan(for: instrument)
        var best: (e: StudioNoteEvent, d: CGFloat)?
        for e in events {
            let abs16 = Int((Double(e.onMs) / step).rounded())
            guard let np = ScoreLayout.notePoint(midi: e.note, accidental: e.accidental,
                                                 onset16ths: abs16, plan: plan, pages: pages),
                  np.page == pageIndex else { continue }
            let dx = np.point.x - pagePoint.x, dy = np.point.y - pagePoint.y
            let d = dx * dx + dy * dy
            if best == nil || d < best!.d { best = (e, d) }
        }
        // Only snap when the tap is reasonably NEAR a note (≈8% of page height) — a tap in empty
        // space selects nothing, so a stray/mis-aimed tap in Move/Edit can't toggle a distant note.
        guard let best else { return nil }
        let reach = pages[pageIndex].size.height * 0.08
        return best.d <= reach * reach ? best.e : nil
    }

    private func toggle(_ e: StudioNoteEvent) {
        if selection.contains(e) { selection.remove(e) } else { selection.insert(e) }
        syncPen(to: e)
    }

    /// Sync the length/accidental pen to a note (so the EDIT/ENTER chips reflect the last-touched one).
    private func syncPen(to e: StudioNoteEvent) {
        editLength = NoteDuration.snapped(toSixteenths: max(1, Int((Double(e.offMs - e.onMs) / step).rounded())))
        editAccidental = e.accidental ?? .natural
    }

    // MARK: Cursor + bars (SELECT navigation)

    private func onset(_ e: StudioNoteEvent) -> Int { Int((Double(e.onMs) / step).rounded()) }
    private var lastNote: StudioNoteEvent? { events.max { $0.onMs < $1.onMs } }
    private var noteOnsets: [Int] { Array(Set(events.map(onset))).sorted() }
    /// Bars occupied by content (rounded up from the last note's end).
    private var contentBars: Int {
        guard let end = events.map({ Int((Double($0.offMs) / step).rounded()) }).max() else { return 0 }
        return (end + 15) / 16
    }
    /// Total bars shown = content, floored at the requested minimum (empty trailing bars).
    private var barCount: Int { max(contentBars, minBars) }
    /// The last bar is EMPTY (a trailing added bar) → removable without deleting notes.
    private var lastBarEmpty: Bool { barCount > contentBars }

    private func selectAtOnset(_ on: Int) {
        let here = events.filter { onset($0) == on }
        selection = Set(here)
        if let e = here.first { syncPen(to: e) }
    }
    private func selectBar(_ bar: Int) {
        selection = Set(events.filter { onset($0) / 16 == bar })
        if let e = selection.first { syncPen(to: e) }
    }

    /// ◀ / ▶ in SELECT: move the cursor one note (Note mode) or one bar (Bar mode) and select the
    /// note(s) there. Moving forward past the end grows the score by an empty bar.
    private func moveCursor(_ delta: Int) {
        if granularity == .bar {
            let target = cursor / 16 + delta
            guard target >= 0 else { return }
            if target >= barCount { minBars = target + 1 }      // grow to include the target bar
            cursor = target * 16
            selectBar(target)
        } else if delta > 0 {
            if let nxt = noteOnsets.first(where: { $0 > cursor }) {
                cursor = nxt; selectAtOnset(cursor)
            } else {
                minBars = barCount + 1                          // past the last note → new empty bar
                cursor = barCount * 16
                selection = []
            }
        } else if let prv = noteOnsets.last(where: { $0 < cursor }) {
            cursor = prv; selectAtOnset(cursor)
        }
    }

    private func addBar() { minBars = barCount + 1 }
    /// Remove the last bar only when it's EMPTY — never deletes notes.
    private func removeBar() { if lastBarEmpty { minBars = barCount - 1 } }

    /// The ＋ / − bar controls, positioned at the LAST measure's top-right / bottom-right corners
    /// (page-space) on the page that holds it — drawn on the canvas (ScorePageView) so they sit on
    /// the last bar itself.
    private func lastBarOverlay(pages: [ScorePage]) -> (page: Int, controls: ScorePageView.BarControls)? {
        guard let pageIndex = pages.indices.last,
              let system = pages[pageIndex].systems.last,
              let measure = system.measures.last,
              let minTop = system.strips.map(\.top).min(),
              let maxTop = system.strips.map(\.top).max() else { return nil }
        let pad = system.spacing * 3
        let x = measure.x + measure.width
        return (pageIndex, ScorePageView.BarControls(
            topRight: CGPoint(x: x, y: minTop - pad),
            bottomRight: CGPoint(x: x, y: maxTop + system.spacing * 4 + pad),
            canRemove: lastBarEmpty,
            onAdd: { addBar() },
            onRemove: { removeBar() }))
    }

    private func toggleBar(_ measure: Int) {
        let inBar = events.filter { Int((Double($0.onMs) / step).rounded()) / 16 == measure }
        guard !inBar.isEmpty else { return }
        if inBar.allSatisfy({ selection.contains($0) }) { inBar.forEach { selection.remove($0) } }
        else { inBar.forEach { selection.insert($0) } }
    }

    // MARK: Move (steppers) / Duplicate

    private func moveSemitone(_ delta: Int) {
        mutateSelected { var e = $0; e.note = max(0, min(127, e.note + delta)); e.accidental = nil; return e }
    }

    private func moveStep(_ delta: Int) {
        guard !selection.isEmpty else { return }
        let d = Int((Double(delta) * step).rounded())
        let minOn = events.filter { selection.contains($0) }.map(\.onMs).min() ?? 0
        let shift = max(-minOn, d)      // the whole group moves together, never before 0
        guard shift != 0 else { return }
        mutateSelected { var e = $0; e.onMs += shift; e.offMs += shift; return e }
    }

    private func duplicateSelection() {
        let bar = Int((16.0 * step).rounded())
        let copies = events.filter { selection.contains($0) }.map { e -> StudioNoteEvent in
            var c = e; c.onMs += bar; c.offMs += bar; return c
        }
        guard !copies.isEmpty else { return }
        commit(events + copies)
        selection = Set(copies)         // select the copies so they can be nudged next
    }

    // MARK: Edit (length / accidental / delete)

    private func setLength(_ d: NoteDuration) {
        editLength = d
        mutateSelected { var e = $0; e.offMs = e.onMs + Int((Double(d.sixteenths) * step).rounded()); return e }
    }

    private func setAccidental(_ a: Accidental) {
        editAccidental = a
        mutateSelected { e in
            var next = e
            let staff = ClefPlan.plan(for: instrument).staff(forNote: e.note)
            let pos = ScoreLayout.spelledPosition(midi: e.note, clef: staff, accidental: e.accidental).position
            let natural = ScoreLayout.naturalMidi(position: pos, clef: staff)
            switch a {
            case .natural: next.note = natural; next.accidental = nil
            case .sharp:   next.note = natural + 1; next.accidental = .sharp
            case .flat:    next.note = natural - 1; next.accidental = .flat
            }
            return next
        }
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        commit(events.filter { !selection.contains($0) })
        selection = []
    }

    // MARK: Selection rings

    /// A page-space ring for every selected note (grouped per page by the caller).
    private func selectionPoints(pages: [ScorePage]) -> [(page: Int, point: CGPoint)] {
        guard !selection.isEmpty else { return [] }
        let plan = ClefPlan.plan(for: instrument)
        return events.filter { selection.contains($0) }.compactMap { e in
            let abs16 = Int((Double(e.onMs) / step).rounded())
            return ScoreLayout.notePoint(midi: e.note, accidental: e.accidental, onset16ths: abs16,
                                         plan: plan, pages: pages)
        }
    }
}

// MARK: - One laid page (Canvas host + tap/selection)

/// Draws ONE `ScorePage` via `ScoreRenderer` inside a SwiftUI Canvas. `withCGContext` hands a
/// TOP-LEFT-origin y-DOWN CGContext — exactly the renderer's contract. The page is laid at A4
/// metrics and SCALED to the canvas, so the on-screen sheet is proportionally identical to the
/// exported PDF. When `editing`, a `SpatialTapGesture` reports the tap in PAGE space and a blue
/// selection ring is stroked at each `highlights` point (I2 multi-select).
struct ScorePageView: View {
    /// The ＋ / − bar controls overlaid at the last bar's corners (page-space points).
    struct BarControls {
        var topRight: CGPoint
        var bottomRight: CGPoint
        var canRemove: Bool
        var onAdd: () -> Void
        var onRemove: () -> Void
    }

    let page: ScorePage
    var editing = false
    /// Page-space centers of the selection rings drawn on THIS page (empty = none).
    var highlights: [CGPoint] = []
    /// When set (the page holding the last measure, while editing), the ＋ / − bar buttons are
    /// overlaid at the last bar's top-right / bottom-right corners.
    var barControls: BarControls?
    /// Tap callback with the point converted to PAGE space (editing only).
    var onTap: ((CGPoint) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let scale = max(1, geo.size.width) / page.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.withCGContext { cg in
                        let s = size.width / page.size.width
                        cg.saveGState()
                        cg.scaleBy(x: s, y: s)
                        ScoreRenderer.draw(page, in: cg)
                        for h in highlights {
                            cg.setStrokeColor(CGColor(red: 0.43, green: 0.66, blue: 1, alpha: 0.95))
                            cg.setLineWidth(1.6)
                            cg.strokeEllipse(in: CGRect(x: h.x - 8, y: h.y - 8, width: 16, height: 16))
                        }
                        cg.restoreGState()
                    }
                }
                .contentShape(Rectangle())
                // Attached unconditionally; `onTap` is nil unless editing, so it no-ops otherwise. A
                // tap coexists with the parent ScrollView's drag-to-scroll.
                .gesture(SpatialTapGesture().onEnded { ev in
                    onTap?(CGPoint(x: ev.location.x / scale, y: ev.location.y / scale))
                })
                if let bc = barControls {
                    Button { bc.onAdd() } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                            .symbolRenderingMode(.palette).foregroundStyle(Theme.bg, Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .position(x: bc.topRight.x * scale, y: bc.topRight.y * scale)
                    .accessibilityIdentifier("score-add-bar")
                    .accessibilityLabel("Add bar")
                    Button { bc.onRemove() } label: {
                        Image(systemName: "minus.circle.fill").font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.bg, bc.canRemove ? Theme.danger : Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(!bc.canRemove)
                    .position(x: bc.bottomRight.x * scale, y: bc.bottomRight.y * scale)
                    .accessibilityIdentifier("score-remove-bar")
                    .accessibilityLabel("Remove bar")
                }
            }
        }
    }
}
