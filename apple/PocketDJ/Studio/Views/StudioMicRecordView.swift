import SwiftUI
#if canImport(UIKit)
import UIKit   // openSettingsURLString — the mic-denied hand-off (iOS/iPadOS only)
#endif

/// Performance ▸ SAMPLES ▸ "Record" (spec §10) — capture a sample straight from the microphone.
/// Presented as a SHEET from `StudioSamplesView` (no init args). All the hard parts (AVAudioSession
/// coexistence, route-change hardening, crash-safe fragmented writing, the capture-stall watchdog)
/// live in `StudioMicRecorder`; this view is JUST the UI over its published state — it never touches
/// an audio session (the house rule).
///
/// Flow (spec §10): permission → level meter → record / stop → named sample.
///   • on appear `beginMonitoring()` requests permission (the first run shows the system prompt) and
///     brings up the level meter; a DENIED result shows the Settings hand-off, never a dead button;
///   • the meter is a `TimelineView` polling `micRecorder.levels` (peak + rms bars) — the levels
///     mirror is deliberately non-observable (a 10 Hz meter must never invalidate SwiftUI), so it's
///     SAMPLED, not observed;
///   • record → the pulsing stop button + an elapsed clock derived from `startedAtMs` (never a
///     ticking published property); a ≥5 s capture stall shows a warning; a writer death surfaces
///     `writerFailureMessage` once;
///   • stop hands back the take's identity — THIS view files the `StudioSample` (the recorder owns
///     the file, the view owns naming) and shows an inline rename before Done.
struct StudioMicRecordView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioMicRecorder.self) private var micRecorder
    @Environment(\.dismiss) private var dismiss

    /// Set once a take has been stopped + filed — drives the rename-before-Done state. The id is the
    /// sample already in the store (filed on stop); renaming just updates it.
    @State private var recordedSampleId: String?
    @State private var nameDraft = "Mic recording"

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            content
                .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        // Count this sheet as a presenter (multi-window): the session is torn down only when the
        // LAST mic-record sheet leaves, so a second window's sheet can't kill this capture.
        .onAppear { micRecorder.retainPresenter() }
        // Permission + meter come up on appear; the first run shows the system prompt.
        .task { await micRecorder.beginMonitoring() }
        // Leaving the sheet releases this presenter; the LAST release tears the session down +
        // restores playback. A dismissal MID-TAKE (when this is the last sheet) files the take
        // (default name) inside the recorder — recorded audio is never silently lost.
        .onDisappear { micRecorder.releasePresenter() }
        // A permanent writer death (disk full / folder vanished) auto-stopped + filed the partial
        // take; surface the reason once, then clear it.
        .alert("Recording stopped", isPresented: writerFailureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(micRecorder.writerFailureMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Record sample").font(.headline).foregroundStyle(Theme.fg)
                Text("From \(selectedInputLabel)").font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("mic-source-label")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("mic-cancel")
        }
    }

    /// The selected input's name for the header ("the microphone" / "TX-6") — drives the
    /// "sample from audio in" affordance's copy.
    private var selectedInputLabel: String {
        guard let uid = micRecorder.selectedInputUID,
              let opt = micRecorder.availableInputs.first(where: { $0.id == uid }) else {
            return "the microphone"
        }
        return opt.isLineIn ? opt.name : "the microphone"
    }

    /// Input selector — ALWAYS shown before recording (iOS): a tappable menu when there's more than
    /// one input (built-in mic + external audio-in like a USB-C interface / the TX-6), or a static
    /// chip + a "plug in an interface" hint when only the built-in mic is present. macOS uses the
    /// system default input, so nothing is shown there.
    @ViewBuilder
    private var inputPicker: some View {
        #if os(iOS)
        let inputs = micRecorder.availableInputs
        if inputs.count > 1 {
            Menu {
                ForEach(inputs) { opt in
                    Button {
                        micRecorder.selectInput(uid: opt.id)
                    } label: {
                        Label(opt.name, systemImage: opt.id == micRecorder.selectedInputUID
                              ? "checkmark" : (opt.isLineIn ? "cable.connector" : "mic"))
                    }
                }
            } label: {
                inputChip(name: inputs.first { $0.id == micRecorder.selectedInputUID }?.name ?? "Input",
                          lineIn: selectedInputLabel != "the microphone", tappable: true)
            }
            .accessibilityIdentifier("mic-input-picker")
        } else if let only = inputs.first {
            VStack(spacing: 7) {
                inputChip(name: only.name, lineIn: only.isLineIn, tappable: false)
                if !only.isLineIn {
                    Text("Connect a USB-C audio interface — like your TX-6 — to sample its output instead of the mic.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                        .accessibilityIdentifier("mic-audioin-hint")
                }
            }
        }
        #endif
    }

    private func inputChip(name: String, lineIn: Bool, tappable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: lineIn ? "cable.connector" : "mic")
            Text(name).lineLimit(1)
            if tappable { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tappable ? Theme.accent : Theme.fgDim)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background((tappable ? Theme.accent.opacity(0.15) : Theme.bgOverlay), in: Capsule())
    }

    // MARK: Content (denied → recorded → live)

    @ViewBuilder
    private var content: some View {
        if micRecorder.permissionDenied {
            deniedState
        } else if let id = recordedSampleId {
            recordedState(id)
        } else {
            liveState
        }
    }

    // MARK: Denied

    private var deniedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 36)).foregroundStyle(Theme.fgDim)
            Text("Microphone access is off").font(.headline).foregroundStyle(Theme.fg)
            Text("PocketDJ can’t record without microphone access. Turn it on in Settings, then "
                 + "reopen this sheet.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("mic-denied")
            #if canImport(UIKit)
            Button("Open Settings") { openSettings() }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("mic-open-settings")
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: Live (meter + record/stop)

    private var liveState: some View {
        VStack(spacing: 20) {
            if !micRecorder.isRecording { inputPicker }   // pick mic vs audio-in before recording
            meter
            if micRecorder.isRecording {
                elapsedClock
                if micRecorder.captureStalled {
                    Label("The microphone stopped delivering audio — check the input and hold on.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.accent2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("mic-stalled")
                }
            } else {
                Text("Tap the button to record. Tap again to stop.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            recordButton
        }
        .frame(maxWidth: .infinity)
    }

    /// Input level meter — SAMPLED on a TimelineView (the non-observable `StudioMicLevels` mirror).
    /// A quiet rms bar over a translucent peak bar; both decay to zero when the tap stops firing
    /// (engine parked) so a frozen level never lies about a live input.
    private var meter: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let live = Date().timeIntervalSinceReferenceDate - micRecorder.levels.updatedAt < 0.3
            let peak = live ? CGFloat(min(1, max(0, micRecorder.levels.peak))) : 0
            let rms = live ? CGFloat(min(1, max(0, micRecorder.levels.rms))) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bgOverlay)
                    Capsule().fill(Theme.accent.opacity(0.35))
                        .frame(width: peak * geo.size.width)
                    Capsule().fill(micRecorder.isRecording ? Theme.danger : Theme.accent)
                        .frame(width: rms * geo.size.width)
                }
            }
            .frame(height: 14)
            .accessibilityIdentifier("mic-level-meter")
        }
        .frame(height: 14)
    }

    /// Elapsed clock derived from `startedAtMs` — SAMPLED, never a ticking published property.
    private var elapsedClock: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let sec = max(0, Date().timeIntervalSince1970 - micRecorder.startedAtMs / 1000)
            Text(StudioFmt.clock(sec))
                .font(.title3.monospacedDigit()).foregroundStyle(Theme.fg)
                .accessibilityIdentifier("mic-elapsed")
        }
    }

    private var recordButton: some View {
        Button { toggleRecord() } label: {
            ZStack {
                Circle().strokeBorder(Theme.danger, lineWidth: 3).frame(width: 72, height: 72)
                // Filled circle when idle → morphs to a square while recording (the standard
                // record/stop affordance).
                RoundedRectangle(cornerRadius: micRecorder.isRecording ? 6 : 30, style: .continuous)
                    .fill(Theme.danger)
                    .frame(width: micRecorder.isRecording ? 30 : 56,
                           height: micRecorder.isRecording ? 30 : 56)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mic-record-toggle")
        .accessibilityLabel(micRecorder.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: Recorded (rename → Done)

    private func recordedState(_ id: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36)).foregroundStyle(Theme.accent)
            Text("Recorded").font(.headline).foregroundStyle(Theme.fg)
            TextField("Sample name", text: $nameDraft)
                .pocketField()
                .accessibilityIdentifier("mic-name-field")
            HStack(spacing: 12) {
                Button("Record another") {
                    recordedSampleId = nil
                    nameDraft = micRecorder.defaultRecordingName
                    Task { await micRecorder.beginMonitoring() }   // stop() ended monitoring — re-arm
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("mic-record-another")
                Spacer()
                Button("Done") {
                    let name = nameDraft.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { studio.renameSample(id, to: name) }
                    dismiss()
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("mic-done")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func toggleRecord() {
        if micRecorder.isRecording {
            // Clean stop hands the take back — the VIEW files it (the recorder owns the file, the
            // view owns naming; the recorder-doc contract).
            let source = micRecorder.captureSource   // mic vs the selected audio-in — before stop() resets state
            let fallbackName = micRecorder.defaultRecordingName
            guard let take = micRecorder.stop() else { return }
            let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
            let filedName = trimmed.isEmpty ? fallbackName : trimmed
            studio.addSample(StudioSample(
                id: take.id, name: filedName,
                fileName: take.fileName, wasUserFolder: take.wasUserFolder,
                createdAt: Date().timeIntervalSince1970 * 1000,
                durationMs: take.durationMs, source: source, grid: nil, edit: .neutral))
            recordedSampleId = take.id
            nameDraft = filedName   // the rename field opens on what was just filed
        } else {
            Task { await micRecorder.start() }
        }
    }

    private var writerFailureBinding: Binding<Bool> {
        Binding(get: { micRecorder.writerFailureMessage != nil },
                set: { if !$0 { micRecorder.writerFailureMessage = nil } })
    }

    #if canImport(UIKit)
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    #endif
}
