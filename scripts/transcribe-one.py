#!/usr/bin/env python3
# Timed-lyrics transcription for ONE audio file (a Demucs VOCALS stem) via faster-whisper.
# Mirrors analyze-one.py / separate-one.py: one path arg, prints ONE JSON line (the last
# non-empty stdout line is what the caller — stem-worker.mjs runPyJson — parses). Model /
# device / compute come from the environment so the SAME script serves CPU int8 on the
# m7i.large fleet today and a GPU float16 worker once the quota lands.
#   LYRICS_MODEL=small LYRICS_DEVICE=cpu LYRICS_COMPUTE=int8 python transcribe-one.py vocals.mp3
# Prints: {"version":1,"model":"faster-whisper-small","lang":"en","durationMs":215000,
#          "words":[{"text":"hello","startMs":1200,"endMs":1440}, ...]}
# The vocals stem is CUT-derived (song-relative), so word timestamps need no extra offset.
import sys, os, json

VERSION = 1


def main():
    src = sys.argv[1]
    model_size = os.environ.get("LYRICS_MODEL", "small")
    device = os.environ.get("LYRICS_DEVICE", "cpu")
    compute = os.environ.get("LYRICS_COMPUTE", "int8")
    try:
        from faster_whisper import WhisperModel
        model = WhisperModel(model_size, device=device, compute_type=compute)
        # word_timestamps → per-word start/end; vad_filter drops the silence between phrases
        # that a vocals stem is mostly made of (faster + fewer hallucinated words).
        segments, info = model.transcribe(src, word_timestamps=True, vad_filter=True)
        words = []
        prev = 0                                  # clamp starts monotonically non-decreasing
        for seg in segments:                      # iterating the generator runs the transcription
            for w in (seg.words or []):
                text = (w.word or "").strip()
                if not text:
                    continue
                s = int(round((w.start or 0) * 1000))
                e = int(round((w.end or 0) * 1000))
                if s < prev:
                    s = prev
                if e < s:
                    e = s
                words.append({"text": text, "startMs": s, "endMs": e})
                prev = s
        lang = info.language or None
        duration_ms = int(round(info.duration * 1000)) if info.duration else None
        print(json.dumps({"version": VERSION, "model": f"faster-whisper-{model_size}",
                          "lang": lang, "durationMs": duration_ms, "words": words},
                         ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)


main()
