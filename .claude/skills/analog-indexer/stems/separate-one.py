#!/usr/bin/env python3
# Demucs stem separation for ONE audio file -> 4 stems (vocals/drums/bass/other). Mirrors
# analyze-one.py / analyze-beatgrid.py: one path arg, prints ONE JSON line (the last
# non-empty stdout line is what the caller parses). Model/device/format/bitrate come from
# the environment so the SAME script serves both the Docker (CPU) and native (MPS) runners.
#   docker run --rm --entrypoint python -e STEM_MODEL=htdemucs -e STEM_DEVICE=cpu \
#     -v <dir>:/work pocketdj-stems:latest /work/separate-one.py /work/song.mp3
#   # native MPS: STEM_DEVICE=mps PYTORCH_ENABLE_MPS_FALLBACK=1 python separate-one.py song.mp3
# Prints: {"ok":true,"model":"htdemucs","stems":{"vocals":"out/htdemucs/song/vocals.mp3", ...}}
import sys, os, json, glob, subprocess

EXPECT = ("vocals", "drums", "bass", "other")   # 4-stem invariant


def main():
    src = sys.argv[1]
    work = os.path.dirname(os.path.abspath(src))
    model = os.environ.get("STEM_MODEL", "htdemucs")
    device = os.environ.get("STEM_DEVICE", "cpu")
    fmt = os.environ.get("STEM_FORMAT", "mp3")
    br = os.environ.get("STEM_BITRATE", "256")      # integer kbps (demucs --mp3-bitrate)
    out = os.path.join(work, "out")
    cmd = ["python", "-m", "demucs", "-n", model, "-j", "1", "--device", device, "-o", out]
    cmd += ["--flac"] if fmt == "flac" else ["--mp3", "--mp3-bitrate", str(br)]
    cmd += [src]
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK="1")
    try:
        subprocess.run(cmd, check=True, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ext = "flac" if fmt == "flac" else "mp3"
        stems = {}
        for name in EXPECT:
            hits = glob.glob(os.path.join(out, model, "*", f"{name}.{ext}"))
            if not hits:
                raise FileNotFoundError(f"missing stem {name}")
            stems[name] = os.path.relpath(hits[0], work)
        if set(stems) != set(EXPECT):               # 4-stem guard: reject a non-4-stem model
            raise ValueError(f"unexpected stem set: {sorted(stems)}")
        print(json.dumps({"ok": True, "model": model, "stems": stems}))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)


main()
