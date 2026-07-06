import SwiftUI

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
    @Environment(SettingsStore.self) private var settings

    @State private var showNewFromTrack = false
    @State private var showMicRecord = false
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
        .sheet(isPresented: $showMicRecord) { StudioMicRecordView() }
        .sheet(item: $editing) { ref in StudioSampleEditorView(sampleId: ref.id) }
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

            Spacer()

            if !samples.isEmpty {
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
            Text("Carve a region out of any track, or record straight from the microphone.")
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
        }
    }

    private static func sourceLabel(_ source: StudioSource) -> String {
        switch source {
        case .track: return "track"
        case .mic: return "mic"
        case .take: return "take"
        }
    }

    // MARK: Alert bindings + delete copy

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })
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
