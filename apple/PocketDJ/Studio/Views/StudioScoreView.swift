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

    /// Edit mode (spec §7) — toggled by the action bar, passed to the shared ScoreEditorView.
    @State private var editing = false

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
        ScrollView {
            VStack(spacing: 14) {
                actionBar(take)
                // The shared editable surface — a take commits edits as `editedEvents`.
                ScoreEditorView(events: take.scoreEvents, bpm: take.bpm, instrument: take.instrument,
                                title: displayTitle(take), editing: editing,
                                onEdit: { studio.setTakeEvents(takeId, events: $0) })
                Text("\(take.instrument.displayName) · \(Fmt.bpm(take.bpm)) BPM")
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

    // MARK: Exports

    private func exportPDF(_ take: StudioTake) {
        let doc = ScoreQuantizer.quantize(events: take.scoreEvents, bpm: take.bpm,
                                          instrument: take.instrument)
        let data = ScorePDF.makePDF(score: doc, title: displayTitle(take),
                                    instrument: take.instrument)
        guard !data.isEmpty else {
            errorText = "Couldn't build the PDF."
            return
        }
        pdfDoc = ScorePDFFile(data: data)
        showPDFExporter = true
    }

    private func exportMIDI(_ take: StudioTake) {
        // Deliberately the RAW/effective events (spec §7): the score's readable simplification is
        // the PDF; MIDI is the faithful stream a DAW ingests.
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
