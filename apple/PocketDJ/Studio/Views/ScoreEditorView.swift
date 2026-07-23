import SwiftUI

/// The reusable editable-score surface (spec §7). Renders an event stream as notation and — when
/// `editing` — lets you tap the staff to place a note (current length + accidental) or select an
/// existing one, then re-apply length/accidental or delete. Edits are committed through `onEdit`.
/// Shared by the saved-take Score screen and the Instruments LIVE staff, so both edit identically.
struct ScoreEditorView: View {
    var events: [StudioNoteEvent]
    var bpm: Double
    var instrument: InstrumentKey
    var title: String
    var editing: Bool
    /// Commit an edited event stream (take → setTakeEvents; live → setLiveEvents).
    var onEdit: ([StudioNoteEvent]) -> Void

    @State private var editLength: NoteDuration = .quarter
    @State private var editAccidental: Accidental = .natural
    /// Index into `events` of the selected note; nil = none.
    @State private var selectedIndex: Int?
    /// Multi-step Undo (live-commit + undo model). Each committed edit pushes the PRE-edit
    /// stream here; Undo pops and re-commits it. View-local + session-scoped — cleared when
    /// editing ends, never persisted (no schema surface). Both hosts get Undo; only the
    /// saved-take host adds Cancel (the live staff keeps changing as you play).
    @State private var undoStack: [[StudioNoteEvent]] = []

    var body: some View {
        let doc = ScoreQuantizer.quantize(events: events, bpm: bpm, instrument: instrument)
        let pages = ScoreLayout.paginate(score: doc, title: title, instrument: instrument)
        let sel = selectionPoint(pages: pages)
        VStack(spacing: 12) {
            if editing { editToolbar() }
            if events.isEmpty {
                Text(editing ? "Tap the staff to place a note." : "No notes yet.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            ForEach(pages.indices, id: \.self) { i in
                ScorePageView(page: pages[i], editing: editing,
                              highlight: sel?.page == i ? sel?.point : nil,
                              onTap: editing ? { p in handleTap(at: p, page: pages[i]) } : nil)
                    .aspectRatio(pages[i].size.width / pages[i].size.height, contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .accessibilityIdentifier("score-page-\(i)")
            }
        }
        .onChange(of: editing) { if !editing { selectedIndex = nil; undoStack.removeAll() } }
    }

    // MARK: Toolbar (length · accidental · delete)

    private func editToolbar() -> some View {
        VStack(spacing: 8) {
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
                Button { undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").lineLimit(1).fixedSize()
                }
                .buttonStyle(.bordered).tint(Theme.accent)
                .disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("score-undo")
                Button(role: .destructive) { deleteSelected() } label: {
                    Label("Delete", systemImage: "trash").lineLimit(1).fixedSize()
                }
                .buttonStyle(.bordered).tint(Theme.danger)
                .disabled(selectedIndex == nil)
                .accessibilityIdentifier("score-delete")
            }
            Text(selectedIndex != nil
                 ? "Editing the selected note — tap the staff to place another."
                 : "Tap the staff to place a note, or tap a note to select it.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

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

    // MARK: Operations

    /// Commit an edit, first snapshotting the pre-edit stream onto the undo stack so Undo can
    /// walk back through the whole session. Undo itself re-commits via `onEdit` directly (no
    /// push), so undo is repeatable and never grows the stack.
    private func commit(_ next: [StudioNoteEvent]) {
        undoStack.append(events)
        onEdit(next)
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        onEdit(prev)           // re-commit the prior snapshot WITHOUT pushing
        selectedIndex = nil     // indices shift when an add/delete is undone
    }

    /// A tap on a page: select the note at that spot, else place a new one there.
    private func handleTap(at pagePoint: CGPoint, page: ScorePage) {
        guard let loc = ScoreLayout.locate(point: pagePoint, page: page) else { selectedIndex = nil; return }
        let plan = ClefPlan.plan(for: instrument)
        let step = ScoreQuantizer.sixteenthMs(bpm: bpm)
        if let j = events.firstIndex(where: {
            let abs16 = Int((Double($0.onMs) / step).rounded())
            let staff = plan.staff(forNote: $0.note)
            let pos = ScoreLayout.spelledPosition(midi: $0.note, clef: staff, accidental: $0.accidental).position
            return abs16 == loc.measureIndex * 16 + loc.onset16ths && staff == loc.staff && pos == loc.position
        }) {
            selectedIndex = j
            let e = events[j]
            editLength = NoteDuration.snapped(toSixteenths: max(1, Int((Double(e.offMs - e.onMs) / step).rounded())))
            editAccidental = e.accidental ?? .natural
            return
        }
        let natural = ScoreLayout.naturalMidi(position: loc.position, clef: loc.staff)
        let (midi, acc): (Int, Accidental?)
        switch editAccidental {
        case .natural: (midi, acc) = (natural, nil)
        case .sharp: (midi, acc) = (natural + 1, .sharp)
        case .flat: (midi, acc) = (natural - 1, .flat)
        }
        let onMs = Int((Double(loc.measureIndex * 16 + loc.onset16ths) * step).rounded())
        let offMs = onMs + Int((Double(editLength.sixteenths) * step).rounded())
        var next = events
        next.append(StudioNoteEvent(onMs: onMs, offMs: offMs, note: midi, velocity: 96, accidental: acc))
        commit(next)
        selectedIndex = next.count - 1
    }

    private func setLength(_ d: NoteDuration) {
        editLength = d
        guard let j = selectedIndex, j < events.count else { return }
        let step = ScoreQuantizer.sixteenthMs(bpm: bpm)
        var next = events
        next[j].offMs = next[j].onMs + Int((Double(d.sixteenths) * step).rounded())
        commit(next)
    }

    private func setAccidental(_ a: Accidental) {
        editAccidental = a
        guard let j = selectedIndex, j < events.count else { return }
        var next = events
        let e = next[j]
        let staff = ClefPlan.plan(for: instrument).staff(forNote: e.note)
        let pos = ScoreLayout.spelledPosition(midi: e.note, clef: staff, accidental: e.accidental).position
        let natural = ScoreLayout.naturalMidi(position: pos, clef: staff)
        switch a {
        case .natural: next[j].note = natural; next[j].accidental = nil
        case .sharp: next[j].note = natural + 1; next[j].accidental = .sharp
        case .flat: next[j].note = natural - 1; next[j].accidental = .flat
        }
        commit(next)
    }

    private func deleteSelected() {
        guard let j = selectedIndex, j < events.count else { return }
        var next = events
        next.remove(at: j)
        commit(next)
        selectedIndex = nil
    }

    /// The selected note's page + page-space point (the selection ring). nil when nothing selected.
    private func selectionPoint(pages: [ScorePage]) -> (page: Int, point: CGPoint)? {
        guard let j = selectedIndex, j < events.count else { return nil }
        let e = events[j]
        let step = ScoreQuantizer.sixteenthMs(bpm: bpm)
        let abs16 = Int((Double(e.onMs) / step).rounded())
        return ScoreLayout.notePoint(midi: e.note, accidental: e.accidental, onset16ths: abs16,
                                     plan: ClefPlan.plan(for: instrument), pages: pages)
    }
}

// MARK: - One laid page (Canvas host + tap/selection)

/// Draws ONE `ScorePage` via `ScoreRenderer` inside a SwiftUI Canvas. `withCGContext` hands a
/// TOP-LEFT-origin y-DOWN CGContext — exactly the renderer's contract. The page is laid at A4
/// metrics and SCALED to the canvas, so the on-screen sheet is proportionally identical to the
/// exported PDF. When `editing`, a `SpatialTapGesture` reports the tap in PAGE space and a blue
/// selection ring is stroked at `highlight`.
struct ScorePageView: View {
    let page: ScorePage
    var editing = false
    /// Page-space center of the selection ring drawn on THIS page (nil = none).
    var highlight: CGPoint?
    /// Tap callback with the point converted to PAGE space (editing only).
    var onTap: ((CGPoint) -> Void)?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.withCGContext { cg in
                    let scale = size.width / page.size.width
                    cg.saveGState()
                    cg.scaleBy(x: scale, y: scale)
                    ScoreRenderer.draw(page, in: cg)
                    if let h = highlight {
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
                let scale = max(1, geo.size.width) / page.size.width
                onTap?(CGPoint(x: ev.location.x / scale, y: ev.location.y / scale))
            })
        }
    }
}
