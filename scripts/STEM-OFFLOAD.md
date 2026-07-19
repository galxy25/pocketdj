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
| `scripts/stem-worker.mjs` | Worker. `<songId>` one-shot · `--serve` long-running SQS consumer · `--poll` one message. Pulls the source audio using the **S3 key carried in the job** (`srcKey` — analog songs use their per-song cut `rips/<id>.cut.mp3`, digital use `rips/<id>.mp3`), runs Demucs (same `separate-one.py` + `STEM_*` contract as `lib/audio-stem.mjs`), uploads 4 stems, posts the result to the results queue, deletes the job. A failed job is left un-deleted → redelivered → DLQ after 3 tries. |
| `scripts/stem-autoscaler.mjs` | Scale-**up** controller. `reconcile` launches workers from the launch template based on `ApproximateNumberOfMessages`. `--enqueue` sends jobs to SQS (rip-server calls the same). `--status` dry-run. Never scales down. |
| `scripts/stem-sqs-setup.mjs` | Idempotent SQS setup: creates the jobs queue (redrive→DLQ, 900s visibility), results queue, DLQ. |
| `scripts/stem-worker-userdata.sh` | Launch-template boot: fetch worker code from `s3://…/worker-code/`, `--serve`, then `shutdown` (instance launches with `InstanceInitiatedShutdownBehavior=terminate`). |
| Golden AMI / launch template / IAM role / SG / keypair | `pocketdj-stem-worker`: m7i.large, code fetched from S3 at boot, IAM scoped to the rips bucket + the 3 SQS queues. |
| `rip-server.mjs` (`CFG.stemOffload`, default on) | `offloadStem()` sends manifest-song jobs to SQS instead of running demucs inline; `pumpStemResults()` folds worker results into `manifest.json`; `pumpStemDlq()` fails dead-lettered jobs. **Uploaded custom audio (`/stemify-custom`) still separates locally.** Set `POCKETDJ_STEM_OFFLOAD=0` to revert. |

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
