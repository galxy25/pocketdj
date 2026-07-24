import SwiftUI

// MARK: - Reusable Studio mixer deck (B6 — SAMP + SEQ3)

/// A reusable "mixer deck" control surface over a `StudioSampleEdit`: the deck-styled voicing
/// (tempo / pitch / gain + a compressor · reverb · delay · filter FX rack + an optional live
/// looper) shared by the **sampler editor** (SAMP) and the **sequencer's per-row deck** (SEQ3).
///
/// It forks the F4 `NowPlayingDSP` control model (same effect voicings, the sampler's own
/// `StudioEngine` chain — never `MixEngine`, so opening it can't collide with a live Mix-tab
/// session). It is a PURE control surface: it holds no engine reference. The host wires:
///   • `onEdit` → its both-ways write (`engine.applyEdit` live + `studio.updateSampleEdit`
///     persist, which bumps the render revision so the bake — and any sequencer row using this
///     sample — inherits the change on the next render);
///   • `onLoop` → the engine's EPHEMERAL loop-audition.
///
/// The tempo / pitch / gain / FX PERSIST and BAKE (the sampler's non-destructive contract — you
/// don't lose tweaks, and a sequencer row bakes them into its row buffer). The **looper is
/// live-only** and resets when the editor closes — the "ephemeral" half of the deck.
struct StudioMixerDeck: View {
    /// The sample's current non-destructive edit (source of truth lives in the host's store).
    let edit: StudioSampleEdit
    /// Show the Gain slider. SAMP: true. SEQ3 per-row: false — a row already has its own LIVE gain
    /// chip (`RowGainChip`), so a second baked gain here would just confuse.
    var showGain: Bool = true
    /// Show the live looper capsule. SAMP: true. SEQ3 per-row: false (a row loops via the pattern,
    /// and the looper is an ephemeral audition tool with no per-row meaning).
    var showLooper: Bool = true
    /// The engine's current loop-audition state (the capsule reflects it; the host owns the flag).
    var loopOn: Bool = false
    /// Distinguishes accessibility ids when several decks are on screen (one per sequencer row).
    var idPrefix: String = "mixdeck"
    /// One mutation of the edit, applied by the host both ways (live chain + store).
    var onEdit: (StudioSampleEdit) -> Void
    /// Toggle the live looper (SAMP only).
    var onLoop: (Bool) -> Void = { _ in }

    /// Copy-mutate-emit: each control edits a fresh copy and hands the whole edit back, so the host
    /// has a single choke-point (clamp · live-apply · persist) regardless of which knob moved.
    private func mut(_ f: (inout StudioSampleEdit) -> Void) {
        var e = edit; f(&e); onEdit(e)
    }
    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Transport-shaping trio.
            StudioEditSlider(title: "Tempo", systemImage: "hare", range: 0.5...2.0, step: 0.05,
                             value: edit.rate, format: { String(format: "×%.2f", $0) },
                             a11y: "\(idPrefix)-tempo") { v in mut { $0.rate = v } }
            StudioEditSlider(title: "Pitch", systemImage: "tuningfork", range: -12...12, step: 1,
                             value: edit.pitchSemitones, format: { String(format: "%+.0f st", $0) },
                             a11y: "\(idPrefix)-pitch") { v in mut { $0.pitchSemitones = v } }
            if showGain {
                StudioEditSlider(title: "Gain", systemImage: "speaker.wave.2", range: -60...12, step: 1,
                                 value: edit.gainDb, format: { String(format: "%+.0f dB", $0) },
                                 a11y: "\(idPrefix)-gain") { v in mut { $0.gainDb = v } }
            }

            Divider().overlay(Theme.border)
            Text("FX").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)

            StudioEditSlider(title: "Compressor", systemImage: "waveform.path.ecg", range: 0...1, step: 0.05,
                             value: edit.compWet, format: pct,
                             a11y: "\(idPrefix)-comp") { v in mut { $0.compWet = v } }
            StudioEditSlider(title: "Reverb", systemImage: "water.waves", range: 0...1, step: 0.05,
                             value: edit.reverbWet, format: pct,
                             a11y: "\(idPrefix)-reverb") { v in mut { $0.reverbWet = v } }
            StudioEditSlider(title: "Delay", systemImage: "wave.3.right", range: 0...1, step: 0.05,
                             value: edit.delayWet, format: pct,
                             a11y: "\(idPrefix)-delay") { v in mut { $0.delayWet = v } }
            StudioEditSlider(title: "Filter", systemImage: "line.3.horizontal.decrease.circle", range: 0...1, step: 0.05,
                             value: edit.filterAmt, format: pct,
                             a11y: "\(idPrefix)-filter") { v in mut { $0.filterAmt = v } }

            if showLooper {
                Divider().overlay(Theme.border)
                Button { onLoop(!loopOn) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                        Text(loopOn ? "Looping" : "Loop")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(loopOn ? Theme.bg : Theme.fg)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(loopOn ? Theme.accent2 : Theme.bgOverlay, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix)-loop")
                .accessibilityLabel(loopOn ? "Looping — tap to stop looping" : "Loop the trim window")
            }
        }
    }
}
