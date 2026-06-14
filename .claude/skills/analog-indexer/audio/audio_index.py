#!/usr/bin/env python3
"""
PocketDJ AUDIO indexer — the [4] audio stage of the analog indexer.

Runs OUT OF BAND from the app (dev machine now, cloud server later). For each vinyl
album rip it: copies the file to a local work dir, segments it into songs using a
silence/RMS waveform heuristic, and runs BPM + musical-key (+ Camelot) detection on
each segment with librosa. Writes a per-album audio record to an append-only JSONL
shard, then **deletes the copied file and any segment files** so it never eats disk.

Audio analysis can DISAGREE with the album/track metadata (different track counts), so
segments are stored independently (album.audioTracks); per-song bpm/key are also filled
by order where they line up, for sorting.

Design goals (per the spec):
  - copy album -> work dir -> segment -> bpm+key per song -> idempotent update -> CLEANUP
  - tunable PARALLELISM (--concurrency / AUDIO_CONC) to trade throughput vs. host load
  - progressive + idempotent: skip albums already in --out; append per album as it finishes

Usage:
  .venv-audio/bin/python audio_index.py \
    --index index-out/current/index.json --vinyl-dir /Volumes/RipBurnMix \
    --out index-out/shards-pw/audio.jsonl --concurrency 4 [--limit N] [--slice A:B]
    [--work-dir ~/Downloads/pdj-audio-work] [--write-segments] [--keep] [--sr 22050]
    [--top-db 35] [--min-gap 1.4] [--min-track 25]
"""
import argparse
import json
import os
import shutil
import sys
import time
import traceback
from concurrent.futures import as_completed

# NOTE: numpy/librosa are imported LAZILY inside the worker functions only. The
# ORCHESTRATOR process must NOT import numpy — a parent with numpy/OpenBLAS threads
# loaded crashes the python subprocesses it spawns (segfault on import). Keeping the
# orchestrator numpy-free makes every isolated worker subprocess start clean.

# ----------------------------------------------------------------- key detection
# Krumhansl-Schmuckler key profiles (major/minor), correlated against the mean chroma.
KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Camelot wheel codes (DJ harmonic mixing): B = major, A = minor.
CAMELOT = {
    "C major": "8B", "G major": "9B", "D major": "10B", "A major": "11B", "E major": "12B",
    "B major": "1B", "F# major": "2B", "C# major": "3B", "G# major": "4B", "D# major": "5B",
    "A# major": "6B", "F major": "7B",
    "A minor": "8A", "E minor": "9A", "B minor": "10A", "F# minor": "11A", "C# minor": "12A",
    "G# minor": "1A", "D# minor": "2A", "A# minor": "3A", "F minor": "4A", "C minor": "5A",
    "G minor": "6A", "D minor": "7A",
}


def detect_key(chroma_mean):
    """Return (key_name, camelot, strength) via KS-profile correlation over 12 rotations."""
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


# ----------------------------------------------------------------- segmentation
def segment_bounds(y, sr, top_db, min_gap_s, min_track_s):
    """Silence/RMS heuristic: non-silent intervals (librosa.effects.split), bridge
    short within-song gaps, drop too-short fragments. Returns [(start,end)] in samples."""
    import librosa

    intervals = librosa.effects.split(y, top_db=top_db)
    if len(intervals) == 0:
        return [(0, len(y))]
    min_gap = int(min_gap_s * sr)
    merged = []
    for s, e in intervals:
        if merged and s - merged[-1][1] < min_gap:
            merged[-1][1] = e  # bridge a short (within-song) gap
        else:
            merged.append([s, e])
    min_track = int(min_track_s * sr)
    segs = [(int(s), int(e)) for s, e in merged if (e - s) >= min_track]
    if not segs:  # fall back to the whole thing rather than nothing
        segs = [(0, len(y))]
    return segs


# ----------------------------------------------------------------- per-album worker
def analyze_album(task):
    """Runs in a worker process. Copy -> load -> segment -> bpm/key -> CLEANUP. Always
    cleans up the copied file + any segment files, even on error."""
    import librosa
    import numpy as np

    album_id = task["albumId"]
    src = task["src"]
    work_dir = task["work_dir"]
    p = task["params"]
    copied = None
    seg_files = []
    t0 = time.time()
    try:
        os.makedirs(work_dir, exist_ok=True)
        # 1) copy the album file local (avoid hammering the external/remote drive)
        copied = os.path.join(work_dir, f"{album_id}__{os.path.basename(src)}")
        shutil.copyfile(src, copied)
        # 2) decode to mono at the analysis sample rate
        y, sr = librosa.load(copied, sr=p["sr"], mono=True)
        dur = len(y) / sr
        # 3) segment into songs
        bounds = segment_bounds(y, sr, p["top_db"], p["min_gap"], p["min_track"])
        segments = []
        win = p["window"]  # samples; 0 = whole segment
        for i, (s, e) in enumerate(bounds):
            if p["write_segments"]:
                import soundfile
                sf = os.path.join(work_dir, f"{album_id}__seg{i:02d}.wav")
                soundfile.write(sf, y[s:e], sr)
                seg_files.append(sf)
            # Analysis WINDOW: BPM + key are stable within a song, so a bounded slice
            # (start a little in, capped at `win`) is representative AND bounds memory/CPU
            # so chroma/beat never run on a 20-min block (which OOM-killed the pool worker).
            off = s + min(int((e - s) * 0.1), int(5 * sr))
            a_end = min(e, off + win) if win > 0 else e
            aw = y[off:a_end]
            tempo = librosa.beat.beat_track(y=aw, sr=sr)[0]
            bpm = float(np.atleast_1d(tempo)[0])
            chroma = librosa.feature.chroma_cqt(y=aw, sr=sr).mean(axis=1)
            key_name, camelot, strength = detect_key(chroma)
            segments.append({
                "i": i,
                "startMs": int(round(s / sr * 1000)),
                "endMs": int(round(e / sr * 1000)),
                "durationMs": int(round((e - s) / sr * 1000)),
                "bpm": round(bpm, 1),
                "key": key_name,
                "camelot": camelot,
                "keyStrength": strength,
            })
        return {
            "albumId": album_id,
            "originalFilename": os.path.basename(src),
            "durationSec": round(dur, 1),
            "segments": segments,
            "analyzeSec": round(time.time() - t0, 1),
            "ok": True,
        }
    except Exception as exc:  # never let one album kill the pool
        return {"albumId": album_id, "originalFilename": os.path.basename(src), "ok": False,
                "error": f"{type(exc).__name__}: {exc}", "trace": traceback.format_exc()[-500:]}
    finally:
        # 4) CLEANUP — copied album + any segment files, always.
        for f in [copied, *seg_files]:
            try:
                if f and os.path.exists(f):
                    os.remove(f)
            except OSError:
                pass


# ----------------------------------------------------------------- worker isolation
import glob
import subprocess
from concurrent.futures import ThreadPoolExecutor


def cleanup_album(work_dir, album_id):
    """Remove any leftover copied file / segments for this album (belt-and-suspenders:
    runs even if a worker subprocess was killed before its own finally block)."""
    for f in glob.glob(os.path.join(work_dir, f"{album_id}__*")):
        try:
            os.remove(f)
        except OSError:
            pass


def process_one(args, album_id, src):
    """Analyze ONE album in an ISOLATED subprocess so a native librosa segfault (or a
    hang) fails just this album instead of taking down a shared process pool. Always
    cleans up the work dir for this album afterward."""
    cmd = [sys.executable, os.path.abspath(__file__),
           "--analyze-id", album_id, "--analyze-src", src,
           "--work-dir", args.work_dir, "--sr", str(args.sr),
           "--top-db", str(args.top_db), "--min-gap", str(args.min_gap),
           "--min-track", str(args.min_track), "--window-sec", str(args.window_sec)]
    if args.write_segments and not args.keep:
        cmd.append("--write-segments")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
        if p.returncode == 0 and p.stdout.strip():
            return json.loads(p.stdout)
        why = "segfault/abort" if p.returncode and p.returncode < 0 else f"exit {p.returncode}"
        return {"albumId": album_id, "originalFilename": os.path.basename(src), "ok": False,
                "error": f"worker {why}: {(p.stderr or '').strip()[-180:]}"}
    except subprocess.TimeoutExpired:
        return {"albumId": album_id, "originalFilename": os.path.basename(src), "ok": False,
                "error": f"timeout >{args.timeout}s"}
    except Exception as exc:  # noqa: BLE001
        return {"albumId": album_id, "originalFilename": os.path.basename(src), "ok": False,
                "error": f"{type(exc).__name__}: {exc}"}
    finally:
        if not args.keep:
            cleanup_album(args.work_dir, album_id)


def run_worker(args):
    """Subprocess entry: analyze the single album and print its JSON record to stdout."""
    params = {"sr": args.sr, "top_db": args.top_db, "min_gap": args.min_gap,
              "min_track": args.min_track, "window": int(args.window_sec * args.sr),
              "write_segments": args.write_segments}
    rec = analyze_album({"albumId": args.analyze_id, "src": args.analyze_src,
                         "work_dir": args.work_dir, "params": params})
    sys.stdout.write(json.dumps(rec))
    sys.stdout.flush()


# ----------------------------------------------------------------- main / orchestration
def load_done(out_path):
    done = set()
    if os.path.exists(out_path):
        with open(out_path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    if rec.get("albumId"):
                        done.add(rec["albumId"])
                except json.JSONDecodeError:
                    pass
    return done


def main():
    ap = argparse.ArgumentParser(description="PocketDJ audio indexer (segment + BPM + key)")
    ap.add_argument("--index", required=True, help="index.json (albums w/ pointer.originalFilename)")
    ap.add_argument("--vinyl-dir", required=True, help="dir with the raw album files")
    ap.add_argument("--out", required=True, help="append-only audio.jsonl shard")
    ap.add_argument("--work-dir", default=os.path.expanduser("~/Downloads/pdj-audio-work"))
    ap.add_argument("--concurrency", type=int, default=int(os.environ.get("AUDIO_CONC", "3")),
                    help="albums analyzed in parallel (trade throughput vs host load)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--slice", default="", help="A:B over the todo list")
    ap.add_argument("--only", default="", help="comma-sep albumIds (overrides selection)")
    # Shard the todo across parallel CONTAINERS (each its own process namespace, conc 1)
    # — librosa/OpenBLAS races + segfaults under in-process concurrency, so we parallelize
    # at the container level instead.
    ap.add_argument("--shard", type=int, default=0)
    ap.add_argument("--num-shards", type=int, default=1)
    ap.add_argument("--sr", type=int, default=22050)
    ap.add_argument("--top-db", type=float, default=24.0, help="silence threshold below peak (lower = more splits)")
    ap.add_argument("--min-gap", type=float, default=0.8, help="min inter-track silence to split on (s)")
    ap.add_argument("--min-track", type=float, default=40.0, help="drop/merge segments shorter than (s)")
    ap.add_argument("--window-sec", type=float, default=90.0, help="seconds of each segment to analyze (0=all)")
    ap.add_argument("--timeout", type=int, default=300, help="per-album wall-clock cap (s)")
    ap.add_argument("--write-segments", action="store_true", help="also write per-song wavs (cleaned up)")
    ap.add_argument("--keep", action="store_true", help="don't clean up (debugging)")
    # internal: isolated single-album worker invocation
    ap.add_argument("--analyze-id", default="", help=argparse.SUPPRESS)
    ap.add_argument("--analyze-src", default="", help=argparse.SUPPRESS)
    # --index/--vinyl-dir/--out are not needed in worker mode
    for a in ap._actions:
        if a.dest in ("index", "vinyl_dir", "out"):
            a.required = False
    args = ap.parse_args()

    # Worker mode: analyze one album, print its record, exit (crash-isolated).
    if args.analyze_id and args.analyze_src:
        run_worker(args)
        return

    if not (args.index and args.vinyl_dir and args.out):
        ap.error("--index, --vinyl-dir and --out are required")

    with open(args.index) as fh:
        index = json.load(fh)

    done = load_done(args.out)
    only = set(x for x in args.only.split(",") if x)
    todo = []
    idx = -1  # STABLE position among albums-that-have-a-file (resume-safe shard assignment)
    for a in index["albums"]:
        fn = (a.get("pointer") or {}).get("originalFilename")
        if not fn:
            continue
        src = os.path.join(args.vinyl_dir, fn)
        if not os.path.exists(src):
            continue
        idx += 1
        if only:
            if a["id"] not in only:
                continue
        else:
            if args.num_shards > 1 and (idx % args.num_shards) != args.shard:
                continue
            if a["id"] in done:
                continue
        todo.append({"albumId": a["id"], "src": src})

    if args.slice:
        x, _, z = args.slice.partition(":")
        todo = todo[int(x or 0): int(z) if z else None]
    if args.limit > 0:
        todo = todo[: args.limit]

    params = {"sr": args.sr, "top_db": args.top_db, "min_gap": args.min_gap,
              "min_track": args.min_track, "window_sec": args.window_sec}

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    os.makedirs(args.work_dir, exist_ok=True)
    sys.stderr.write(
        f"audio: {len(todo)} albums to analyze (skipping {len(done)} done) · "
        f"concurrency={args.concurrency} · sr={args.sr} top_db={args.top_db}\n")
    sys.stderr.flush()

    t0 = time.time()
    done_n = 0
    seg_total = 0
    failed = 0
    out_fh = open(args.out, "a")
    try:
        # Each album runs in its OWN subprocess (process_one); a ThreadPool just bounds
        # how many run at once. A native segfault/hang fails only that album.
        with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
            futs = {ex.submit(process_one, args, t["albumId"], t["src"]): t for t in todo}
            for fut in as_completed(futs):
                rec = fut.result()
                rec["analyzedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                rec["params"] = params
                out_fh.write(json.dumps(rec) + "\n")
                out_fh.flush()
                done_n += 1
                if rec.get("ok"):
                    seg_total += len(rec.get("segments", []))
                else:
                    failed += 1
                    sys.stderr.write(f"  ✗ {rec['albumId']} {rec.get('error','')}\n")
                if done_n % 5 == 0 or done_n == len(todo):
                    el = time.time() - t0
                    rate = done_n / el * 3600 if el else 0
                    sys.stderr.write(
                        f"  audio {done_n}/{len(todo)} · {seg_total} segments · {failed} failed · "
                        f"{rate:.0f} albums/hr · {el:.0f}s\n")
                    sys.stderr.flush()
    finally:
        out_fh.close()
    el = time.time() - t0
    sys.stderr.write(f"done: {done_n} albums, {seg_total} segments, {failed} failed in {el:.0f}s "
                     f"({done_n/el*3600 if el else 0:.0f} albums/hr) -> {args.out}\n")


if __name__ == "__main__":
    main()
