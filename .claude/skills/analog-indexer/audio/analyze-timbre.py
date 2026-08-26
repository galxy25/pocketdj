#!/usr/bin/env python3
# TIMBRE features for ONE audio file — the "musicality" vector the recommendation engine scores
# against, alongside the bpm/key that analyze-one.py already produces.
#
#   docker run --rm --entrypoint python -v <dir>:/work pocketdj-audio:latest \
#     /work/analyze-timbre.py /work/song.mp3
#
# Prints one JSON line: {"ok":true,"v":1,"f":{...}} where every value in `f` is a scalar already
# NORMALIZED to roughly 0…1 on real music, so the engine can take a plain distance between two
# vectors without carrying a per-feature scaler. Raw units would make centroid (hundreds of Hz)
# swamp flatness (1e-3) in any euclidean metric; normalizing at extraction time keeps that
# decision in ONE place instead of duplicated in the Lambda and on device.
#
# WHY THESE EIGHT AND NOT THIRTEEN MFCCs: MFCC coefficients are a basis, not a description — a
# listener cannot tell you what mfcc7 means, and neither can a "why we picked this" line in the UI.
# Each axis here is something a person can name: bright/dark, dense/sparse, tonal/noisy, punchy/
# smooth, busy/still, loud-flat/dynamic. That matters because a thumbs-down has to be explainable.
# mfcc1..4 ride along as an unnamed timbre residual (the coarse spectral envelope shape) precisely
# because the named axes do NOT capture vowel-ish/instrumentation colour on their own.
#
# BOUNDED like analyze-one.py: same 90 s representative window from the same 5 % offset, so a
# timbre vector and a bpm/key from the same file describe the same stretch of audio.
#
# A capture this file cannot honestly describe is REJECTED — `too-short`, `silent`,
# `degenerate-axes`, `non-finite-axis` — never emitted as a vector full of nulls or rail-pinned
# zeros. Those four reasons are exactly the ones scripts/timbre-batch.mjs treats as PERMANENT;
# anything else it sees is the environment and stays retryable.
import sys, json, math

WIN_SEC = 90
SR = 22050

# A window carrying no signal is not a quiet record, it is a FAILED capture: both axes that are
# RATIOS (percussive share, crest factor) divide by the energy in this window, so at zero energy
# they are undefined, `norm()` hands back None, and the row ships with null axes — a shape the
# 14-finite-numbers contract forbids and every reader downstream then has to defend against. Two
# rows of the shipping corpus (sng_e063cda2d69b, sng_9ed699c0dd1f) are exactly this: hpss energy
# AND rms_mean both literally 0. Reject at the source, the way `too-short` already is.
SILENT_RMS = 1e-4
# …and a vector that came back mostly pinned at a rail is the same failure wearing a different
# hat: 32 rows of the shipping corpus carry 7+ axes at exactly 0.0 and read as MUTUALLY similar
# because they are all the same degenerate point, not because they sound alike.
MAX_ZERO_AXES = 7


def norm(x, lo, hi):
    """Clamp-and-scale to 0…1. lo/hi are the 1st/99th percentile of the real catalog, not the
    theoretical range — a theoretical range compresses every real song into a sliver. Returns None
    only for an input that is not a finite number; the contract check below then rejects the whole
    capture rather than shipping a vector with a hole in it."""
    if x is None:
        return None
    x = float(x)
    if not math.isfinite(x):
        return None
    v = (x - lo) / (hi - lo)
    return round(max(0.0, min(1.0, v)), 4)


def fail(err):
    print(json.dumps({"ok": False, "error": err}))
    sys.exit(1)


def main():
    path = sys.argv[1]
    try:
        import librosa, numpy as np

        y, sr = librosa.load(path, sr=SR, mono=True)
        n = len(y)
        off = min(int(n * 0.05), 5 * sr)
        win = WIN_SEC * sr
        aw = y[off:off + win] if n > off else y
        if aw.size < sr:                       # under a second of audio — nothing to describe
            fail("too-short")

        S = np.abs(librosa.stft(aw, n_fft=2048, hop_length=512))

        cent = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
        roll = librosa.feature.spectral_rolloff(S=S, sr=sr, roll_percent=0.85)[0]
        band = librosa.feature.spectral_bandwidth(S=S, sr=sr)[0]
        flat = librosa.feature.spectral_flatness(S=S)[0]
        zcr = librosa.feature.zero_crossing_rate(aw, hop_length=512)[0]
        rms = librosa.feature.rms(S=S)[0]

        # Harmonic / percussive split — "punch". A drum-forward record and a pad-forward record can
        # sit on the same centroid; this is the axis that tells them apart.
        H, P = librosa.decompose.hpss(S)
        h_e = float(np.sum(H ** 2))
        p_e = float(np.sum(P ** 2))

        # ── SILENT CAPTURE = A FAILED CAPTURE, NOT A QUIET RECORD ───────────────────────────
        # This gate has to run BEFORE anything divides by the window's energy. It is the one place
        # that knows the difference between "no signal" and "a vector".
        rms_mean = float(np.mean(rms))
        if not math.isfinite(rms_mean) or rms_mean < SILENT_RMS or (h_e + p_e) <= 0:
            fail("silent")

        perc = p_e / (h_e + p_e) if (h_e + p_e) > 0 else None

        # Onset density — events per second, i.e. how BUSY the arrangement is, independent of tempo
        # (a half-time 140 bpm record and a busy 140 bpm record differ here and nowhere else).
        onsets = librosa.onset.onset_detect(y=aw, sr=sr, units="time")
        dur = len(aw) / sr
        onset_rate = (len(onsets) / dur) if dur > 0 else None

        # Loudness dynamics — crest factor over the RMS envelope. A brickwalled master sits near 1;
        # a record that breathes sits well above it. (`rms_mean` was needed earlier, for the
        # silence gate — the one check that has to run before any ratio divides by it.)
        rms_max = float(np.max(rms))
        crest = (rms_max / rms_mean) if rms_mean > 0 else None

        mf = librosa.feature.mfcc(S=librosa.power_to_db(S ** 2), n_mfcc=5)

        # ── THE lo/hi TABLE IS MEASURED, NOT GUESSED ────────────────────────────────────────────
        # Every pair below is the p02/p98 of the RAW value over a 76-song sample of the owner's
        # own ripped catalog (10 artists across rock / r&b / electronic / jazz / hip-hop), dumped
        # from the raw blocks. The first cut of this file used plausible textbook ranges and three axes
        # came back DEAD: m1 pinned at 1.0 for 88 % of songs, m3 for 66 %, `punch` at a rail for
        # 14 %. A saturated axis is not a weak feature, it is a MISSING one — every song scores
        # the same, so it contributes exactly zero to any distance while still costing a slot in
        # the vector. Re-derive from the stored `r` blocks (data/timbre-raw.json) if the
        # collection's centre of gravity moves; bump TIMBRE_VERSION in
        # scripts/lib/audio-analyze.mjs when you do, so every consumer refuses to mix two
        # calibrations in one corpus — and re-measure the decay, the admission margin and the
        # spread bar at the same time, because the rails ARE the units those are expressed in.
        f = {
            # NAMED axes ─ each one is a sentence a person could say about the record.
            "bright": norm(np.mean(cent), 1200, 6200),         # spectral centroid, Hz
            "brightVar": norm(np.std(cent), 350, 1850),        # how much the brightness moves
            "air": norm(np.mean(roll), 2500, 10000),           # 85 % rolloff, Hz — top-end extension
            "width": norm(np.mean(band), 1700, 3300),          # spectral bandwidth, Hz
            "noisy": norm(np.mean(flat), 0.003, 0.25),         # flatness — tonal ↔ noise-like
            "fizz": norm(np.mean(zcr), 0.04, 0.50),            # zero-crossing rate
            "punch": norm(perc, 0.02, 0.95),                   # percussive share of energy
            "busy": norm(onset_rate, 0.2, 6.0),                # onsets per second
            # Crest is heavily right-skewed (p50 3.0, p98 42) — the tail is near-silent captures,
            # not dynamic masters, so the hi is set at the top of the MUSICAL range and the tail
            # clamps rather than compressing every real record into the bottom eighth.
            "dynamic": norm(crest, 2.0, 8.0),                  # RMS crest factor
            "loud": norm(rms_mean, 0.0, 0.22),                 # average level
            # Unnamed spectral-envelope residual (mfcc1..4, dropping mfcc0 = level, already `loud`).
            "m1": norm(np.mean(mf[1]), 0, 330),
            "m2": norm(np.mean(mf[2]), -35, 105),
            "m3": norm(np.mean(mf[3]), 0, 120),
            "m4": norm(np.mean(mf[4]), -55, 45),
        }
        # ── THE CONTRACT, CHECKED HERE AND NOWHERE ELSE ─────────────────────────────────────
        # "14 finite numbers, or nothing." A row that fails this is not a weak measurement, it is
        # a measurement that did not happen — and it is worse than a missing row, because the
        # corpus cannot tell the two apart and every degenerate row reads as the nearest neighbour
        # of every other degenerate row. Rejecting leaves the song retryable-and-absent instead.
        if any(v is None for v in f.values()):
            fail("non-finite-axis")
        if sum(1 for v in f.values() if v == 0.0) >= MAX_ZERO_AXES:
            fail("degenerate-axes")

        out = {"ok": True, "v": 1, "durationSec": round(n / sr, 1), "f": f}
        # ── THE RAW MEASUREMENTS RIDE ALONG, ALWAYS ─────────────────────────────────────────
        # Normalization is a pure affine clamp, so keeping the raw values makes a future rail
        # recalibration a RE-NORMALISATION (arithmetic on numbers already taken) instead of a
        # RE-EXTRACTION (15k songs × ~3.5 s of librosa, and 10,388 of them behind a removable
        # volume no cloud worker can mount). This used to sit behind `--raw`, which is exactly
        # why the shipped corpus was built without it and why a calibration derived from 76
        # songs stayed in force while the corpus grew 200× — moving it cost hours nobody had.
        #
        # It is 14 floats. `fold-timbre.mjs` keeps them OUT of the published corpus and folds
        # them into data/timbre-raw.json, so no device downloads a byte of this.
        out["r"] = {
            "cent": float(np.mean(cent)), "centStd": float(np.std(cent)),
            "roll": float(np.mean(roll)), "band": float(np.mean(band)),
            "flat": float(np.mean(flat)), "zcr": float(np.mean(zcr)),
            "perc": perc, "onsetRate": onset_rate, "crest": crest, "rms": rms_mean,
            "m1": float(np.mean(mf[1])), "m2": float(np.mean(mf[2])),
            "m3": float(np.mean(mf[3])), "m4": float(np.mean(mf[4])),
        }
        print(json.dumps(out))
    except Exception as exc:                                    # noqa: BLE001 — best-effort stage
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)


main()
