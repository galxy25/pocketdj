# PocketDJ Stemify — On-Demand Demucs Stem Separation (build-ready spec)

> **Status: design complete, not yet built. Verdict: BUILD the indexer + durable queue + manifest fields + native creation UI, gated on a Phase-0 PoC that measures real Demucs wall-clock on this exact host (Apple M4 / macOS 26.5 / 32 GB).** Stemify separates any PocketDJ song into 4 stems (`vocals/drums/bass/other`) with Demucs v4 `htdemucs` (default; v3 `hdemucs_mmi`/`mdx_extra` as a one-env fallback), stores them at deterministic public S3 keys, and folds the result additively into the rip manifest — mirroring the existing rip / beat-grid / Rip-Burn machinery byte-for-byte so it lights up on every song/album/collection surface with one edit each. This document folds in a full review pass: every cross-section contract is now canonicalized (one model knob, one function name, one version field, one timeout, one manifest representation), the runner is async-spawn (not the event-loop-freezing `execFileSync` the draft shipped), the rip→stem chain has failure/cancel/zombie cleanup, and a **minimal in-app audition path ships in this PR** so the artifact is verifiable rather than invisible. Per-song always (analog ⇒ the per-song cut, never the album side). The full Mix-deck multi-stem consumption (solo/mute decks) remains a scoped follow-up, but is no longer the *only* consumer.

---

## Decisions locked (2026-06-26, Levi)

These override the spec's defaults/recommendations where they differ:

1. **Runtime = native MPS, Docker-CPU fallback.** Ship the host venv runner using Apple MPS as the default (`CFG.demucsRuntime='native'`, `CFG.demucsDevice='mps'`); keep the `pocketdj-stems` Docker-CPU image as the portable fallback. Gated on the Phase-0 PoC measuring real wall-clock on this host.
2. **App scope = creation UI only this PR.** Add the per-song/album `line.3.horizontal` Stemify button and the collection "Stemify" action + progress. **No in-app stem playback/audition this PR** (the §5.2 audition player is *deferred*, not shipped). Verification during testing is by stemifying a real playlist and inspecting the manifest / re-running to confirm skip.
3. **Native app only.** No PWA Stemify surfaces this PR.
4. **Format = mp3 256k.** Full-corpus `/backfill-stems` **is allowed** (not hard-capped to curated subsets) — the goal is to eventually stem the whole catalog. **Idempotent skip is mandatory:** an already-stemmed song at the current `stemVersion`/`stemModel` MUST be detected and skipped, so re-running `/stemify` or `/backfill-stems` over a playlist only stems the missing ones. Initial testing: Levi backfills one playlist (a few songs first) to validate server + app + skip behavior.

---

## 0. Canonical contract (single source of truth — every section references this)

The draft sections disagreed on load-bearing identifiers; the review flagged this as a build-blocker (imports resolve to `undefined`, the Swift decoder silently misses, the "single config knob" hard-constraint was violated by two env names). Frozen here, once:

| Concern | Canonical name | Notes |
|---|---|---|
| Model env knob (THE single knob) | `POCKETDJ_DEMUCS_MODEL` → `CFG.demucsModel` → exported `STEMS_MODEL` | All three read the **same** env: `STEMS_MODEL = process.env.POCKETDJ_DEMUCS_MODEL \|\| 'htdemucs'`. Writer + re-stem predicate both compare against `CFG.demucsModel`, which equals `STEMS_MODEL`. |
| Device knob | `POCKETDJ_DEMUCS_DEVICE` → `CFG.demucsDevice` | `mps` (native) \| `cpu`. Forced to `cpu` when runtime=`docker`. |
| Runtime knob | `POCKETDJ_DEMUCS_RUNTIME` → `CFG.demucsRuntime` | `native` (host venv, MPS) \| `docker` (CPU). |
| Image tag | `POCKETDJ_STEM_IMAGE` → `CFG.stemImage` | `pocketdj-stems:latest`. |
| Output format | `POCKETDJ_STEM_FORMAT` → `CFG.stemFormat` | `mp3` (default) \| `flac`. **Persisted per entry** (see manifest). |
| Bitrate | `POCKETDJ_STEM_BITRATE` → `CFG.stemBitrate` | **`256`** (integer kbps — `demucs --mp3-bitrate 256`; `'256k'` is rejected by demucs). |
| Per-job deadline | `POCKETDJ_STEM_DEADLINE_MS` → `CFG.stemDeadlineMs` | **ONE value: `1800000` (30 min).** Passed into the lib as the spawn/kill budget; the queue watchdog uses `stemDeadlineMs + 30_000` so they never fight. |
| Lib function | `separateStems(opts)` in `scripts/lib/audio-stem.mjs` | Exported alongside `STEMS_VERSION`, `STEMS_MODEL`, `STEM_NAMES`. Async, **spawn**-based, child-registering, watchdog-killable. |
| Algorithm version | `STEMS_VERSION = 1` | Separate from `ANALYSIS_VERSION` so a Demucs change never triggers a beatgrid re-run. |
| Manifest version field | `stemVersion` (singular) | Identical in JS writer and Swift decoder. Presence ⇒ stemmed. |
| Manifest stems field | explicit `stems` map `{vocals,drums,bass,other}` (S3 keys) + `stemFormat` | **Explicit keys, not derived** — the format knob makes client-side derivation wrong for FLAC entries. |
| Stem fixed shape | `STEM_NAMES = ['vocals','drums','bass','other']` | **4-stem models only.** `htdemucs_6s` is forbidden (would break the key map + Swift decoder + this contract). |

A round-trip test (writer → backfill predicate) is mandatory (§9) to prove a freshly-stemmed song is **not** re-selected by `/backfill-stems` — the field-name split would otherwise re-stem the entire corpus on every restart.

---

## 1. Architecture overview

Stemify is an **on-demand, per-song** pipeline. It reuses the rip corpus, the librosa-indexer Docker/skill pattern, the durable rip queue, the additive manifest, and the Rip/Burn UI — but the heavy work lives on its own concurrency-1 queue so a multi-minute Demucs run never starves a real-time capture.

```
 ┌──────────────────── CREATION (rip-server, on-demand per song) ─────────────────────────────┐
 │                                                                                            │
 │  source select (mirror analyzeBeatgridForSong:1001)                                        │
 │    digital song ─► rips/<songId>.mp3                                                        │
 │    analog song  ─► rips/<songId>.cut.mp3   (per-song CUT, NEVER rips/<albumId>.mp3)         │
 │         │                                                                                   │
 │         │  (not yet ripped/cut?  acceptRip → real-time capture → cut → chain back)          │
 │         ▼                                                                                   │
 │   separateStems()  ── async SPAWN, detached, conc-1, watchdog-killable ──┐                  │
 │     native venv  python -m demucs -n htdemucs --device mps  --mp3 --mp3-bitrate 256         │
 │     OR docker    pocketdj-stems  (--device cpu, portable fallback)        │                  │
 │         │                                                                ▼                  │
 │   demucs v4 htdemucs  →  out/htdemucs/<track>/{vocals,drums,bass,other}.mp3                 │
 │         │                                                                                   │
 │         ▼  aws s3 cp  (public rips/* prefix, deterministic keys)                            │
 │   s3://pocketdj-rips/rips/stems/<songId>/{vocals,drums,bass,other}.mp3                      │
 │         │                                                                                   │
 │         ▼  applyStems(e,r) → ADDITIVE fields on manifest[songId] → saveManifest()           │
 │   manifest[songId] += { stems, stemModel, stemVersion, stemmedAt, stemBytes, stemFormat }   │
 └────────┼───────────────────────────────────────────────────────────────────────────────────┘
          │  rips/manifest.json  (one public object; every client re-fetches whole on refresh)
          ▼
 ┌──────────────────────────────── APP (read-only; no server contact to PLAY) ────────────────┐
 │  RipsStore.ManifestEntry { stems: Stems, stemVersion, stemModel, stemFormat, stemmedAt }    │
 │     isStemmed(songId)        → manifest[songId]?.stemVersion != nil                          │
 │     stemURLs(forSong:)       → 4 public S3 URLs off Config.ripsBase                          │
 │         │                                                                                   │
 │         ├─► CREATION:  RowTransport "line.3.horizontal" button  +  collection "Stemify"     │
 │         │              POST /stemify · /stemify-collection · /stemify-cancel                 │
 │         │                                                                                   │
 │         ├─► AUDITION (this PR):  StemAuditionPlayer (AVPlayer streams the public stem URL)   │
 │         │              → verify a stem actually separated, by ear, from any row              │
 │         │                                                                                   │
 │         └─► FULL MIX (follow-up PR):  download-to-local → 4× AVAudioPlayerNode per deck      │
 │                        solo/mute  (AVAudioFile needs LOCAL urls — NOT streamable https)      │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
```

The diagram encodes two review fixes: (a) the runner is **spawn**, not `execFileSync` — so the event loop, watchdog, and `/stemify-cancel` kill-path all work; (b) the app has a real consumer **in this PR** (AVPlayer audition), and the full Mix path is correctly drawn as *download-to-local first* because `AVAudioFile(forReading:)` / `MixResolver.isLoadable` only accept local URLs.

---

## 2. The Demucs stems indexer

A **separate** image/runtime from `pocketdj-audio` (torch + demucs conflict with the librosa `numpy<2`/numba pin and add ~2 GB). Lives at `.claude/skills/analog-indexer/stems/` beside the `audio/` skill.

### 2.1 Runtime decision — native MPS default, Docker-CPU fallback (gated on the PoC)

The only reason the librosa indexer is Dockerized is that macOS arm64 librosa CQT/beat wheels segfault (`audio/Dockerfile` L2-3) — **that reason does not apply to torch/demucs**, which ship working arm64 + MPS wheels. Docker Desktop on macOS runs a linux/arm64 VM with **no Metal/MPS passthrough**, so in-container torch is CPU-only. The host is a known Apple **M4 / macOS 26.5 / 32 GB** iMac, so the native MPS path is the intended fast path; Docker-CPU is the portable/CI fallback behind the same `demucsRuntime`/`demucsDevice` knobs.

> **Review-folded caveat (do not treat the MPS speedup as settled):** Demucs MPS support is experimental; `htdemucs` is a Hybrid *Transformer* whose ops historically hit MPS gaps and trigger `PYTORCH_ENABLE_MPS_FALLBACK=1` (which we enable) — fallback runs those ops on CPU and can erode or erase the speedup; some reports show Demucs MPS comparable to or slower than CPU. **Re-pin torch to the newest release with confirmed M4/macOS-26 MPS wheels (≥ 2.4), not the early-2024 `torch==2.2.2`.** Phase-0 (§7) measures real wall-clock **and** peak RAM **and** how often MPS-fallback fires on this exact box, and locks the shipped default: **if measured MPS < ~2× CPU, ship `cpu` as the default** and recompute every estimate against the CPU floor.

### 2.2 `pocketdj-stems` Docker image (portable CPU fallback)

`.claude/skills/analog-indexer/stems/Dockerfile`:

```dockerfile
# PocketDJ STEM indexer — Demucs (htdemucs default). SEPARATE from pocketdj-audio:
# torch+demucs are heavy and conflict with the numpy<2/librosa pin. A container on
# macOS is CPU-ONLY (no MPS passthrough) — this is the portable/CI path; the native
# venv (§2.4) is the fast path on the Apple-Silicon host.
FROM python:3.11-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
 && rm -rf /var/lib/apt/lists/*
# Newest CPU torch with confirmed wheels (PoC pins the exact version). CPU-only here.
RUN pip install --no-cache-dir torch torchaudio --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir "demucs==4.0.1"
# Bake the default weights so runs are OFFLINE + IDEMPOTENT (an uncached torch-hub
# download would break the durable guarantee).
ENV TORCH_HOME=/opt/torch
ARG STEM_MODEL=htdemucs
RUN python -c "from demucs.pretrained import get_model; get_model('${STEM_MODEL}')"
# Do NOT pin OMP/OPENBLAS *_NUM_THREADS=1 like the librosa image — demucs benefits
# from multi-core and the queue is conc-1 (no in-process BLAS race).
COPY separate-one.py /app/separate-one.py
WORKDIR /app
ENTRYPOINT ["python", "separate-one.py"]
```

A v3 fallback image: `docker build --build-arg STEM_MODEL=hdemucs_mmi -t pocketdj-stems:hdemucs_mmi .claude/skills/analog-indexer/stems`.

### 2.3 `separate-one.py` — per-file stem script

`.claude/skills/analog-indexer/stems/separate-one.py`. Mirrors `analyze-one.py`/`analyze-beatgrid.py`: one mp3 arg, prints **one JSON line** (last non-empty stdout line is parsed). Model/device/format/bitrate come from env so the same script serves Docker and native. **Validates it produced exactly the 4-stem set** before reporting `ok` (review: guards against a non-4-stem model slipping in).

```python
#!/usr/bin/env python3
# Demucs stem separation for ONE file → 4 stems. Runs in pocketdj-stems (Docker, CPU)
# OR a host venv (native, MPS). Prints: {"ok":true,"model":"htdemucs",
#   "stems":{"vocals":"out/htdemucs/song/vocals.mp3", ...}}
import sys, os, json, glob, subprocess
EXPECT = ('vocals', 'drums', 'bass', 'other')   # 4-stem invariant
def main():
    src    = sys.argv[1]
    work   = os.path.dirname(src)
    model  = os.environ.get('STEM_MODEL', 'htdemucs')
    device = os.environ.get('STEM_DEVICE', 'cpu')
    fmt    = os.environ.get('STEM_FORMAT', 'mp3')
    br     = os.environ.get('STEM_BITRATE', '256')      # integer kbps
    out    = os.path.join(work, 'out')
    cmd = ['python', '-m', 'demucs', '-n', model, '-j', '1', '--device', device, '-o', out]
    cmd += ['--flac'] if fmt == 'flac' else ['--mp3', '--mp3-bitrate', br]
    cmd += [src]
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK='1')
    try:
        subprocess.run(cmd, check=True, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ext = 'flac' if fmt == 'flac' else 'mp3'
        stems = {}
        for name in EXPECT:
            hits = glob.glob(os.path.join(out, model, '*', f'{name}.{ext}'))
            if not hits:
                raise FileNotFoundError(f'missing stem {name}')
            stems[name] = os.path.relpath(hits[0], work)
        if set(stems) != set(EXPECT):                    # 4-stem guard
            raise ValueError(f'unexpected stem set: {sorted(stems)}')
        print(json.dumps({'ok': True, 'model': model, 'stems': stems}))
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}))
        sys.exit(1)
main()
```

CLI it shells (identical in Docker and native):
```
python -m demucs -n htdemucs --mp3 --mp3-bitrate 256 -j 1 --device cpu -o /work/out /work/song.mp3
# native MPS fast path: --device mps   (PYTORCH_ENABLE_MPS_FALLBACK=1)
```
Output layout: `out/<model>/<trackname>/{vocals,drums,bass,other}.<ext>`.

### 2.4 `separateStems()` — `scripts/lib/audio-stem.mjs` (async spawn, watchdog-killable)

> **Blocker fixed:** the draft ran Demucs via synchronous `execFileSync(..., {timeout:900000})`, which would freeze the single-threaded rip-server event loop for the entire 1.5–15 min run (no `/health`, no rips, no cancels) **and** leaves the §4 watchdog/`/stemify-cancel` kill-path inert (no child object, no pid to register or `process.kill(-pid)`). The runner is rewritten to **async `spawn`, `detached:true`** (own process group, exactly like `runAnalogJob`'s ffmpeg at rip-server.mjs:659/L713-717), assigns `opts.child.p = <proc>` so the server can `process.kill(-p.pid,'SIGKILL')`, and resolves a Promise on `close`. Only the `aws s3 cp` uploads stay synchronous/await (seconds, like the rest of the server).

```js
// scripts/lib/audio-stem.mjs
import { spawn, execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const STEM_PY = join(REPO, '.claude/skills/analog-indexer/stems/separate-one.py');
export const STEMS_MODEL   = process.env.POCKETDJ_DEMUCS_MODEL || 'htdemucs'; // SAME env as CFG.demucsModel
export const STEMS_VERSION = 1;                       // bump only on algorithm change
export const STEM_NAMES    = ['vocals', 'drums', 'bass', 'other'];

/**
 * Separate ONE file into 4 stems, upload to rips/stems/<songId>/<stem>.<ext>.
 * Resolves { ok, stems:{vocals,drums,bass,other} S3 KEYS, model, stemBytes, format }.
 * The caller writes the manifest. opts.child.p is set to the live demucs process so
 * the rip-server watchdog/cancel can group-kill it.
 */
export async function separateStems(opts) {
  const {
    file, songId, bucket, region = 'us-west-2', profile = 'levi',
    model = STEMS_MODEL,
    runtime = process.env.POCKETDJ_DEMUCS_RUNTIME || 'native',
    device  = runtime === 'docker' ? 'cpu' : (process.env.POCKETDJ_DEMUCS_DEVICE || 'mps'),
    image   = process.env.POCKETDJ_STEM_IMAGE  || 'pocketdj-stems:latest',
    venv    = process.env.POCKETDJ_STEM_VENV   || join(homedir(), '.pocketdj', '.venv-stems'),
    format  = process.env.POCKETDJ_STEM_FORMAT || 'mp3',
    bitrate = process.env.POCKETDJ_STEM_BITRATE || '256',
    tmp     = join(homedir(), '.pocketdj', 'rips'),
    child   = { p: null },          // shared handle for the watchdog/cancel
  } = opts;

  const out = { ok: false, stems: null, model, stemBytes: null, format };
  if (!existsSync(STEM_PY)) return out;

  const work = join(tmp, `stem-${songId}`);
  mkdirSync(work, { recursive: true });
  const ext = format === 'flac' ? 'flac' : 'mp3';
  const contentType = format === 'flac' ? 'audio/flac' : 'audio/mpeg';
  try {
    copyFileSync(file, join(work, 'song.mp3'));
    copyFileSync(STEM_PY, join(work, 'separate-one.py'));
    const senv = { STEM_MODEL: model, STEM_DEVICE: device, STEM_FORMAT: format, STEM_BITRATE: bitrate };

    // --- async spawn (NOT execFileSync): event loop stays live, child is killable ---
    const stdout = await new Promise((res, rej) => {
      let proc, buf = '';
      if (runtime === 'docker') {
        proc = spawn('docker',
          ['run', '--rm', '--entrypoint', 'python',
           ...Object.entries(senv).flatMap(([k, v]) => ['-e', `${k}=${v}`]),
           '-v', `${work}:/work`, image, '/work/separate-one.py', '/work/song.mp3'],
          { detached: true });
      } else {
        proc = spawn(join(venv, 'bin', 'python'),
          [join(work, 'separate-one.py'), join(work, 'song.mp3')],
          { detached: true, env: { ...process.env, ...senv, PYTORCH_ENABLE_MPS_FALLBACK: '1' } });
      }
      child.p = proc;                                  // register for watchdog/cancel
      proc.stdout.on('data', (d) => { buf += d; });
      proc.on('error', rej);
      proc.on('close', (code) => code === 0 ? res(buf) : rej(new Error(`demucs exit ${code}`)));
    });

    const j = JSON.parse(stdout.trim().split('\n').filter(Boolean).pop());
    if (!j.ok) return out;

    const stems = {};
    let bytes = 0;
    for (const name of STEM_NAMES) {
      const local = join(work, j.stems[name]);
      const key = `rips/stems/${songId}/${name}.${ext}`;
      execFileSync('aws', ['s3', 'cp', local, `s3://${bucket}/${key}`,
        '--content-type', contentType, '--profile', profile, '--region', region],
        { stdio: 'ignore' });
      stems[name] = key;
      try { bytes += statSync(local).size; } catch { /* ignore */ }
    }
    out.ok = true; out.stems = stems; out.model = j.model || model; out.stemBytes = bytes || null;
  } catch { /* best-effort: never wedge the queue */ }
  finally { child.p = null; rmSync(work, { recursive: true, force: true }); }
  return out;
}
```

### 2.5 Provisioning — `scripts/stems-index.sh`

Mirrors `audio-index.sh`'s idempotent build guard; provisions whichever runtime is selected and pre-warms weights so the first real run is offline. `scripts/update-ripserver.sh` runs this once on the iMac before `/stemify*` works (same pre-provision contract as `docker build -t pocketdj-audio`).

```bash
IMAGE=${POCKETDJ_STEM_IMAGE:-pocketdj-stems:latest}
VENV=${POCKETDJ_STEM_VENV:-$HOME/.pocketdj/.venv-stems}
MODEL=${POCKETDJ_DEMUCS_MODEL:-htdemucs}
if [ "${POCKETDJ_DEMUCS_RUNTIME:-native}" = docker ]; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || docker build --build-arg STEM_MODEL="$MODEL" -t "$IMAGE" .claude/skills/analog-indexer/stems
else
  [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "demucs==4.0.1" torch torchaudio   # PoC pins exact torch
  "$VENV/bin/python" -c "from demucs.pretrained import get_model; get_model('$MODEL')"
fi
```

### 2.6 Deterministic S3 naming

All under the **public `rips/*` prefix** (the only prefix the bucket policy makes public — rip-server.mjs:729). Keyed by **`songId`** (never `albumId`): each stem is computed on one song's own audio, so there is no shared album artifact. Mirrors `rips/waveforms/<id>.png` / `rips/analysis/<id>.json`.

```
rips/stems/<songId>/vocals.<ext>
rips/stems/<songId>/drums.<ext>
rips/stems/<songId>/bass.<ext>
rips/stems/<songId>/other.<ext>     # <ext> = mp3 (default) | flac
```

- Public URL via `publicUrl(key)`: `https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com/rips/stems/<songId>/<stem>.<ext>` — no auth to play; only **creation** hits the rip server.
- **Idempotent** within a format: a re-run overwrites the same 4 objects. A format swap (mp3→flac) writes new-extension objects and **orphans the old** — re-stemming should `aws s3 rm` the prior-format keys (the manifest's `stemFormat` records what to delete). This is why `stemFormat` is persisted.
- `<songId>` may carry a source namespace (`am:`); it is already used verbatim in `rips/<songId>.mp3`, so it is S3-key-safe as a path segment.
- See §6 for the public-exposure risk and the authed-proxy alternative.

---

## 3. Manifest schema additions (additive / back-compat)

### 3.1 rip-server JS — additive fields + `applyStems()`

New fields are **additive on the existing `manifest[songId]` entry** (never a new manifest), exactly how `cutKey`/beatgrid scalars were folded in. Old clients ignore unknown fields; a concurrent rip/analysis `saveManifest` cannot drop stems.

| Field | Type | Example | Notes |
|---|---|---|---|
| `stems` | `{vocals,drums,bass,other}` | `{"vocals":"rips/stems/<id>/vocals.mp3", ...}` | The 4 S3 keys. Presence ⇒ stemmed. |
| `stemModel` | string | `"htdemucs"` | Provenance; drives model-swap re-stem. |
| `stemVersion` | int | `1` | `STEMS_VERSION` stamp; drives `/backfill-stems` idempotency. **Singular field name — canonical.** |
| `stemFormat` | string | `"mp3"` | Records the actual extension (mp3\|flac); makes URL resolution format-correct and enables orphan-cleanup on a format swap. |
| `stemmedAt` | number (epoch ms) | `1750900000000` | `Date.now()` at completion (mirrors `rippedAt`). |
| `stemBytes` | int | `14233344` | Total bytes of the 4 stems (single number, like `cutBytes`). |

```js
// rip-server.mjs — next to applyBeatgrid()
import { separateStems, STEMS_VERSION, STEMS_MODEL, STEM_NAMES } from './lib/audio-stem.mjs';

function applyStems(e, r) {
  if (!r || !r.ok || !r.stems) return false;
  e.stems = r.stems;                       // {vocals,drums,bass,other} S3 keys
  e.stemModel = r.model || CFG.demucsModel; // == STEMS_MODEL
  e.stemVersion = STEMS_VERSION;
  e.stemFormat = r.format || CFG.stemFormat;
  e.stemmedAt = Date.now();
  if (r.stemBytes) e.stemBytes = r.stemBytes;
  return true;
}
```

**Re-stem predicate (schema-owned; consumed by `/backfill-stems` and `resumeStems`):**
```js
const eligible = (e) => (e.source === 'digital' && e.key) || (e.source === 'analog' && e.cutKey);
const wantStems = (e) =>
  eligible(e) && ((e.stemVersion ?? 0) < STEMS_VERSION || e.stemModel !== CFG.demucsModel);
```
Same shape as `backfillBeatgrids`'s `want()` (rip-server.mjs:1019-1020), **plus** the `stemModel !== CFG.demucsModel` clause so a v4→v3 swap re-stems without a `STEMS_VERSION` bump and without forcing a beatgrid re-run. (See §6 for the footgun warning — the model-mismatch clause is gated behind the candidate cap.)

### 3.2 Swift `RipsStore.ManifestEntry`

Additive optional fields on `ManifestEntry` (RipsStore.swift L48-82), each `= nil` so old manifests decode and old app builds ignore them. Insert after the beatgrid block (L80-81). The stems field is a **typed struct** (review: the draft disagreed map-vs-struct; the struct is safer and matches `stemURLs`):

```swift
// Demucs stem separation (Stemify indexer; all optional ⇒ back-compat). Per-song S3 keys
// under the PUBLIC rips/ prefix: rips/stems/<songId>/{vocals,drums,bass,other}.<ext>.
// PER-SONG always: a digital song stems its own `key`; an analog song stems its per-song
// CUT (`cutKey`), never the album side. Presence of `stemVersion` ⇒ stemmed.
struct Stems: Decodable, Equatable {
    var vocals: String
    var drums: String
    var bass: String
    var other: String
}
var stems: Stems? = nil
var stemModel: String? = nil
var stemVersion: Int? = nil           // SINGULAR — matches the JS writer (canonical)
var stemFormat: String? = nil
var stemmedAt: Double? = nil
var stemBytes: Int? = nil
```

Helpers (mirror `cachedURL`/`url(forKey:)`/`waveformURL`):

```swift
func isStemmed(_ songId: String) -> Bool { manifest[songId]?.stemVersion != nil }

/// Public stem URLs for a song (nil when not stemmed). Built off the same ripsBase as
/// cachedURL — playback works server-offline (pure S3 read). Keys are stored explicitly,
/// so the URL is correct regardless of mp3/flac format.
func stemURLs(forSong songId: String) -> [String: URL]? {
    guard let s = manifest[songId]?.stems else { return nil }
    return ["vocals": url(forKey: s.vocals), "drums": url(forKey: s.drums),
            "bass":   url(forKey: s.bass),   "other": url(forKey: s.other)]
}
func stemURL(forSong songId: String, _ stem: String) -> URL? { stemURLs(forSong: songId)?[stem] }
```

`ripsBase` = `Config.ripsBase` (`apple/PocketDJ/Support/Config.swift:21`). Stems live under `rips/`, so these URLs are public-readable with no auth header — identical to cuts/waveforms.

---

## 4. rip-server: stem queue + endpoints + rip→stem chaining + `/backfill-stems`

All wiring in `scripts/rip-server.mjs`. The queue is a deliberate hybrid: **analysis-queue *shape*** (conc-1, in-process, off the capture critical path — `pumpAnalysis` :938-946), **rip-queue *durability*** (durable per-songId intent — user intent is NOT re-derivable from the manifest, unlike analysis), and a **`pump()`-style watchdog** (a hung Demucs child on a conc-1 queue would wedge ALL stemming forever).

### 4.1 CFG knobs + module state

```js
// CFG block (rip-server.mjs:33-66) — canonical names from §0
demucsModel:    process.env.POCKETDJ_DEMUCS_MODEL   || 'htdemucs',   // THE single knob; v3: hdemucs_mmi | mdx_extra
demucsDevice:   process.env.POCKETDJ_DEMUCS_DEVICE  || 'mps',        // cpu when runtime=docker
demucsRuntime:  process.env.POCKETDJ_DEMUCS_RUNTIME || 'native',
stemImage:      process.env.POCKETDJ_STEM_IMAGE     || 'pocketdj-stems:latest',
stemFormat:     process.env.POCKETDJ_STEM_FORMAT    || 'mp3',
stemBitrate:    process.env.POCKETDJ_STEM_BITRATE   || '256',        // integer kbps
stemDeadlineMs: numEnv('POCKETDJ_STEM_DEADLINE_MS', 30 * 60_000),    // ONE value, 30 min
stemCollectionCap: numEnv('POCKETDJ_STEM_COLLECTION_CAP', 60),       // §6 size guard
```

```js
// module state, beside the analysis queue (:935)
const stemQ = [];                     // songIds queued for separation
let   stemming = false;               // conc-1 guard
const stemInflight = new Map();       // songId -> stemJobId (ALWAYS per-songId)
let   activeStemJobId = null;
const activeStemChild = { p: null };  // the live demucs child (registered by separateStems)
const stemAttempts = new Map();       // songId -> int (max-attempt cap; poison-input guard)
const STEM_MAX_ATTEMPTS = 3;

const STEM_WANT_DIR = join(CFG.tmp, 'stem-queue');   // durable intent (mirror QUEUE_DIR :122)
mkdirSync(STEM_WANT_DIR, { recursive: true });
const stemWantFile = (songId) => join(STEM_WANT_DIR, `${songId}.json`);
const wantStem = (songId) => existsSync(stemWantFile(songId));
function persistStemWant(songId, job) {
  try { writeFileSync(stemWantFile(songId), JSON.stringify(
    { songId, jobId: job.jobId, ripFromCloud: !!job.ripFromCloud, createdAt: job.createdAt })); } catch {}
}
function clearStemWant(songId) { try { rmSync(stemWantFile(songId)); } catch {} }
function killActiveStemChild() {       // mirror killActiveChild :492
  const p = activeStemChild.p; if (!p) return;
  try { process.kill(-p.pid, 'SIGKILL'); } catch { try { p.kill('SIGKILL'); } catch {} }
}
```

Stem jobs live in the **existing `jobs` Map** (so `GET /jobs/:id` resolves them for free) with `kind:'stem'` and phases `queued → ripping → stemming → ready | error | ineligible`. One edit to `jobView` (:377): `const live = job.phase === 'ripping' || job.phase === 'streaming' || job.phase === 'stemming';`

### 4.2 Deliberate divergences from the analysis path (each justified)

1. **Async spawn, not `execFileSync`** — §2.4. A minutes-long sync call would freeze `/health`/rips/cancels and make the watchdog inert.
2. **No in-process backoff** — a stem is not time-sensitive. On failure keep the durable want (until the attempt cap) and let `resumeStems()`/`/backfill-stems` re-attempt.
3. **Single-flight is ALWAYS per-songId** — a rip keys `inflight` by `albumId` for analog; a stem is per-song by hard constraint, so `stemInflight` is keyed only by `songId`. A live rip and a live stem for the same song coexist with no collision.
4. **Never co-run with a real-time capture** (review-added) — `pumpStems` defers while a real-time digital capture is active, so a parallel Demucs run can't degrade a latency-sensitive capture (CPU/RAM/thermal contention); it resumes from the rip-completion hook.

### 4.3 `acceptStem()` + worker + pump (with watchdog + capture-gate)

```js
function sourceReady(e) { return !!e && (e.source === 'analog' ? !!e.cutKey : !!e.key); }
// analog with boundaries but no cut yet  → transient 'needsCut'
function cutPending(e) { return e?.source === 'analog' && !e.cutKey && hasCutBoundaries(e); }
// analog with NO derivable boundaries    → TERMINAL 'ineligible' (can never be stemmed)
function cutImpossible(e) { return e?.source === 'analog' && !e.cutKey && !hasCutBoundaries(e); }
// hasCutBoundaries mirrors cutDurationMs(:757): startMs!=null && a derivable duration exists.

// status: 'unknown'|'ready'|'inflight'|'queued'|'ripping'|'needsCut'|'ineligible'
function acceptStem(songId, ripFromCloud = false) {
  const song = songId && songById.get(songId);
  if (!song) return { job: null, status: 'unknown' };
  const e = manifest[songId];
  if (e && (e.stemVersion ?? 0) >= STEMS_VERSION && e.stemModel === CFG.demucsModel)
    return { job: null, status: 'ready' };                       // idempotent
  if (e && cutImpossible(e)) { clearStemWant(songId); return { job: null, status: 'ineligible' }; }
  const existingId = stemInflight.get(songId);
  if (existingId && jobs.has(existingId)) return { job: jobs.get(existingId), status: 'inflight' };

  const job = { jobId: randomUUID(), songId, kind: 'stem', phase: 'queued',
                createdAt: Date.now(), ripFromCloud: !!ripFromCloud };
  jobs.set(job.jobId, job);
  stemInflight.set(songId, job.jobId);
  persistStemWant(songId, job);
  setPhase(job, 'queued');

  if (sourceReady(e)) { enqueueStem(songId); return { job, status: 'queued' }; }
  if (e && cutPending(e)) {                                       // ripped, boundaries exist, no cut yet
    kickBackfillCuts(songId);                                     // auto-kick cuts; chain resumes via hook
    setPhase(job, 'queued', { message: 'cutting before stemming' });
    return { job, status: 'needsCut' };
  }
  acceptRip(songId, ripFromCloud);                               // not ripped → rip first (idempotent)
  setPhase(job, 'ripping', { message: 'ripping before stemming' });
  return { job, status: 'ripping' };
}

function enqueueStem(songId) {
  if (!stemInflight.has(songId)) return;
  if (!stemQ.includes(songId)) stemQ.push(songId);
  pumpStems();
}

// Capture-gate (review): never start a stem while a real-time capture runs.
function realtimeCaptureActive() {
  const j = activeJobId && jobs.get(activeJobId);
  return !!(j && j.realtime);                                     // digital/cloud capture in flight
}

async function pumpStems() {
  if (stemming) return;
  if (realtimeCaptureActive()) return;                           // defer; rip-completion hook re-pumps
  const songId = stemQ.shift();
  if (!songId) return;
  stemming = true;
  activeStemJobId = stemInflight.get(songId);
  let timer;
  try {
    const watchdog = new Promise((_, rej) => {
      timer = setTimeout(() => { killActiveStemChild(); rej(new Error('stem watchdog timeout')); },
                         CFG.stemDeadlineMs + 30_000);            // > the lib budget; never fights it
      timer.unref?.();
    });
    await Promise.race([stemManifestSong(songId), watchdog]);
  } catch (e) {
    const n = (stemAttempts.get(songId) || 0) + 1;
    stemAttempts.set(songId, n);
    const job = jobs.get(activeStemJobId);
    if (n >= STEM_MAX_ATTEMPTS) {                                // poison input: stop re-attempting
      if (job && job.phase !== 'error') setPhase(job, 'error', { error: `failed ${n}× — giving up` });
      clearStemWant(songId);
    } else if (job && job.phase !== 'error') setPhase(job, 'error', { error: e.message }); // keep want
  } finally {
    clearTimeout(timer);
    stemInflight.delete(songId); activeStemChild.p = null; activeStemJobId = null; stemming = false;
    pumpStems();
  }
}

async function stemManifestSong(songId) {
  const e = manifest[songId];
  if (!e) { clearStemWant(songId); return; }
  if ((e.stemVersion ?? 0) >= STEMS_VERSION && e.stemModel === CFG.demucsModel) {
    clearStemWant(songId); finishStem(songId); return;           // a concurrent backfill won
  }
  const srcKey = e.source === 'analog' ? e.cutKey : e.key;       // EXACT mirror of analyzeBeatgridForSong:1001
  if (!srcKey) {                                                 // analog, no cut yet
    if (cutImpossible(e)) { clearStemWant(songId); setIneligible(songId); }
    return;                                                      // cutPending: keep want, /backfill-cuts chain re-drives
  }
  const job = jobs.get(stemInflight.get(songId));
  if (job?.canceled) return;
  if (job) setPhase(job, 'stemming', { message: 'separating stems' });

  const local = join(CFG.tmp, `${songId}.stem.mp3`);             // download to CFG.tmp (no ~/Downloads TCC)
  try { await aws(['s3', 'cp', `s3://${CFG.bucket}/${srcKey}`, local]); }
  catch { throw new Error('source download failed'); }
  try {
    const r = await separateStems({                              // async spawn; registers activeStemChild
      file: local, songId, bucket: CFG.bucket, region: CFG.region, profile: CFG.profile,
      model: CFG.demucsModel, runtime: CFG.demucsRuntime, device: CFG.demucsDevice,
      image: CFG.stemImage, format: CFG.stemFormat, bitrate: CFG.stemBitrate,
      tmp: CFG.tmp, child: activeStemChild,
    });
    if (job?.canceled || job?.phase === 'error') return;        // orphaned-continuation guard (runAnalogJob:678)
    if (!r.ok) throw new Error('demucs failed');
    applyStems(e, r);                                            // ADDITIVE write — only AFTER all 4 uploaded
    await saveManifest();                                        // stamp = source of truth; partials orphan harmlessly
    stemAttempts.delete(songId); clearStemWant(songId); finishStem(songId);
  } finally { try { rmSync(local); } catch {} }
}

function finishStem(songId) {
  const job = jobs.get(stemInflight.get(songId)); if (job) setPhase(job, 'ready', { message: 'stems ready' });
}
function setIneligible(songId) {
  const job = jobs.get(stemInflight.get(songId)); if (job) setPhase(job, 'ineligible', { error: 'no per-song cut — cannot stem' });
}
```

### 4.4 Rip→stem (and cut→stem) chaining + failure cleanup

Stems must NOT auto-run for every rip (analysis is cheap; Demucs is heavy) — gate on the durable `wantStem` set.

```js
function kickWantedStem(songId) {
  if (!wantStem(songId)) return;
  if (stemInflight.has(songId)) enqueueStem(songId); else acceptStem(songId);
}
```
- **Analog**, in `runAnalogJob` after `enqueueAnalysis(song.id)` (:748) — the cut pass (:702-742) already ran, so `cutKey` exists: `for (const s of songsByAlbum.get(album.id) || []) kickWantedStem(s.id);`
- **Digital**, in `runDigitalJob` after `enqueueAnalysis(song.id)` (:918): `kickWantedStem(song.id);`
- **`/backfill-cuts` completion** — after a cut is written for a `cutPending` song, call `kickWantedStem(songId)` so the cut→stem chain self-completes for already-ripped analog albums (review: the draft only chained fresh rips).

> **Review-fixed failure orphans:** add a **rip-FAILURE** hook (the digital `else fail(...)` branch and the analog "file not found"/no-source branches): `if (wantStem(songId)) { const job = jobs.get(stemInflight.get(songId)); if (job) setPhase(job,'error',{error:'source unrippable'}); stemInflight.delete(songId); clearStemWant(songId); }`. Also make `/rip-cancel`'s `cancelOne` clear any dependent stem want. Without this, an in-catalog-but-unrippable song (streaming-only, missing analog file) loops re-rip→re-fail every restart while the row sits at `ripping` forever.

### 4.5 Endpoints (all behind `authed()`, after `/rip-collection` :1268 / `/backfill-beatgrids` :1296)

**POST `/stemify {songId, ripFromCloud?}`** — single song. Response is `jobView`-shaped (Swift reuses the decoder).
```js
if (path === '/stemify' && req.method === 'POST') {
  const { songId, ripFromCloud } = await readJson(req);
  const r = acceptStem(songId, ripFromCloud);
  if (r.status === 'unknown')    return send(res, 404, { error: 'unknown songId' });
  if (r.status === 'ineligible') return send(res, 200, { jobId: null, songId, phase: 'ineligible' });
  if (r.status === 'ready')      return send(res, 200, { jobId: null, songId, phase: 'ready', stems: manifest[songId].stems });
  return send(res, 200, jobView(r.job));
}
```

**POST `/stemify-collection {songIds, ripFromCloud?}`** — mirror `/rip-collection` with the rip/cut→stem chain baked into `acceptStem`. **Enforces the size cap** (review: a Pocket DAG or large playlist could silently enqueue a multi-day job).
```js
if (path === '/stemify-collection' && req.method === 'POST') {
  const { songIds, ripFromCloud, confirmLarge } = await readJson(req);
  const ids = Array.isArray(songIds) ? [...new Set(songIds)] : [];
  if (ids.length > CFG.stemCollectionCap && !confirmLarge)
    return send(res, 200, { needsConfirm: true, count: ids.length, cap: CFG.stemCollectionCap,
                            message: `${ids.length} songs — this is a long job; re-send with confirmLarge:true` });
  const results = ids.map((id) => { const r = acceptStem(id, ripFromCloud);
    return { songId: id, status: r.status, jobId: r.job ? r.job.jobId : null }; });
  const counts = results.reduce((c, r) => { c[r.status] = (c[r.status] || 0) + 1; c.total++; return c; },
    { ready: 0, queued: 0, inflight: 0, ripping: 0, needsCut: 0, ineligible: 0, unknown: 0, total: 0 });
  return send(res, 200, { results, counts });
}
```

**POST `/stemify-cancel {songIds}`** — STOP. Cancels queued/active stem jobs AND routes the rip-dependency through `cancelOne` so a stopped Stemify never leaves a rip capturing.
```js
function cancelStemOne(songId, canceledAlbums) {
  const song = songId && songById.get(songId); if (!song) return 'notFound';
  const e = manifest[songId];
  if (e && (e.stemVersion ?? 0) >= STEMS_VERSION && e.stemModel === CFG.demucsModel) return 'alreadyDone';
  cancelOne(songId, canceledAlbums);                            // tears down the chained rip (idempotent)
  const jobId = stemInflight.get(songId);
  if (!jobId || !jobs.has(jobId)) { clearStemWant(songId); return 'notFound'; }
  const job = jobs.get(jobId);
  if (activeStemJobId === jobId) { job.canceled = true; killActiveStemChild(); } // kill the live child
  const qi = stemQ.indexOf(songId); if (qi >= 0) stemQ.splice(qi, 1);
  stemInflight.delete(songId); stemAttempts.delete(songId); clearStemWant(songId);
  setPhase(job, 'error', { error: 'canceled' });
  return 'canceled';
}
```
Router clone of `/rip-cancel` (:1304), counts `{canceled,notFound,alreadyDone,total}`.

**POST `/backfill-stems`** — re-stem **stale** entries only. Clone of `/backfill-beatgrids` (:1290) with a **dedicated `stemBackfillRunning` flag** (not the shared `backfillRunning` :770) and a **hard candidate cap** so it can never kick a full-corpus multi-week run (review: at ~93k songs even the model-mismatch clause could re-stem the world). It **seeds the durable queue** (calls `acceptStem` per candidate) so every separation gets the conc-1 watchdog + durable-resume protection.
```js
let stemBackfillRunning = false;
async function backfillStems(opts = {}) {
  const want = (e) => wantStems(e);                              // §3.1 predicate (version OR model)
  const ids = Object.entries(manifest).filter(([, e]) => want(e)).map(([id]) => id);
  for (const id of ids) { if (want(manifest[id] || {})) acceptStem(id); }  // idempotent; drains via pumpStems
  console.error(`  backfill-stems: enqueued ${ids.length}`);
}
if (path === '/backfill-stems' && req.method === 'POST') {
  const { confirmLarge } = await readJson(req).catch(() => ({}));
  const candidates = Object.values(manifest).filter((e) => wantStems(e)).length;
  if (candidates > CFG.stemCollectionCap && !confirmLarge)
    return send(res, 200, { ok: false, needsConfirm: true, candidates, cap: CFG.stemCollectionCap,
                            model: CFG.demucsModel, version: STEMS_VERSION });
  if (!stemBackfillRunning) { stemBackfillRunning = true;
    backfillStems().finally(() => { stemBackfillRunning = false; }); }
  return send(res, 200, { ok: true, candidates, model: CFG.demucsModel, version: STEMS_VERSION, running: stemBackfillRunning });
}
```

**`/health`** (:1208): additive `stems: true` flag for UI gating (preferred over forcing a `RIP_PROTOCOL` 2→3 bump, which would banner older apps):
```js
return send(res, 200, { ok: true, host: hostname(), version: RIP_PROTOCOL, hls: true, stems: true, /* …rest… */ });
```

**Progress polling** — *per-item* (`/stemify` returned a `jobId`): poll `GET /jobs/:id` → `jobView` with `phase ∈ {queued,ripping,stemming,ready,error,ineligible}`. *Collection*: poll the manifest, predicate `manifest[id].stems != null` (the durable completion signal; the client resolves stem URLs straight off S3).

### 4.6 Startup resume

`resumeStems()` after `resumeAnalysis()` (:1375): read the durable intent dir (NOT the manifest), recreate each stem job via `acceptStem` (fresh process → `stemInflight` empty → re-enqueue or re-rip), skipping already-done and ineligible. Clears wants for unknown/done songs so they don't loop.

### 4.7 Hook-point summary

| What | Where | Action |
|---|---|---|
| import `separateStems`, `STEMS_VERSION`, `STEMS_MODEL`, `STEM_NAMES` | :26 | add |
| CFG `demucsModel/demucsDevice/demucsRuntime/stemImage/stemFormat/stemBitrate/stemDeadlineMs/stemCollectionCap` | :33-66 | add |
| stem queue state + `STEM_WANT_DIR` + `killActiveStemChild` + `stemAttempts` | beside :935 / :122 / :492 | add |
| `jobView` live set | :377 | add `\|\| job.phase === 'stemming'` |
| `applyStems` | beside `applyBeatgrid` :984 | add |
| `acceptStem`/`enqueueStem`/`pumpStems`/`stemManifestSong`/`finishStem`/`setIneligible`/`realtimeCaptureActive` | beside :398 / :947 | add |
| `cancelStemOne` | beside `cancelOne` :431 | add |
| `backfillStems` + `stemBackfillRunning` + `wantStems` | beside `backfillBeatgrids` :1017 | add |
| rip→stem chain (analog/digital) | :748 / :918 | add `kickWantedStem` |
| cut→stem chain | `/backfill-cuts` completion | add `kickWantedStem` |
| rip-FAILURE cleanup | digital `fail()` / analog no-source branches | clear want + terminal stem job |
| `/stemify`, `/stemify-collection`, `/stemify-cancel`, `/backfill-stems` | after :1251 / :1268 / :1322 / :1296 | new routes |
| `/health` `stems:true` | :1209 | add |
| `resumeStems()` | after :1375 | add |

---

## 5. App: collection "Stemify" + per-song button + ingestion + audition

Native SwiftUI. Everything mirrors `CollectionRipBurn.swift` / `RipsStore.swift` so it lights up on every collection + song surface with one edit each. **This PR also ships a minimal audition** so the artifact is verifiable (review blocker: the draft shipped invisible artifacts).

### 5.1 Ingestion + client methods (`apple/PocketDJ/State/RipsStore.swift`)

`ManifestEntry` fields + `isStemmed`/`stemURLs` per §3.2. Per-song state + methods mirror `jobs`/`requesting` and `requestRipIfNeeded`/`ripCollection`/`cancelCollection`:

```swift
enum StemPhase: String, Decodable { case queued, ripping, stemming, ready, error, ineligible }
struct StemJob: Decodable, Equatable { var jobId: String? = nil; var songId: String? = nil; var phase: StemPhase; var error: String? = nil }
private(set) var stemJobs: [String: StemJob] = [:]
private var requestingStems: Set<String> = []
nonisolated private static let stemInFlightPhases: Set<StemPhase> = [.queued, .ripping, .stemming]

func stemify(_ songId: String) async { /* POST /stemify; idempotent 3-layer guard like requestRipIfNeeded; pollStemReady */ }
func stemifyCollection(_ songIds: [String]) async -> BatchRipResult { /* POST /stemify-collection; 404 → per-song stemify() fallback */ }
@discardableResult func cancelStemCollection(_ songIds: [String]) async -> [CancelItem] { /* POST /stemify-cancel; silent 404 no-op */ }
```

> **Review fixes folded:** (a) `pollStemReady` and the collection poll use **stem-specific, much longer caps** sized to the chosen runtime's worst case (Docker-CPU multi-hour) — the rip-tuned 30-min / ~2-h caps would give up while the server keeps stemming; the per-item completion backs off the manifest with a high ceiling and a "Refresh to check" affordance rather than a hard give-up. (b) The 404 collection fallback synthesizes counts from `stemJobs[id]?.phase` (queued/ripping/stemming/ready), **not** `jobs[id]` (which is the rip dict — copying the rip fallback verbatim would mis-count). (c) `BatchRipResult`/`Counts` gain `ripping` and `ineligible` buckets (default 0 ⇒ tolerant of older servers).

### 5.2 Audition player (this PR — makes the artifact verifiable)

`apple/PocketDJ/Mix/StemAuditionPlayer.swift` *(new)*. A lightweight `AVPlayer` that **streams** a single public stem URL (vocals solo / instrumental). Critically this uses `AVPlayer`/`AVPlayerItem`, which accept remote https URLs — **not** `AVAudioFile(forReading:)`, which only opens local files (review: the draft's `stemURLs → AVAudioPlayerNode` seam was unworkable for streaming). No BurnStore download, no Mix-engine change. The per-row stem button long-press (or a small accessory) plays `vocals` so Levi can confirm separation worked by ear, satisfying "verify in app each stage."

```swift
@Observable final class StemAuditionPlayer {
    private var player: AVPlayer?
    private(set) var auditioning: String?            // "<songId>:<stem>"
    func play(_ url: URL, tag: String) { stop(); player = AVPlayer(url: url); player?.play(); auditioning = tag }
    func stop() { player?.pause(); player = nil; auditioning = nil }
}
```

### 5.3 Per-item Stemify button — the single shared site

`apple/PocketDJ/Views/CollectionSongRow.swift` → `RowTransport` (:297). Editing this ONE shared transport surfaces the button in the Browser list, every collection row, the frozen Setlist, the album `TrackRow` (`AlbumDetailView.swift:243`), and `SongDetailView` (:126).

- Add `Busy.stem` (:312). Add `stemmed`/`stemBusy` helpers alongside `cached`/`canAct`.
- Add the third button after `row-download-<id>`. **Idle/done glyph = `line.3.horizontal`** (hard constraint), **busy uses a distinct in-progress treatment** — a small `ProgressView()` plus a phase label ("Ripping first…"/"Stemming…"), **not** the `ellipsis` the download button shows (review: two ambiguous ellipses side-by-side, and minutes-to-hours warrants real phase feedback):

```swift
if stemBusy {
    HStack(spacing: 4) { ProgressView().controlSize(.mini)
        Text(stemPhaseLabel).font(.caption2).foregroundStyle(Theme.fgDim) }
        .accessibilityIdentifier("row-stemify-\(song.id)")
} else {
    Button { doStemify() } label: { Image(systemName: "line.3.horizontal").font(.caption) }
        .buttonStyle(.borderless)
        .foregroundStyle(stemmed ? Theme.accent : (canAct ? Theme.fgDim : Theme.fgDim.opacity(0.4)))
        .disabled(!canAct || busy != nil)
        .accessibilityIdentifier("row-stemify-\(song.id)")
}
```
`doStemify()` sets `busy = .stem` and `await rips.stemify(song.id)`. "Stemmed" is the accent tint (parallel to `cached` tinting play at :352); the glyph stays `line.3.horizontal`. **The a11y id is on the Button/HStack content only, never a container** — the documented macOS container-id-propagation bug (`CollectionSongRow.swift:502`) would clobber `row-play-<id>`/`row-download-<id>`.

### 5.4 Album-level "Stemify each song"

`apple/PocketDJ/Views/AlbumDetailView.swift`. Per-track button is free (each `TrackRow` embeds `RowTransport`). Album action: add `@State private var ripBurn = CollectionRipBurnController()`, `@Environment(RipsStore.self) private var rips`, the `.collectionRipBurn(ripBurn)` modifier, and a `ToolbarItem(.primaryAction)` after `album-shuffle` calling `ripBurn.stemify(tracks.map(\.id), rips:, noun:)` with a11y id `album-stemify`. Satisfies the per-song constraint (album ⇒ each track, never the side).

### 5.5 Collection "Stemify" (Playlist / Pocket / Setlist)

`apple/PocketDJ/Views/CollectionRipBurn.swift`. `CollectionRipBurnButtons` is already mounted in `PocketsView:133`, `PlaylistsView:417/:551`, `SetlistDetailView:229/:291`. Add one button + one controller op ⇒ all four screens light up.

- **Button** after Burn (:44): `Label("Stemify \(noun)", systemImage: "line.3.horizontal")`, a11y `collection-stemify`, disabled `ids.isEmpty || controller.working || !rips.hasServer`.
- **Controller** (:66): add `Op.stem`, `stemInProgress`/`stemProgress`, a SEPARATE `stemPollTask`/`lastStemIds` (so a simultaneous Rip and Stemify don't fight one poll), `stemify()`/`startStemPoll`/`finishStemPoll` cloned from the rip path with completion predicate `rips.isStemmed(id)` (not `cachedURL`). The summary surfaces `ready`/pending(`queued+inflight+ripping`)/`ineligible`/`unknown`, and **the rip-first phase is shown as a distinct count** ("N being ripped first · M stemming") when the server returns a `ripping` bucket (review). Honor the server's `needsConfirm` envelope with an "N songs, long job — proceed?" alert before committing.
- **STOP** routes through `controller.stop(rips:burns:)` → `rips.cancelStemCollection(lastStemIds)`. `/stemify-cancel` tears down BOTH the chained rips and the queued stems server-side, so the client calls only `cancelStemCollection`.
- **Progress pill** in `CollectionRipBurnAlert` (:308): third branch for `stemInProgress`, a11y `stem-progress`, STOP id `collection-stem-stop`.

### 5.6 Server-capability gating

Extend the `/health` probe to read `stems:true` → `rips.serverSupportsStems`. Add it to the disable predicates in §5.3-5.5 so the buttons hide cleanly on an old server; until wired, `!rips.hasServer` + the `/stemify*` 404 fallbacks keep the UI safe.

### 5.7 Scope notes (review-folded)

- **PWA out of scope for this PR.** The deployed React PWA (`src/`, `ItemCard.tsx`, `SetlistView.tsx`) is **not** wired for Stemify in v1; the native app is the sole shipping creation surface. A PWA `Stemify` action (same `/stemify*` endpoints) is a tracked follow-up — "every relevant view" holds for native; the web surface is explicitly deferred, not silently broken.
- **Full Mix multi-stem decks (solo/mute) = follow-up PR.** It requires (a) a `BurnStore` stem-download/burn pipeline (`AVAudioFile` needs LOCAL urls; `MixResolver.isLoadable:73` gates on `burns.localURL != nil`) and (b) a 4-`AVAudioPlayerNode`-per-deck engine rewrite — neither is in this PR. The clean seam is in place: a future `BurnStore.stems(forSong:)` (byte-for-byte the `beatGrid(forSong:)` pattern at `BurnStore.swift:409`) + `rips.stemURLs(forSong:)`. This PR ships ingestion + URL helpers + the streaming audition, so the next PR is purely consumption.

### 5.8 a11y-id inventory

| Surface | a11y id | Element |
|---|---|---|
| Per-row (everywhere) | `row-stemify-<songId>` | Stemify button/progress in `RowTransport` (content only, never container) |
| Album toolbar | `album-stemify` | album-level action |
| Collection menu | `collection-stemify` | "Stemify \(noun)" |
| Collection pill | `stem-progress` / `collection-stem-stop` | progress + inline STOP |

---

## 6. Feasibility, cost & risks (quantified)

### 6.1 Runtime feasibility — ranges, gated on the PoC

Wall-clock per **~4-min song**, default settings (no `--shifts`). **These are estimates bounded by the measured CPU floor; the MPS column is unvalidated until Phase-0 (§2.1).**

| Runtime / device | `htdemucs` (v4 default) | `hdemucs_mmi` (v3 light) | `mdx_extra` (v3 bag-of-4) |
|---|---|---|---|
| Native venv · **MPS** (intended default, **if PoC confirms ≥2× CPU**) | ~45–120 s* | ~20–60 s* | ~2–4 min* |
| Native venv · CPU | ~4–8 min | ~2–4 min | ~7–13 min |
| Docker-on-Mac · CPU only | ~5–10 min | ~2–4 min | ~8–15 min |

\* MPS figures assume a real speedup that fallback ops can erode — **treat as a hypothesis, not a design input.** Peak RAM `htdemucs` is segment-bounded (~4–8 GB/run regardless of track length); the host is 32 GB.

**Workload bounding** (conc-1, midpoint). The addressable corpus is **~105k songs — 92,865 Apple Music + 12,525 analog** (verified), not the 12k the draft used:

- **20-song already-ripped setlist:** ~15–40 min (MPS, if real) / ~2–3.5 h (CPU). Acceptable as a background job with a progress pill — *for small, already-ripped sets*.
- **Rip-first penalty (review, previously unquantified):** digital ripping is **real-time Audio Hijack capture** (`realtime:true`, `totalMs = LENGTH_MS`) on the single capture queue. An unripped 20-song setlist incurs **~70–80 min of serial real-time ripping before any stemming begins**, dominating wall-clock regardless of Demucs speed; an unripped 200-song playlist is the better part of a day in ripping alone. Surface a two-phase estimate ("M to rip first, then N to stem").
- **Full-corpus stemify is impractical at every device tier:** 92,865 songs ≈ **~3 months continuous on (optimistic) MPS**, **a year-plus on CPU**. `/backfill-stems` is **hard-capped** (`stemCollectionCap`, default 60; `confirmLarge` to exceed) and exists only to re-run an already-stemmed subset after a model/version bump — it must never default to the whole catalog. `/stemify-collection` and the album/pocket/playlist actions carry the **same cap + confirm** (Pocket DAGs expand to thousands of songs).

### 6.2 Storage & egress cost (recomputed at ~105k)

Stems under public `rips/stems/<songId>/{...}.<ext>`. Per ~4-min song:
- **mp3 256k (default):** ~7.7 MB/stem × 4 ≈ **~31 MB/song** ≈ 4× the source rip.
- **flac (future lossless option):** ~12–25 MB/stem × 4 ≈ **~60–110 MB/song** (~2–3.5× the mp3 stems).

| Working set | mp3 storage | S3 Standard us-west-2 ($0.023/GB-mo) |
|---|---|---|
| 100 songs | ~3 GB | ~$0.07/mo |
| 1,000 songs | ~31 GB | ~$0.70/mo |
| **Whole ~92.9k AM catalog** | **~2.8 TB** | **~$65/mo** |
| Whole ~105k (AM+analog) | ~3.2 TB | ~$74/mo |

Storage stays cheap; the real variable is **egress**. Stem playback streams ~31 MB (4 stems) per song-play directly from public S3 (`ripsBase` is the direct S3 URL, **no CloudFront in front**) at **$0.09/GB** ⇒ ~$0.0028/song-play; 10k stem-plays/mo ≈ **~$28/mo**. **Recommendation:** front `rips/stems/` (or all `rips/`) with the existing CloudFront distribution before Mix-tab stem streaming ships, to cut egress + per-request cost. **Lifecycle:** stems are a regenerable, deterministically-keyed cache — transition `rips/stems/` to S3 Standard-IA after ~30 days and optionally expire after ~90–180 days (re-stemmable on demand). **Do not** lifecycle source rips/cuts.

### 6.3 License & copyright posture

- **License:** Demucs code + `htdemucs`/`hdemucs_mmi`/`mdx_extra` weights are **MIT** — fine to bundle weights and ship outputs (`mdx_extra` is research-grade, trained with extra data; MIT still applies).
- **Copyright exposure (review — re-weighted, NOT "no new exposure"):** keys are deterministic and `songId`s are enumerable straight from the public `manifest.json`, so the **entire isolated-acapella/instrumental corpus is trivially scrapeable with zero auth**. Isolated stems are materially **more** sensitive and independently redistributable than full-mix rips. **This is a real escalation over ripping, not parity.** Options, in order of safety: (1) serve stems through the **authed rip-server** (proxy/stream) instead of public S3; (2) keep public S3 but use a **non-enumerable opaque token** in the key (`rips/stems/<songId>/<token>/vocals.mp3`, token stored in `stems`) so a stem URL can't be guessed from the manifest's song list alone — partial mitigation since the manifest still lists keys; (3) accept the heightened public exposure with explicit sign-off. **Recommend (1) or (2); do not silently ship (3).** Tracked in §8.

### 6.4 Risks & mitigations

- **Queue starvation / live-capture contention:** dedicated conc-1 `stemQ`/`pumpStems`, separate from rip + analysis queues; **and** `pumpStems` defers while a real-time capture is active (§4.2-4.3) so a Demucs run can't degrade a latency-sensitive capture. Gate behind the durable `wantStem` set so only user-initiated songs ever stem. `nice`/low-priority the child where feasible.
- **conc-1 justification (corrected):** keep conc-1, but the reason is **thermal throttling under sustained load + single-GPU/CPU throughput + the host simultaneously doing real-time captures** — **not** OOM (two `htdemucs` runs ≈ 8–16 GB on a 32 GB box would not OOM). Record real peak RAM from the PoC.
- **Source quality:** analog rips/cuts are 256k mp3 — isolated vocals/other will surface lossy artifacts. Inherent, not a blocker; best-effort try/catch so a failure never wedges the queue. Future knob: stem from a higher-quality source if available.
- **Analog-cut dependency (three states, review-fixed):** stem the per-song **cut**, never the album side. `cutPending` (boundaries exist, cut not made) → transient, auto-kick `/backfill-cuts`, chain resumes. `cutImpossible` (no `startMs`/derivable duration — `cutDurationMs:757` returns null) → **TERMINAL `ineligible`**, clear the want, report once (no infinite needsCut zombie). Already-ripped pre-cut analog auto-kicks `/backfill-cuts` rather than silently sitting at needsCut.
- **Failure recovery & poison inputs:** manifest stamp is the source of truth — write stem fields **only after all 4 upload**, so a crash mid-upload orphans S3 objects but leaves no stamp; `resumeStems` re-runs and the deterministic keys overwrite the partials. A genuinely-crashing song hits the **`STEM_MAX_ATTEMPTS=3` cap** and goes terminal `error`, clearing its want so it stops re-attempting every restart. The watchdog group-kills a hung child (`stemDeadlineMs + 30 s`).
- **Timeout (single value, review-fixed):** `CFG.stemDeadlineMs = 1800000` (30 min) sized to the slowest supported combo (mdx_extra / Docker-CPU / a long track); the lib budget and the watchdog derive from this one value (watchdog = budget + 30 s). The draft's 15-min figure would SIGKILL a legitimate 7–8-min-track CPU run.
- **Server-capability gating:** older servers 404 the new endpoints → `stems:true` `/health` flag + the `ripCollection`-style 404 fallback.

---

## 7. Phased rollout / smallest PoC

- **Phase 0 — PoC (one song, native, GATING):** in a host venv, `demucs -n htdemucs --device mps --mp3 --mp3-bitrate 256 -o <out> <one-song.mp3>` (`PYTORCH_ENABLE_MPS_FALLBACK=1`) **on this exact M4 / macOS 26.5 box**. Measure wall-clock, peak RAM, and **log how often MPS-fallback fires**; listen to the 4 stems. Hand-`aws s3 cp` to `rips/stems/<songId>/` and hand-edit one manifest entry, then confirm the Swift client `isStemmed`/`stemURLs` + the §5.2 AVPlayer audition resolve + play the public stem end-to-end. **Gate:** pin the exact torch version with confirmed M4 wheels; lock the shipped default device (`mps` only if ≥~2× CPU, else `cpu`); replace every §6.1 estimate with measured numbers.
- **Phase 1 — image + lib + runner:** `pocketdj-stems` Dockerfile (weights baked) + native venv; `scripts/lib/audio-stem.mjs` (`separateStems` async-spawn + `STEMS_VERSION`/`STEMS_MODEL`/`STEM_NAMES`); `separate-one.py`; `scripts/stems-index.sh`. Verify Docker-CPU and native-MPS emit the identical `rips/stems/<songId>/{...}.<ext>` shape.
- **Phase 2 — durable queue:** `stemQ`/`pumpStems`/`stemManifestSong` (conc-1 + watchdog + capture-gate + attempt cap), durable `STEM_WANT_DIR`, additive write after all 4 uploads, `resumeStems`. Add the **writer→backfill round-trip test** (proves a fresh stem is not re-selected). Drive from a local fn — no HTTP yet.
- **Phase 3 — endpoints + chain:** `/stemify`, `/stemify-collection` (size cap + `needsConfirm`), `/stemify-cancel` (tears down chained rips), rip→stem + cut→stem + rip-FAILURE hooks, `/health` `stems:true`.
- **Phase 4 — backfill (bounded):** `/backfill-stems` — single-flight, resumable, version/model-gated, **candidate-capped**, skips ineligible analog.
- **Phase 5 — native UI + audition:** `ManifestEntry` fields + client methods + `RowTransport` button (`row-stemify-<id>`, distinct busy treatment) + `album-stemify` + `collection-stemify` + progress pill + the §5.2 streaming audition. Overflow-aware UI tests; never an a11y id on a container.
- **Phase 6 — ops:** pre-provision image/venv + warmed weights on the iMac via `update-ripserver.sh`; document the knobs; apply the `rips/stems/` lifecycle; decide CloudFront fronting + the public-exposure posture (§6.3) before any wide stem streaming.

### Smallest end-to-end PoC

One song → 4 stems → S3 → one hand-edited manifest entry → the native row shows the accent-tinted `line.3.horizontal` and the AVPlayer audition plays the isolated vocal. This proves the whole vertical (separate → store → manifest → app → audible) before any queue/endpoint/UI build, and satisfies "verify in app each stage."

### 9. Tests

- `RipsStoreTests`: decode `ManifestEntry` with `stems`/`stemModel`/`stemVersion`/`stemFormat` ⇒ `isStemmed` true + `stemURLs` builds four `rips/stems/<id>/*.<ext>` URLs; without stems ⇒ false/nil. Decode a `/stemify-collection` envelope incl. `ripping`/`ineligible` statuses.
- **Round-trip idempotency test (mandatory):** server writes `stemVersion`/`stemModel` → `wantStems(e)` returns false for that entry (catches the field-name split that would re-stem the corpus forever).
- `CollectionRipBurnController`: `stemify()` summary for ready/pending/rip-first/ineligible/unknown; STOP routes to `cancelStemCollection` and clears `stemInProgress`; honors `needsConfirm`.
- UI test (overflow-aware, per the toolbar-overflow memory): `row-stemify-<id>` reachable on a Browser row, album `TrackRow`, setlist row; `collection-stemify` reachable in Playlist/Pocket/Setlist menus (incl. behind the iPhone "More" overflow); `album-stemify` in the album toolbar; assert `row-play-<id>`/`row-download-<id>` still resolve after adding the third button.

---

## 8. Open questions for Levi

1. **Public exposure of isolated stems (most important).** Deterministic public keys + the public `manifest.json` make the whole acapella/instrumental corpus scrapeable with zero auth — materially more sensitive than full-mix rips. Serve stems through the **authed rip-server proxy** (safest), use a **non-enumerable opaque token** in the key (partial), or **accept public exposure with explicit sign-off**? (Recommend proxy-or-token, not silent-public.)
2. **Shipped runtime/device default — decided by the Phase-0 PoC.** Native-MPS (fast, *if* the PoC confirms ≥~2× CPU with acceptable fallback) vs Docker-CPU (portable, ~5–10 min/song, pattern-consistent with the librosa indexer). Also confirm re-pinning torch to the newest M4/macOS-26 MPS wheel rather than `2.2.2`.
3. **Consumption scope for this PR.** Ship the streaming single-stem **audition** (recommended — makes the artifact verifiable) and defer the full Mix solo/mute decks (BurnStore stem-download + 4-node-per-deck engine) to a follow-up PR? Or land the indexer + queue + manifest **dark** with no buttons until the Mix consumer is ready?
4. **Backfill / collection caps.** Confirm a hard candidate cap (default 60, `confirmLarge` to exceed) on `/stemify-collection`, the album/pocket/playlist actions, **and** `/backfill-stems` — so nobody accidentally kicks a ~3-month full-corpus run. What cap value?
5. **Re-stem trigger.** Version-only (`stemVersion < STEMS_VERSION`; a model swap = bump version + set `CFG.demucsModel` together) vs **also** `stemModel !== CFG.demucsModel` (auto-re-stems on any model env change — convenient but a footgun behind the cap). Spec uses version-OR-model, gated by the cap.
6. **Output format.** mp3 256k default (4× source, cheap) vs flac (2–3.5× the mp3 stems) if the future Mix decks want lossless. mp3 default, flac opt-in via `stemFormat` (persisted per entry; mixed-format catalogs are supported)?
7. **CloudFront + lifecycle.** Front `rips/stems/` (or all `rips/`) with the existing CloudFront distribution to cut stem-streaming egress? Apply Standard-IA after ~30 d + expire after ~90–180 d on the regenerable `rips/stems/` prefix?
8. **PWA.** Confirm the deployed React PWA is out of scope for v1 (native is the sole creation surface) — or should a `Stemify` action land in `ItemCard.tsx`/`SetlistView.tsx` in this PR too?
9. **Model pinning.** Stay strictly 4-stem (`htdemucs`/`hdemucs_mmi`/`mdx_extra`) for v1; `htdemucs_6s` (guitar/piano) only behind a schema-version bump + widened `STEM_NAMES`. Confirm.