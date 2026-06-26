#!/usr/bin/env python3
# Beat-grid analysis for ONE audio file — per-beat + downbeat timestamps, grid BPM, and a
# steadiness verdict, for the Mix tab's beat-matching (see
# docs/design/mix-ondevice-tempo-pitch-beatmatch-spec.md §3/§5). librosa-ONLY by design:
# madmom would give a stronger joint beat+downbeat tracker but its pretrained models are
# non-commercial (a shipping-app risk) AND it doesn't install in the pocketdj-audio image,
# so we use librosa.beat_track for the beats + an onset-energy heuristic for the downbeat
# phase. Swap in madmom's DBNDownBeatTrackingProcessor later if licensing is resolved.
#
# Runs inside the pocketdj-audio image (same as analyze-one.py):
#   docker run --rm --entrypoint python -v <dir>:/work pocketdj-audio:latest \
#     /work/analyze-beatgrid.py /work/song.mp3
#
# IMPORTANT: analyze the file from frame 0 — firstDownbeatMs is the phase reference the deck
# seeks to, so for analog we run on the per-song CUT (which starts at 0:00), NOT the album side.
#
# Prints one JSON line:
#   {"ok":true, "firstBeatMs":.., "firstDownbeatMs":.., "beatGridBpm":.., "beatsPerBar":4,
#    "tempoVar":.., "tempoConfidence":.., "gridResidualMs":.., "steady":true|false,
#    "beatsMs":[...], "downbeatsMs":[...]}
import sys, json

# DJ-usable tempo window — fold 2×/0.5× detection errors into here (median dance/pop ~120).
BPM_LO, BPM_HI = 70.0, 180.0
BEATS_PER_BAR = 4


def octave_fold(bpm, lo=BPM_LO, hi=BPM_HI):
    """Halve/double a BPM until it lands in [lo, hi] (kills octave detection errors)."""
    if not (bpm and bpm > 0):
        return bpm
    while bpm < lo:
        bpm *= 2.0
    while bpm > hi:
        bpm /= 2.0
    return bpm


def main():
    path = sys.argv[1]
    try:
        import librosa, numpy as np
        y, sr = librosa.load(path, sr=22050, mono=True)
        n = len(y)
        if n < sr * 2:
            print(json.dumps({"ok": False, "error": "audio too short"}))
            sys.exit(1)

        # Onset envelope (shared by beat tracking AND the downbeat-phase heuristic) + beats.
        onset_env = librosa.onset.onset_strength(y=y, sr=sr, aggregate=np.median)
        _, beats = librosa.beat.beat_track(onset_envelope=onset_env, sr=sr, units="frames")
        beats = np.atleast_1d(beats)
        beats = beats[beats < len(onset_env)]          # guard a trailing off-by-one frame
        if len(beats) < 8:
            print(json.dumps({"ok": False, "error": "too few beats"}))
            sys.exit(1)
        beats_ms = librosa.frames_to_time(beats, sr=sr) * 1000.0

        # Robust period from the MEDIAN inter-beat interval, ignoring outliers (a dropped beat
        # gives a ~2× IBI, an extra beat a ~0.5× one — neither is tempo instability). Steadiness
        # is then how tightly the CLEAN intervals hold that period (RMS deviation) plus the BPM
        # spread — both local measures, robust to occasional missed/extra detections (which a
        # global index-fit can't handle without mis-assigning indices over a long track).
        ibis = np.diff(beats_ms)
        ibis = ibis[ibis > 0]
        med = float(np.median(ibis)) if len(ibis) else 0.0
        clean = ibis[(ibis > 0.5 * med) & (ibis < 1.5 * med)] if med > 0 else ibis
        period = float(np.median(clean)) if len(clean) else med

        grid_bpm = octave_fold(60000.0 / period) if period > 0 else 0.0
        grid_residual_ms = float(np.sqrt(np.mean((clean - period) ** 2))) if len(clean) else 999.0
        inst_bpm = 60000.0 / clean if len(clean) else np.array([grid_bpm])
        tempo_var = float(np.std(inst_bpm))

        # Downbeat phase (4/4 assumed): the beat-of-bar whose beats carry the most onset energy
        # on average is beat 1. onset_env indexed at the beat frames.
        beat_strength = onset_env[beats]
        best_phase, best_score = 0, -1.0
        for p in range(BEATS_PER_BAR):
            sel = beat_strength[p::BEATS_PER_BAR]
            score = float(np.mean(sel)) if len(sel) else -1.0
            if score > best_score:
                best_score, best_phase = score, p
        downbeats_ms = beats_ms[best_phase::BEATS_PER_BAR]

        # Confidence + steadiness keyed on the (tempo-independent) ms grid residual. tempoVar
        # scales with bpm² under fixed frame quantization (hop 512 @ 22.05 kHz ≈ 23 ms/beat), so
        # even a metronome-perfect fast track shows several bpm of jitter — it's only a loose
        # gross-instability backstop here, NOT the primary gate.
        tempo_confidence = max(0.0, min(1.0, 1.0 - grid_residual_ms / 40.0))
        steady = bool(grid_residual_ms < 30.0 and tempo_var < 8.0)

        print(json.dumps({
            "ok": True,
            "firstBeatMs": int(round(float(beats_ms[0]))),
            "firstDownbeatMs": int(round(float(downbeats_ms[0]))),
            "beatGridBpm": round(float(grid_bpm), 2),
            "beatsPerBar": BEATS_PER_BAR,
            "tempoVar": round(tempo_var, 3),
            "tempoConfidence": round(tempo_confidence, 3),
            "gridResidualMs": round(grid_residual_ms, 1),
            "steady": steady,
            "beatsMs": [int(round(float(b))) for b in beats_ms],
            "downbeatsMs": [int(round(float(d))) for d in downbeats_ms],
        }))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)


main()
