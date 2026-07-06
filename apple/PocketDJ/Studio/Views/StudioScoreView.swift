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

    private var take: StudioTake? { studio.take(takeId) }

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
        // Quantize + paginate per render: pure functions over an immutable event log — cheap
        // at real take sizes (hundreds of events), and always in sync with a rename (title).
        let doc = ScoreQuantizer.quantize(events: take.events, bpm: take.bpm,
                                          instrument: take.instrument)
        let pages = ScoreLayout.paginate(score: doc, title: displayTitle(take),
                                         instrument: take.instrument)
        return ScrollView {
            VStack(spacing: 14) {
                actionBar(take)
                if take.events.isEmpty {
                    Text("No notes were recorded in this take.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                // Vertical page scroll — every page keeps the A4 aspect and scales to width.
                ForEach(pages.indices, id: \.self) { i in
                    ScorePageView(page: pages[i])
                        .aspectRatio(pages[i].size.width / pages[i].size.height,
                                     contentMode: .fit)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
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
            .disabled(take.events.isEmpty)
            .accessibilityIdentifier("score-replay")
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

    // MARK: Exports

    private func exportPDF(_ take: StudioTake) {
        let doc = ScoreQuantizer.quantize(events: take.events, bpm: take.bpm,
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
        midiDoc = ScoreMIDIFile(data: SMFWriter.write(events: take.events, bpm: take.bpm,
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

    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in
                let scale = size.width / page.size.width
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                ScoreRenderer.draw(page, in: cg)
                cg.restoreGState()
            }
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
