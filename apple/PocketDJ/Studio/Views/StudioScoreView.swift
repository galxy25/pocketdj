import SwiftUI
import UniformTypeIdentifiers

// MARK: - Studio ▸ Instruments ▸ Score (spec §7)
//
// A take's musical score: `ScoreQuantizer.quantize` (derived at render time — never persisted,
// so quantizer improvements retroactively improve every saved take) laid out by
// `ScoreLayout.paginate` and drawn by `ScoreRenderer` into each page's Canvas. The pages are
// laid at the PDF's OWN A4 metrics and scaled to the screen width — deliberately, so what the
// user sees IS the export, pixel-proportional (one layout, two hosts, zero drift; the ScorePDF
// header's design). Replay plays the take's raw EVENTS back through InstrumentEngine, so the
// score and the sound always agree. Exports ride `.fileExporter` (the SettingsView precedent):
// vector PDF via `ScorePDF.makePDF`, type-0 SMF via `SMFWriter.write` (raw unquantized events).
struct StudioScoreView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentEngine.self) private var instruments
    @Environment(InstrumentPackStore.self) private var packs

    /// Looked up live from the store (not a snapshot) so a rename elsewhere reflects here.
    let takeId: String

    @State private var showPDFExporter = false
    @State private var showMIDIExporter = false
    @State private var pdfDoc = ScorePDFFile(data: Data())
    @State private var midiDoc = ScoreMIDIFile(data: Data())
    @State private var errorText: String?

    // Editing (spec §7): a tap places a note (current length + accidental) or selects an existing
    // one; the toolbar's length/accidental then re-apply to the selection, and Delete removes it.
    @State private var editing = false
    @State private var editLength: NoteDuration = .quarter
    @State private var editAccidental: Accidental = .natural
    /// Index into the take's effective (edited) event stream of the selected note; nil = none.
    @State private var selectedIndex: Int?

    private var take: StudioTake? { studio.take(takeId) }
    /// The events the score renders/edits — the edited stream once touched, else the raw take.
    private var events: [StudioNoteEvent] { take?.scoreEvents ?? [] }

    var body: some View {
        Group {
            if let take {
                content(take)
            } else {
                // The take was deleted while this screen was on the stack — degrade, never crash.
                ContentUnavailableView("Take not found", systemImage: "questionmark.square.dashed",
                                       description: Text("This take was deleted."))
            }
        }
        .background(Theme.bg)
        .navigationTitle(take.map { $0.name.isEmpty ? "Score" : $0.name } ?? "Score")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Filename: "<take name>.pdf"/".mid". The exporter appends the content type's
        // extension when missing, so the base name is passed bare for PDF; MIDI passes
        // ".mid" explicitly (a registered extension for public.midi-audio) per spec.
        .fileExporter(isPresented: $showPDFExporter, document: pdfDoc, contentType: .pdf,
                      defaultFilename: exportBaseName) { _ in }
        .fileExporter(isPresented: $showMIDIExporter, document: midiDoc,
                      contentType: ScoreMIDIFile.midiType,
                      defaultFilename: exportBaseName + ".mid") { _ in }
        .alert("Score", isPresented: Binding(get: { errorText != nil },
                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onDisappear {
            // Leaving the score stops ITS replay (the sampler keeps sounding otherwise, with
            // no visible stop control anywhere — replay is a this-screen affordance).
            if instruments.isReplaying { instruments.stopReplay() }
        }
    }

    // MARK: Content

    private func content(_ take: StudioTake) -> some View {
        // Quantize + paginate per render: pure functions over the EFFECTIVE event log (edited once
        // touched) — cheap at real take sizes, always in sync with edits + a rename (title).
        let doc = ScoreQuantizer.quantize(events: take.scoreEvents, bpm: take.bpm,
                                          instrument: take.instrument)
        let pages = ScoreLayout.paginate(score: doc, title: displayTitle(take),
                                         instrument: take.instrument)
        let sel = selectionPoint(take: take, pages: pages)
        return ScrollView {
            VStack(spacing: 14) {
                actionBar(take)
                if editing { editToolbar(take) }
                if take.scoreEvents.isEmpty {
                    Text(editing ? "Tap the staff to place a note."
                                 : "No notes were recorded in this take.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                // Vertical page scroll — every page keeps the A4 aspect and scales to width.
                ForEach(pages.indices, id: \.self) { i in
                    ScorePageView(page: pages[i], editing: editing,
                                  highlight: sel?.page == i ? sel?.point : nil,
                                  onTap: editing ? { p in handleTap(at: p, page: pages[i], take: take) } : nil)
                        .aspectRatio(pages[i].size.width / pages[i].size.height, contentMode: .fit)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                        .accessibilityIdentifier("score-page-\(i)")
                }
                Text("\(pages.count) page\(pages.count == 1 ? "" : "s") · \(take.instrument.displayName) · \(Fmt.bpm(take.bpm)) BPM")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            .padding()
            .frame(maxWidth: 700)     // a readable sheet width on iPad/macOS; full width on iPhone
            .frame(maxWidth: .infinity)
        }
    }

    /// Replay + exports, IN CONTENT (iPhone-portrait toolbar-overflow lesson — an export
    /// hidden behind "•••" is an export nobody finds).
    private func actionBar(_ take: StudioTake) -> some View {
        HStack(spacing: 10) {
            Button {
                if !StudioTakeReplay.toggle(take: take, instruments: instruments, packs: packs) {
                    errorText = "Download the \(take.instrument.displayName) pack to hear this take."
                }
            } label: {
                Label(instruments.isReplaying ? "Stop" : "Replay",
                      systemImage: instruments.isReplaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(instruments.isReplaying ? Theme.danger : Theme.accent)
            .disabled(take.scoreEvents.isEmpty)
            .accessibilityIdentifier("score-replay")
            Button {
                editing.toggle()
                if !editing { selectedIndex = nil }
            } label: {
                Label(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil")
            }
            .buttonStyle(.bordered)
            .tint(editing ? Theme.accent2 : Theme.accent)
            .accessibilityIdentifier("score-edit")
            Spacer(minLength: 0)
            Button { exportPDF(take) } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            .accessibilityIdentifier("score-export-pdf")
            Button { exportMIDI(take) } label: {
                Label("MIDI", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("score-export-midi")
        }
    }

    // MARK: Edit toolbar + operations (spec §7)

    /// The four supported edits: note length (1/8·1/4·1/2·whole), accidental (♮/♯/♭), delete.
    /// Length/accidental are the PLACEMENT defaults AND re-apply to the selected note.
    private func editToolbar(_ take: StudioTake) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Length").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([NoteDuration.eighth, .quarter, .half, .whole], id: \.self) { d in
                    chip(lengthLabel(d), on: editLength == d, id: "score-length-\(lengthTag(d))") {
                        setLength(d, take: take)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("Accidental").font(.caption2).foregroundStyle(Theme.fgDim)
                ForEach([Accidental.natural, .sharp, .flat], id: \.self) { a in
                    chip(accidentalLabel(a), on: editAccidental == a, id: "score-acc-\(a.rawValue)") {
                        setAccidental(a, take: take)
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { deleteSelected(take: take) } label: {
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

    /// A tap on a page: select the note at that spot, else place a new one there.
    private func handleTap(at pagePoint: CGPoint, page: ScorePage, take: StudioTake) {
        guard let loc = ScoreLayout.locate(point: pagePoint, page: page) else { selectedIndex = nil; return }
        let plan = ClefPlan.plan(for: take.instrument)
        let step = ScoreQuantizer.sixteenthMs(bpm: take.bpm)
        // Existing note at this (measure, onset, staff, position)?
        if let j = take.scoreEvents.firstIndex(where: {
            let abs16 = Int((Double($0.onMs) / step).rounded())
            let staff = plan.staff(forNote: $0.note)
            let pos = ScoreLayout.spelledPosition(midi: $0.note, clef: staff, accidental: $0.accidental).position
            return abs16 == loc.measureIndex * 16 + loc.onset16ths && staff == loc.staff && pos == loc.position
        }) {
            selectedIndex = j
            // Reflect the selected note's length/accidental into the toolbar.
            let e = take.scoreEvents[j]
            editLength = NoteDuration.snapped(toSixteenths: max(1, Int((Double(e.offMs - e.onMs) / step).rounded())))
            editAccidental = e.accidental ?? .natural
            return
        }
        // Place a new note.
        let natural = ScoreLayout.naturalMidi(position: loc.position, clef: loc.staff)
        let (midi, acc): (Int, Accidental?)
        switch editAccidental {
        case .natural: (midi, acc) = (natural, nil)
        case .sharp: (midi, acc) = (natural + 1, .sharp)
        case .flat: (midi, acc) = (natural - 1, .flat)
        }
        let onMs = Int((Double(loc.measureIndex * 16 + loc.onset16ths) * step).rounded())
        let offMs = onMs + Int((Double(editLength.sixteenths) * step).rounded())
        var next = take.scoreEvents
        next.append(StudioNoteEvent(onMs: onMs, offMs: offMs, note: midi, velocity: 96, accidental: acc))
        studio.setTakeEvents(takeId, events: next)
        selectedIndex = next.count - 1
    }

    private func setLength(_ d: NoteDuration, take: StudioTake) {
        editLength = d
        guard let j = selectedIndex, j < take.scoreEvents.count else { return }
        let step = ScoreQuantizer.sixteenthMs(bpm: take.bpm)
        var next = take.scoreEvents
        next[j].offMs = next[j].onMs + Int((Double(d.sixteenths) * step).rounded())
        studio.setTakeEvents(takeId, events: next)
    }

    private func setAccidental(_ a: Accidental, take: StudioTake) {
        editAccidental = a
        guard let j = selectedIndex, j < take.scoreEvents.count else { return }
        var next = take.scoreEvents
        let e = next[j]
        let staff = ClefPlan.plan(for: take.instrument).staff(forNote: e.note)
        let pos = ScoreLayout.spelledPosition(midi: e.note, clef: staff, accidental: e.accidental).position
        let natural = ScoreLayout.naturalMidi(position: pos, clef: staff)
        switch a {
        case .natural: next[j].note = natural; next[j].accidental = nil
        case .sharp: next[j].note = natural + 1; next[j].accidental = .sharp
        case .flat: next[j].note = natural - 1; next[j].accidental = .flat
        }
        studio.setTakeEvents(takeId, events: next)
    }

    private func deleteSelected(take: StudioTake) {
        guard let j = selectedIndex, j < take.scoreEvents.count else { return }
        var next = take.scoreEvents
        next.remove(at: j)
        studio.setTakeEvents(takeId, events: next)
        selectedIndex = nil
    }

    /// The selected note's page + page-space point (the selection ring). nil when nothing selected.
    private func selectionPoint(take: StudioTake, pages: [ScorePage]) -> (page: Int, point: CGPoint)? {
        guard let j = selectedIndex, j < take.scoreEvents.count else { return nil }
        let e = take.scoreEvents[j]
        let step = ScoreQuantizer.sixteenthMs(bpm: take.bpm)
        let abs16 = Int((Double(e.onMs) / step).rounded())
        return ScoreLayout.notePoint(midi: e.note, accidental: e.accidental, onset16ths: abs16,
                                     plan: ClefPlan.plan(for: take.instrument), pages: pages)
    }

    // MARK: Exports

    private func exportPDF(_ take: StudioTake) {
        let doc = ScoreQuantizer.quantize(events: take.scoreEvents, bpm: take.bpm,
                                          instrument: take.instrument)
        let data = ScorePDF.makePDF(score: doc, title: displayTitle(take),
                                    instrument: take.instrument)
        // Empty Data = CG resource exhaustion (ScorePDF's documented failure mode) — surface
        // it instead of writing a corrupt file.
        guard !data.isEmpty else {
            errorText = "Couldn't build the PDF."
            return
        }
        pdfDoc = ScorePDFFile(data: data)
        showPDFExporter = true
    }

    private func exportMIDI(_ take: StudioTake) {
        // Deliberately the RAW unquantized events (spec §7): MIDI is the faithful performance
        // for a DAW; the score is the readable simplification.
        midiDoc = ScoreMIDIFile(data: SMFWriter.write(events: take.scoreEvents, bpm: take.bpm,
                                                      instrument: take.instrument))
        showMIDIExporter = true
    }

    private func displayTitle(_ take: StudioTake) -> String {
        take.name.isEmpty ? "Untitled take" : take.name
    }

    /// Export base name: the take's name with filesystem-hostile separators stripped.
    private var exportBaseName: String {
        let raw = take.map(displayTitle) ?? "Take"
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Take" : cleaned
    }
}

// MARK: - One laid page (Canvas host)

/// Draws ONE `ScorePage` via `ScoreRenderer` inside a SwiftUI Canvas. `withCGContext` hands a
/// TOP-LEFT-origin y-DOWN CGContext — exactly the renderer's contract (ScorePDF flips its PDF
/// context to the same space). The page is laid at A4 metrics and SCALED to the canvas, so the
/// on-screen sheet is proportionally identical to the exported PDF (and stays crisp — vector
/// paths scale, they don't resample). The renderer paints its own white sheet: notation is
/// black-on-white by design, deliberately not theme-tinted (screen == export).
private struct ScorePageView: View {
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

// MARK: - FileDocument wrappers (the EditsFile precedent)

/// PDF bytes for `.fileExporter` (score-export-pdf).
struct ScorePDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Standard-MIDI-file bytes for `.fileExporter` (score-export-midi).
struct ScoreMIDIFile: FileDocument {
    /// `public.midi-audio`. `.mid` is one of its registered extensions, so the explicit
    /// "<name>.mid" default filename survives the exporter's type check.
    static let midiType: UTType = .midi
    static var readableContentTypes: [UTType] { [midiType] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
