# Cloud stem-separation offload + autoscaling

Moves Demucs stem separation **off the iMac** onto autoscaling cloud workers, so many users can
stem/download in parallel. Today `scripts/rip-server.mjs` runs stems inline on the one Mac, and
`realtimeCaptureActive()` deliberately **blocks stems during a capture** (CPU/thermal contention
with the latency-sensitive Apple Music capture). Stems don't need the Mac or Apple Music at all —
they only need the ripped mp3, which already lives in the public rips bucket — so they move here.

This offload is pure compute on audio the account already possesses. It does **not** capture or
redistribute any streaming content; the capture rig stays exactly where it is.

## Data flow

```
rip-server (enqueue)  ─▶  S3 job queue                 ─▶  workers (claim → stem → upload)
  stem-autoscaler.mjs      rips/stem-jobs/<id>.job.json      stem-worker.mjs --serve
  --enqueue <id>              │  (claim = mv to .claimed.json)   │  demucs htdemucs, cpu/gpu
                             ▼                                   ▼
  stem-autoscaler.mjs   fleet sized to backlog             rips/stems/<id>/{vocals,drums,bass,other}.mp3
  reconcile (cron)      up on queue depth                  rips/stem-jobs/<id>.result.json  ← manifest stamp
                        down on idle (workers self-retire)
```

## Components

| Piece | What it is |
|---|---|
| `scripts/stem-worker.mjs` | The worker. `<songId>` one-shot · `--poll` drain-once · `--serve` long-running poll+idle-exit. Pulls `rips/<id>.mp3`, runs Demucs (same `separate-one.py` + `STEM_*` contract as `lib/audio-stem.mjs`), uploads 4 stems, writes a `.result.json` manifest stamp. |
| `scripts/stem-autoscaler.mjs` | Scale-**up** controller. `reconcile` launches `min(MAX, ceil(queue/JOBS_PER_WORKER))` workers from the launch template. `--enqueue` drops job markers (rip-server calls the same). `--status` dry-run. Never scales down. |
| `scripts/stem-worker-userdata.sh` | Launch-template boot script: run `--serve`, then `shutdown -h now` (instance launches with `InstanceInitiatedShutdownBehavior=terminate` → scale to zero). |
| Golden AMI | Ubuntu 22.04 + ffmpeg + node 20 + python venv w/ demucs + the worker, baked so scale-up is ~1 min (no per-boot install). |
| Launch template / IAM role / SG | `pocketdj-stem-worker`: m7i.large, least-privilege S3 role (get/put/list on the rips bucket only), SSH from the operator IP. |

## Scaling model

- **Up:** the autoscaler runs on a schedule (launchd/cron ~60s or a Lambda) and launches workers
  when `rips/stem-jobs/` has pending `.job.json` markers. In-progress songs are renamed to
  `.claimed.json`, so they don't count as backlog and don't trigger redundant launches.
- **Down / to zero:** the autoscaler never terminates. Each worker, after `IDLE_SECONDS` with an
  empty queue, exits `--serve` → `shutdown` → terminate. Fleet drains to zero on its own.

## Run it

```
# enqueue work (rip-server would call this when a user requests stems)
node scripts/stem-autoscaler.mjs --enqueue sng_aaaa... sng_bbbb...
# one reconcile pass (or put on a 60s schedule)
node scripts/stem-autoscaler.mjs
node scripts/stem-autoscaler.mjs --status      # peek without launching
```

## Proven (prototype, 2026-07-19, us-west-2, account 011183829623)

- End-to-end on `sng_3be2079ad5e3` (86 s): download → **htdemucs on CPU in 69 s** → 4 distinct
  stems uploaded to `rips/stems/…` (`audio/mpeg`, distinct ETags). Fully off the Mac.
- Bucket `pocketdj-rips-011183829623`; worker instance `c7i.xlarge`, fleet `m7i.large`.

## Caveats / production hardening

- **Queue:** the S3-marker queue's `mv`-claim is not truly atomic. Fine for a small fleet; for
  real fan-out front it with **SQS** (visibility-timeout = exactly-once claim, native depth metric
  for the autoscaler / an ASG target-tracking policy) or an S3 conditional PUT (`If-None-Match`).
- **Quota:** this account's EC2 **standard vCPU quota is 5** and **GPU (G) quota is 0**, so the
  prototype caps at ~2 × m7i.large workers and runs Demucs on **CPU**. For real throughput request
  a quota increase; GPU (g5/g4dn) cuts a separation from ~60 s to ~5–10 s. The code is device-agnostic
  (`POCKETDJ_STEM_DEVICE=cuda`).
- **Torch:** the box pulled the CUDA torch build; on CPU-only workers install the CPU wheel
  (`pip install torch --index-url https://download.pytorch.org/whl/cpu`) to shrink the AMI.
- **Remaining wiring:** a coordinator in `rip-server.mjs` should (a) `--enqueue` instead of running
  stems inline, and (b) fold each `.result.json` into `manifest.json` via `saveManifest` (mirrors
  the current inline stamp: `stems`/`stemModel`/`stemVersion`/`stemFormat`/`stemmedAt`/`stemBytes`).
```
