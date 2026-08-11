#!/usr/bin/env python3
# LONG-LIVED timbre worker — the warm-batch half of the F10 measurement: 93% of the ~14 s/song
# timbre cost is per-PROCESS warm-up (python start + librosa import + numba JIT), not analysis.
# This worker pays that warm-up ONCE and then analyses a stream of files, one JSON task line per
# song on stdin, one JSON result line per song on stdout.
#
#   docker run --rm -i --entrypoint python -v <workdir>:/work pocketdj-audio:latest \
#     /work/timbre-warm-worker.py /work/analyze-timbre.py
#
# Protocol (newline-delimited JSON, stdout flushed per line):
#   -> {"ready": true, "warmupMs": N}                      once, after librosa imports
#   <- {"id": "sng_x", "path": "/work/stage/sng_x.mp3"}    one task
#   -> {"id": "sng_x", "ok": true, "v": 1, "f": {...}}     engine output + the task id
#   <- EOF                                                  clean shutdown, exit 0
#
# THE ENGINE IS NOT REIMPLEMENTED. Each task exec()s the canonical single-song engine
# (analyze-timbre.py — the ONE place the axis definitions and the measured lo/hi calibration
# live) with a patched argv and captured stdout. Numerical identity with the per-song Docker
# path is therefore by CONSTRUCTION: same source file, same librosa (this runs in the same
# pocketdj-audio image), same window logic. Re-exec per task costs microseconds — the heavy
# imports are cached in sys.modules, and numba JIT caches survive because it is one process.
import sys
import json
import time
import io
import contextlib

ENGINE = sys.argv[1] if len(sys.argv) > 1 else "/work/analyze-timbre.py"


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    t0 = time.time()
    # Pay the warm-up NOW, not on the first task, so the driver's per-song timings are honest.
    import librosa  # noqa: F401
    import numpy  # noqa: F401

    with open(ENGINE, "r") as fh:
        engine_src = fh.read()
    engine_code = compile(engine_src, ENGINE, "exec")
    emit({"ready": True, "warmupMs": int((time.time() - t0) * 1000)})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            task = json.loads(line)
        except ValueError:
            emit({"ok": False, "error": "bad task line"})
            continue
        song_id = task.get("id")
        path = task.get("path")
        t1 = time.time()
        out = io.StringIO()
        argv_before = sys.argv
        try:
            # The engine reads sys.argv[1] and prints ONE json line; it sys.exit(1)s on
            # failure, which must not kill the worker — catch SystemExit and keep going.
            sys.argv = [ENGINE, path]
            with contextlib.redirect_stdout(out):
                try:
                    exec(engine_code, {"__name__": "__main__", "__file__": ENGINE})
                except SystemExit:
                    pass
        except Exception as exc:  # noqa: BLE001 — a broken file must not stop the batch
            emit({"id": song_id, "ok": False, "error": str(exc),
                  "engineMs": int((time.time() - t1) * 1000)})
            continue
        finally:
            sys.argv = argv_before
        last = [ln for ln in out.getvalue().splitlines() if ln.strip()]
        try:
            result = json.loads(last[-1]) if last else {"ok": False, "error": "no output"}
        except ValueError:
            result = {"ok": False, "error": "unparseable engine output"}
        result["id"] = song_id
        result["engineMs"] = int((time.time() - t1) * 1000)
        emit(result)


if __name__ == "__main__":
    main()
