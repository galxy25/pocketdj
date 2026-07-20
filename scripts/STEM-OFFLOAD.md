# Cloud stem-separation offload + autoscaling

Moves Demucs stem separation **off the iMac** onto autoscaling cloud workers fed by an **SQS**
queue, so many users can stem/download in parallel. `scripts/rip-server.mjs` used to run stems
inline on the one Mac, and `realtimeCaptureActive()` deliberately **blocked stems during a
capture** (CPU/thermal contention with the latency-sensitive Apple Music capture). Stems don't
need the Mac or Apple Music — only the ripped mp3, already in the public rips bucket — so they
move here. Pure compute on already-ripped audio; the capture rig is untouched.

## Data flow

```
rip-server.mjs                SQS pocketdj-stem-jobs         stem-worker.mjs --serve (fleet)
  offloadStem() ── send ─────▶ {songId}  (900s visibility ── receive ▶ demucs htdemucs (cpu/gpu)
                               = atomic claim; 3 tries→DLQ)            ▶ upload rips/stems/<id>/*.mp3
  pumpStemResults() ◀─ recv ── SQS pocketdj-stem-results ◀── send ──── {songId,stems,stemModel,…}
    fold into manifest.json                                  delete job on success
  pumpStemDlq() ◀──── recv ─── SQS pocketdj-stem-jobs-dlq (poison jobs → mark job errored)

stem-autoscaler.mjs (cron ~60s): reads jobs-queue depth, launches
  min(MAX, ceil(visible/JOBS_PER_WORKER)) workers.  Workers self-retire on idle → scale to zero.
```

## Components

| Piece | What it is |
|---|---|
| `scripts/stem-worker.mjs` | Worker. `<songId>` one-shot · `--serve` long-running SQS consumer · `--poll` one message. Pulls the source audio using the **S3 key carried in the job** (`srcKey` — analog songs use their per-song cut `rips/<id>.cut.mp3`, digital use `rips/<id>.mp3`), runs Demucs (same `separate-one.py` + `STEM_*` contract as `lib/audio-stem.mjs`), uploads 4 stems, posts the result to the results queue, deletes the job. A failed job is left un-deleted → redelivered → DLQ after 3 tries. Also runs the `analysis` and `lyrics` tasks (see below). |
| `scripts/transcribe-one.py` | faster-whisper over ONE vocals stem → prints one JSON line `{version,model,lang,durationMs,words:[{text,startMs,endMs}]}` (the `runPyJson` last-line contract). Model/device/compute from `LYRICS_MODEL` (small) / `LYRICS_DEVICE` (cpu) / `LYRICS_COMPUTE` (int8). `word_timestamps` + `vad_filter`. |
| `scripts/stem-autoscaler.mjs` | Scale-**up** controller. `reconcile` launches workers from the launch template based on `ApproximateNumberOfMessages`. `--enqueue` sends jobs to SQS (rip-server calls the same). `--status` dry-run. Never scales down. |
| `scripts/stem-sqs-setup.mjs` | Idempotent SQS setup: creates the jobs queue (redrive→DLQ, 900s visibility), results queue, DLQ. |
| `scripts/stem-worker-userdata.sh` | Launch-template boot: fetch worker code from `s3://…/worker-code/`, `--serve`, then `shutdown` (instance launches with `InstanceInitiatedShutdownBehavior=terminate`). |
| Golden AMI / launch template / IAM role / SG / keypair | `pocketdj-stem-worker`: m7i.large, code fetched from S3 at boot, IAM scoped to the rips bucket + the 3 SQS queues. |
| `rip-server.mjs` (`CFG.stemOffload`, default on) | `offloadStem()` sends manifest-song jobs to SQS instead of running demucs inline; `pumpStemResults()` folds worker results into `manifest.json`; `pumpStemDlq()` fails dead-lettered jobs. **Uploaded custom audio (`/stemify-custom`) still separates locally.** Set `POCKETDJ_STEM_OFFLOAD=0` to revert. |
| `rip-server.mjs` (`CFG.lyricsOffload`, follows stemOffload) | `offloadLyrics()` fire-and-forget lyrics jobs; `pumpStemResults()` folds the lyrics result; `/backfill-lyrics` + `/lyricsify` trigger. Set `POCKETDJ_LYRICS_OFFLOAD=0/1` to override. See **Lyrics task** below. |

## Lyrics task (timed transcription)

A **separate, fire-and-forget** job (`tasks:['lyrics']`) that transcribes a song's **vocals stem**
into timed words with faster-whisper. Split from stems (not bundled) so it can't blow the 1800s
queue visibility timeout on a long song; the worker still handles a combined `['stems','lyrics']`
job correctly, reusing the vocals stem it just produced instead of re-downloading it.

```
pumpStemResults folds stems ─┐
/backfill-lyrics (all)       ├─▶ offloadLyrics(id) ── send ─▶ SQS {songId,srcKey,tasks:['lyrics']}
/lyricsify {songId}          ┘                                        │
                                                                      ▼  stem-worker doLyrics()
   rips/lyrics/<id>.json  ◀── upload ── faster-whisper(vocals) ◀── vocals stem (local reuse | S3 cp)
        ▲                                                             │
        └── pumpStemResults folds {lyrics,lyricsModel,lyricsVersion} ─┘ (result posted, job deleted)
```

- **Job message:** `{songId, srcKey, tasks:['lyrics']}` (`srcKey` carried for consistency; the worker
  reads the vocals stem, not `srcKey`). **Result message:** `{ok, songId, tasks, workerSeconds,
  lyrics:{lyrics:<key>, lyricsModel, lyricsVersion, deduped?}}` — the `lyrics` field is **nested**
  (like `analysis`), so the stems / analysis / lyrics fold branches stay independent.
- **Vocals source:** the just-produced local `work/vocals.<ext>` on a combined stems+lyrics job,
  else `aws s3 cp rips/stems/<id>/vocals.<ext>`. A missing vocals stem **throws** → DLQ (the server
  only enqueues lyrics once stems exist).
- **Worker DEDUP:** `existingLyrics()` does `aws s3 ls rips/lyrics/<id>.json` and skips whisper +
  re-posts the key unless the job carries `dedup:false` (mirrors `existingStems`).
- **S3 sidecar** `rips/lyrics/<id>.json` (public rips bucket, `application/json`):
  ```json
  {"version":1,"model":"faster-whisper-small","lang":"en","durationMs":215000,
   "words":[{"text":"hello","startMs":1200,"endMs":1440}, ...]}
  ```
  Words are trimmed/non-empty; `startMs` is clamped monotonically non-decreasing; `endMs >= startMs`.
  **Lines are derived client-side** (`DemuxLine.lines(from:)`), so the file only carries words. The
  vocals stem is **cut-derived (song-relative)**, so word timestamps need **no extra offset** — they
  are already relative to the song's start, whether it was a digital rip or an analog per-song cut.
- **Manifest fold** (`pumpStemResults`): stamps `e.lyrics` (the S3 key), `e.lyricsModel`,
  `e.lyricsVersion`, `e.lyricsAt`. `LYRICS_VERSION = 1` (kept in sync between `stem-worker.mjs` and
  `rip-server.mjs`); a bump re-runs stale sidecars via `/backfill-lyrics`. Distinct from the
  catalog's untimed `song.lyrics` text (web bucket `/lyrics/<id>.txt`, `lyrics-cdn.sh`).
- **Enqueue triggers:** (a) automatically after a stems result folds, if the song has vocals and
  no fresh lyrics (`wantLyrics`); (b) `GET|POST /backfill-lyrics` (admin) — every stemmed song
  without fresh lyrics, candidate-capped (`confirmLarge` to sweep the corpus); (c) `POST /lyricsify
  {songId, force?}` (admin) — one song: 404 if unknown, 400 if no vocals stem, already-done if
  fresh (unless `force:true`), else queued.
- **Env:** `POCKETDJ_LYRICS_MODEL` (small), `POCKETDJ_LYRICS_DEVICE` (cpu), `POCKETDJ_LYRICS_COMPUTE`
  (int8); `POCKETDJ_LYRICS_OFFLOAD` follows `POCKETDJ_STEM_OFFLOAD` when unset.
- **Dedup override:** `offloadLyrics` sends `dedup:false` when the caller forces (`/lyricsify
  {force:true}`) or the manifest's sidecar is version-stale — the worker's skip-if-exists would
  otherwise re-stamp the OLD sidecar as current (the `offloadStem dedup:!stale` contract). A worker
  DEDUP result carries no model; the fold keeps the previously-folded `lyricsModel`.
- **AUTO PIPELINE (default):** every fresh rip runs `acceptStem` alongside analysis
  (`CFG.autoStemOnRip`, follows `POCKETDJ_STEM_OFFLOAD`; `POCKETDJ_AUTO_STEM_ON_RIP=0` reverts), and
  every stems fold auto-enqueues lyrics — so a newly ripped or demuxed song lands with stems +
  analysis + timed lyrics, zero taps. The fold pump runs when ANY offload family is on, so lyrics
  results still fold with `POCKETDJ_STEM_OFFLOAD=0`.
- **Catalog fold:** `node scripts/fold-cloud-lyrics.mjs [--apply] [--upload dev,prod]` surfaces the
  timed sidecars in the CATALOG lyrics system (song detail cards): every transcript song gets
  `lyricsStatus='found'` + `lyricsSource='whisper'` and a derived plain-text `/lyrics/<id>.txt` on
  the web CDN. **WHISPER WINS** (Levi 2026-07-19): a transcript REPLACES scraped lyrics (index +
  CDN overwrite); `lyricsSource='manual'` is the ONE protected source. Scraped text survives only
  as the interim fallback on songs with no transcript yet — the scraper pipeline is retired as a
  lyrics source. Empty transcripts never erase lyrics. Additive copy — never `--delete` (the
  fallback corpus shares the prefix). Idempotent — re-run after each backfill wave.
- **Deploy** (at ship time, not now): upload `stem-worker.mjs` **and** `transcribe-one.py` to
  `s3://pocketdj-rips-011183829623/worker-code/`; the userdata pip-installs `faster-whisper` and the
  **first** lyrics job downloads the CTranslate2 model from HuggingFace (no AMI re-bake; bake the
  model into the AMI later for boot determinism).

## Scaling model

- **Up:** the autoscaler launches workers when `pocketdj-stem-jobs` has visible messages. (SQS
  `ApproximateNumberOfMessages` is eventually consistent — a just-sent message can read 0 for a
  moment; a periodic reconcile catches it on the next tick.)
- **Down / to zero:** the autoscaler never terminates. Each `--serve` worker exits after
  `IDLE_SECONDS` with an empty queue → `shutdown` → terminate. Fleet drains to zero on its own.

## Run it

```
node scripts/stem-sqs-setup.mjs                       # one-time: create the queues
node scripts/stem-autoscaler.mjs --enqueue sng_… sng_… # enqueue (rip-server does this on /stemify)
node scripts/stem-autoscaler.mjs                        # reconcile (one pass)
node scripts/stem-autoscaler.mjs --status              # peek queue + fleet, no launch

# install the autoscaler on a 60s schedule (LaunchAgent — required for hands-off processing):
cp scripts/launchd/com.pocketdj.stem-autoscaler.plist ~/Library/LaunchAgents/ && \
  launchctl load ~/Library/LaunchAgents/com.pocketdj.stem-autoscaler.plist
```

The rip server (`com.pocketdj.ripserver`) runs the offload by default (`CFG.stemOffload`); its
`pumpStemResults`/`pumpStemDlq` loops fold worker results into `manifest.json`. Restart it after a
worker-code change only if you also changed the rip-server integration — the workers fetch their
code fresh from `s3://…/worker-code/` each boot.

## Proven (us-west-2, account 011183829623)

- Worker end-to-end: `sng_3be2079ad5e3` (86 s) → htdemucs on **c7i.xlarge CPU in 69 s**;
  `sng_d7acf460d1b0` (104 s) → **m7i.large CPU in 204 s**. 4 distinct stems each.
- Autoscaling: 3-job backlog → 2 workers → distinct claims → all stemmed → fleet 0→2→0.
- SQS: job received (visibility-timeout claim), stems uploaded, well-formed result posted to the
  results queue, job deleted, fleet drained to 0.

## Caveats / hardening

- **Quota:** the account's EC2 standard vCPU quota is 5 and GPU (G) quota is 0 (increases to 64 /
  16 requested). The prototype caps at ~2 × m7i.large on CPU; GPU (g5/g4dn, `POCKETDJ_STEM_DEVICE=cuda`)
  cuts a separation to ~5–10 s once quota lands.
- **Torch:** the AMI pulled the CUDA torch build; on CPU-only workers install the CPU wheel
  (`pip install torch --index-url https://download.pytorch.org/whl/cpu`) to shrink the AMI.
- **Idempotency:** a rip-server restart re-sends outstanding wants to SQS (SQS may still hold the
  originals) → at worst a duplicate separation; folding a duplicate result is idempotent (same keys).
- **Custom audio** (`/stemify-custom`, Studio/Demuxer ids) is intentionally **not** offloaded — the
  audio is uploaded to the server, not in the rips bucket, so it separates locally.
```
