#!/usr/bin/env python3
# Single-file BPM + musical-key (+ Camelot) detection for ONE audio file. Reuses the
# catalog's algorithm (Krumhansl-Schmuckler key profiles + librosa beat-track), bounded
# to a representative window so it's fast per song. Runs inside the pocketdj-audio image:
#   docker run --rm --entrypoint python -v <dir>:/work pocketdj-audio:latest \
#     /work/analyze-one.py /work/song.mp3
# Prints one JSON line: {"bpm":.., "key":.., "camelot":.., "keyStrength":.., "durationSec":.., "ok":true}
import sys, json

KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
CAMELOT = {
    "C major": "8B", "G major": "9B", "D major": "10B", "A major": "11B", "E major": "12B",
    "B major": "1B", "F# major": "2B", "C# major": "3B", "G# major": "4B", "D# major": "5B",
    "A# major": "6B", "F major": "7B",
    "A minor": "8A", "E minor": "9A", "B minor": "10A", "F# minor": "11A", "C# minor": "12A",
    "G# minor": "1A", "D# minor": "2A", "A# minor": "3A", "F minor": "4A", "C minor": "5A",
    "G minor": "6A", "D minor": "7A",
}


def detect_key(chroma_mean):
    import numpy as np
    maj_p = np.array(KS_MAJOR) - np.mean(KS_MAJOR)
    min_p = np.array(KS_MINOR) - np.mean(KS_MINOR)
    best = (-2.0, "C", "major")
    cm = chroma_mean - chroma_mean.mean()
    for i in range(12):
        maj = np.corrcoef(cm, np.roll(maj_p, i))[0, 1]
        if maj > best[0]:
            best = (maj, PITCHES[i], "major")
        mino = np.corrcoef(cm, np.roll(min_p, i))[0, 1]
        if mino > best[0]:
            best = (mino, PITCHES[i], "minor")
    strength, tonic, mode = best
    name = f"{tonic} {mode}"
    return name, CAMELOT.get(name, ""), round(float(strength), 3)


def main():
    path = sys.argv[1]
    try:
        import librosa, numpy as np
        y, sr = librosa.load(path, sr=22050, mono=True)
        n = len(y)
        # representative window: skip the first ~5% (intro), cap at 90s — BPM/key are
        # stable within a song, so this bounds CPU without hurting accuracy.
        off = min(int(n * 0.05), 5 * sr)
        win = 90 * sr
        aw = y[off:off + win] if n > off else y
        tempo = librosa.beat.beat_track(y=aw, sr=sr)[0]
        bpm = round(float(np.atleast_1d(tempo)[0]), 1)
        chroma = librosa.feature.chroma_cqt(y=aw, sr=sr).mean(axis=1)
        key_name, camelot, strength = detect_key(chroma)
        print(json.dumps({"bpm": bpm, "key": key_name, "camelot": camelot,
                          "keyStrength": strength, "durationSec": round(n / sr, 1), "ok": True}))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)


main()
