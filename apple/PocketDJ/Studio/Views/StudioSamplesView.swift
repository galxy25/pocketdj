import SwiftUI
import UniformTypeIdentifiers

/// Performance ▸ SAMPLES — the sample library (spec §1 + §10).
///
/// The list renders straight off `StudioStore.samples` (observed): one row per sample showing
/// name, post-edit duration (mm:ss.s — samples are short, the tenth matters), a source badge
/// (track / mic / take) and the grid badge (BPM or "no grid" — the affordance hint that loops
/// need a tempo). Creation entry points are IN-CONTENT (the iPhone toolbar-overflow lesson:
/// critical controls must never be toolbar-only): "+ From track" opens the song→region carve
/// flow, "Record" opens the mic capture sheet. Tapping a row opens the non-destructive editor.
///
/// Rename runs through an alert `TextField` (the PlaylistsView precedent); delete shows a
/// confirmation LISTING the referrers from `studio.referrers(for:)` — loops keep playing but
/// can't be re-sliced, pattern rows go silent (spec §2's delete contract, surfaced verbatim).
/// A delete the store refuses (user samples folder unreachable — nothing provably gone) gets
/// its own explanation instead of silently doing nothing.
///
/// All flows are SHEETS (self-contained), so this view never depends on whatever navigation
/// container the Performance shell mounts it in.
struct StudioSamplesView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioMicRecorder.self) private var micRecorder
    @Environment(InstrumentPackStore.self) private var packs
    @Environment(SettingsStore.self) private var settings

    @State private var showNewFromTrack = false
    @State private var showMicRecord = false
    /// "From downloaded track" — the offline-only track carve (restrictToDownloaded).
    @State private var showDownloadedTrack = false
    /// The instrumental picker sheet ("Sample from instrumental") — pick a take, render its events.
    @State private var showInstrumentalPicker = false
    /// The file browser (`.fileImporter`) for arbitrary audio files.
    @State private var showFileImporter = false
    /// A file import is transcoding in the background (spinner in the bar).
    @State private var importing = false
    /// Import failed (DRM / unreadable / folder unreachable) — explained in an alert.
    @State private var importError: String?
    /// The sample whose editor sheet is open (id boxed for `sheet(item:)`).
    @State private var editing: StudioSampleRef?
    @State private var renamingId: String?
    @State private var renameDraft = ""
    @State private var deletingId: String?
    /// The store refused the delete (user root unreachable) — explain, never silently no-op.
    @State private var deleteBlocked = false

    /// Newest first — this is a creation surface: the sample you just made is the one you want.
    private var samples: [StudioSample] { studio.samples.sorted { $0.createdAt > $1.createdAt } }

    var body: some View {
        VStack(spacing: 0) {
            creationBar
                .padding(.horizontal, 12)
                .padding(.top, 10)
            if samples.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(samples) { s in row(s) }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .task { wire() }
        .sheet(isPresented: $showNewFromTrack) { StudioNewSampleFromTrackView() }
        .sheet(isPresented: $showDownloadedTrack) { StudioNewSampleFromTrackView(restrictToDownloaded: true) }
        .sheet(isPresented: $showMicRecord) { StudioMicRecordView() }
        .sheet(isPresented: $showInstrumentalPicker) { StudioInstrumentalPickerView() }
        .sheet(item: $editing) { ref in StudioSampleEditorView(sampleId: ref.id) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in handleImport(result) }
        .alert("Couldn’t import", isPresented: importErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("Rename sample", isPresented: renameBinding) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let id = renamingId { studio.renameSample(id, to: renameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete sample?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) {
                if let id = deletingId, !studio.deleteSample(id) { deleteBlocked = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Folder unreachable", isPresented: $deleteBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This sample lives in your samples folder, which isn't reachable right now. "
                 + "Reconnect the folder (Settings ▸ Storage) and try again — nothing was deleted.")
        }
    }

    // MARK: Wiring (views push dependencies in — the MixRecorder pattern, no app-init coupling)

    private func wire() {
        // The store resolves per-family folder bookmarks through settings; the mic recorder
        // files takes into this store and reads the same samples-folder bookmark.
        studio.settings = settings
        micRecorder.settings = settings
        micRecorder.store = studio
        // Active-take guard: a live mic capture's open file must never be swept by
        // Settings ▸ Storage delete-all (sweeping the open fragmented file corrupts the take).
        let mic = micRecorder
        studio.activeTakeFileName = { [weak mic] in mic?.activeTakeFileName }
        // Crash-orphan adoption on tab entry (idempotent — the MixRecorder doctrine: a take
        // interrupted by a crash filed no metadata, but its fragmented file survived).
        micRecorder.recoverOrphans()
    }

    // MARK: Creation bar (in-content — never toolbar-only on iPhone)

    private var creationBar: some View {
        HStack(spacing: 10) {
            Button { showNewFromTrack = true } label: {
                Label("From track", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sample-new-from-track")

            Button { showMicRecord = true } label: {
                Label("Record", systemImage: "mic.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent2.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent2)
            .accessibilityIdentifier("sample-record-mic")

            // Other in-catalog / file sources live behind a compact menu so the two primary
            // buttons (and their UI-test ids) stay put and the iPhone-portrait bar isn't crowded.
            Menu {
                Button { showFileImporter = true } label: {
                    Label("Import audio file…", systemImage: "folder")
                }
                Button { showDownloadedTrack = true } label: {
                    Label("From downloaded track", systemImage: "opticaldisc")
                }
                Button { showInstrumentalPicker = true } label: {
                    Label("Sample from instrumental…", systemImage: "pianokeys")
                }
                .disabled(studio.takes.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sample-add-menu")

            Spacer()

            if importing {
                ProgressView().controlSize(.small)
            } else if !samples.isEmpty {
                Text("\(samples.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(Theme.fgDim)
            Text("No samples yet")
                .font(.headline).foregroundStyle(Theme.fg)
            Text("Carve a region out of any track, import an audio file, or record from the mic.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Row

    private func row(_ s: StudioSample) -> some View {
        Button { editing = StudioSampleRef(id: s.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.sourceIcon(s.source))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    // The NAME text carries the row id (leaf control — a container id would
                    // clobber descendants on macOS, the StemAuditionPanel trap).
                    Text(s.name.isEmpty ? "Untitled sample" : s.name)
                        .font(.callout.weight(.medium)).foregroundStyle(Theme.fg)
                        .lineLimit(1)
                        .accessibilityIdentifier("sample-row-\(s.id)")
                    HStack(spacing: 6) {
                        // Post-edit duration: what the sample PLAYS at, not the raw capture.
                        Text(StudioFmt.mmssTenths(s.effectiveDurationMs))
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        badge(Self.sourceLabel(s.source), tint: Theme.accent)
                        if let g = s.grid {
                            badge("\(Fmt.trim(g.bpm)) BPM", tint: Theme.accent2)
                        } else {
                            badge("no grid", tint: Theme.fgDim)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(10)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renamingId = s.id
                renameDraft = s.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .accessibilityIdentifier("sample-rename-\(s.id)")
            Button(role: .destructive) { deletingId = s.id } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("sample-delete-\(s.id)")
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private static func sourceIcon(_ source: StudioSource) -> String {
        switch source {
        case .track: return "music.note"
        case .mic: return "mic.fill"
        case .take: return "pianokeys"
        case .file: return "waveform"
        }
    }

    private static func sourceLabel(_ source: StudioSource) -> String {
        switch source {
        case .track: return "track"
        case .mic: return "mic"
        case .take: return "take"
        case .file: return "file"
        }
    }

    // MARK: Alert bindings + delete copy

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    // MARK: File import (arbitrary audio → transcode → new grid-less sample)

    /// Transcode a picked audio file into a canonical `.m4a` sample. The `.fileImporter` URL is a
    /// TRANSIENT security-scoped grant — we hold the scope only while copying INTO the samples
    /// folder and never persist the external URL (the StorageView import precedent). Grid-less on
    /// arrival (no server sidecar): the editor's Auto-detect/tap-tempo sets a tempo before slicing.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let e) = result { importError = e.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples)) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            importError = "Your samples folder isn’t reachable right now (Settings ▸ Storage)."
            return
        }
        let sampleId = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: sampleId)
        let destURL = dest.url.appendingPathComponent(fileName)
        let displayName = url.deletingPathExtension().lastPathComponent
        importing = true
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                dest.release?()
            }
            do {
                let imported = try await StudioRender.shared.importAudioFile(sourceURL: url, to: destURL)
                studio.addSample(StudioSample(
                    id: sampleId, name: displayName.isEmpty ? "Imported sample" : displayName,
                    fileName: fileName, wasUserFolder: dest.isUserFolder,
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    durationMs: imported.durationMs,
                    source: .file(originalName: url.lastPathComponent),
                    grid: nil, edit: .neutral))
                importing = false
                editing = StudioSampleRef(id: sampleId)   // open the editor on the new sample
            } catch {
                importing = false
                importError = importMessage(for: error)
            }
        }
    }

    private func importMessage(for error: Error) -> String {
        if case StudioRenderError.protectedSource = error {
            return "This file is DRM-protected (a purchased or streamed track), so it can’t be "
                 + "turned into a sample."
        }
        return "Couldn’t read that audio file. Try a different one (mp3, m4a, wav, aiff, or caf)."
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deletingId != nil }, set: { if !$0 { deletingId = nil } })
    }

    /// The referrer-aware confirmation copy (spec §2): tell the user exactly what a delete
    /// leaves behind — loops stay playable (self-contained after render) but lose re-slicing;
    /// pattern rows targeting the sample go silent as "missing" rows.
    private var deleteMessage: String {
        guard let id = deletingId else { return "" }
        let r = studio.referrers(for: id)
        var parts = ["The audio file is removed from this device."]
        if r.loopCount > 0 {
            parts.append("\(r.loopCount) loop\(r.loopCount == 1 ? "" : "s") sliced from it keep"
                         + " playing but can't be re-sliced.")
        }
        if r.patternRowCount > 0 {
            parts.append("\(r.patternRowCount) sequencer row\(r.patternRowCount == 1 ? "" : "s")"
                         + " will be muted.")
        }
        return parts.joined(separator: " ")
    }
}

/// Identifiable box so `sheet(item:)` can present the editor for a sample id.
struct StudioSampleRef: Identifiable {
    let id: String
}

// MARK: - Instrumental picker ("Sample from instrumental")

/// A sheet listing the saved instrumentals; picking one RENDERS its note events → a real `.m4a`
/// sample (`StudioTakeSampler`) and dismisses. The reverse-direction entry point to the
/// take→sample path — the forward one is the in-row button on the Instrumentals list — so a user
/// building a sample library never has to leave the Samples tab. Needs the instrument pack
/// downloaded (the bank the render loads); a missing pack surfaces the inline error.
struct StudioInstrumentalPickerView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentPackStore.self) private var packs
    @Environment(\.dismiss) private var dismiss

    /// The take rendering right now (its row spinner) — nil when idle. Blocks a second pick.
    @State private var renderingId: String?
    @State private var errorText: String?

    private var takes: [StudioTake] { studio.takes.sorted { $0.createdAt > $1.createdAt } }

    var body: some View {
        NavigationStack {
            Group {
                if takes.isEmpty {
                    ContentUnavailableView("No instrumentals", systemImage: "pianokeys",
                        description: Text("Record an instrumental on the Instruments tab first."))
                } else {
                    List {
                        ForEach(takes) { take in row(take) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Sample from instrumental")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("instrumental-pick-cancel")
                }
            }
            .alert("Couldn’t sample", isPresented: Binding(get: { errorText != nil },
                                                           set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func row(_ take: StudioTake) -> some View {
        Button { pick(take) } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(Theme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.name.isEmpty ? "Untitled instrumental" : take.name)
                        .foregroundStyle(Theme.fg).lineLimit(1)
                    Text("\(take.instrument.displayName) · \(Fmt.duration(take.durationMs))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                if renderingId == take.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "waveform.badge.plus").foregroundStyle(Theme.accent2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(renderingId != nil || take.scoreEvents.isEmpty)
        .accessibilityIdentifier("instrumental-pick-\(take.id)")
    }

    private func pick(_ take: StudioTake) {
        guard renderingId == nil else { return }
        renderingId = take.id
        Task {
            do {
                _ = try await StudioTakeSampler.makeSample(from: take, studio: studio, packs: packs)
                dismiss()
            } catch {
                renderingId = nil
                errorText = StudioTakeSampler.message(for: error)
            }
        }
    }
}

/// Studio-local formatting helpers (samples/loops are SHORT — `Fmt.duration`'s m:ss granularity
/// hides the difference between a 1.2 s and a 1.9 s stab, so the tenth is shown).
enum StudioFmt {
    /// Milliseconds → "m:ss.t" (tenths).
    static func mmssTenths(_ ms: Int) -> String {
        let t = max(0, ms)
        let s = t / 1000
        let tenths = (t % 1000) / 100
        return String(format: "%d:%02d.%d", s / 60, s % 60, tenths)
    }

    /// Seconds → "m:ss.t" (the transport clock variant).
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        return mmssTenths(Int(seconds * 1000))
    }
}
