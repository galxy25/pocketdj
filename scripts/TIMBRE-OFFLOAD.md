# Cloud timbre analysis

The 14-axis timbre vector the recommendation engine scores against, produced **in the cloud**.
Local Docker is retired for batch work: it is the calibration reference, not the compute.

## Why a second fleet rather than a `tasks:['timbre']` branch on the stem worker

Reusing the stem lane's *transport* is right, and every mechanism below is copied from it. Reusing
its *fleet* is not:

1. **Architecture.** The 12,395 existing vectors were measured inside the **arm64**
   `pocketdj-audio` image. The stem fleet is **x86_64 m7i** and cannot run it without qemu.
2. **Unpinned environment.** `stem-worker-userdata.sh` `pip install`s librosa unpinned, at boot,
   outside Docker. That produces plausible vectors *in a different numeric space* — the one thing
   the correctness constraint forbids.
3. **Warm batch.** One SQS message per song = one python process per song = the 14 s cold path
   `timbre-warm-worker.py` exists to avoid (93 % of naive per-song cost is warm-up).

Separate **queues** for the same reason, plus a sharper one: a timbre job on `pocketdj-stem-jobs`
would be *claimed* by a stem worker, fall through `processJob` with no matching branch, post an
empty `{ok:true}` result and **delete the message**. The job vanishes, the DLQ stays empty, and
nothing looks wrong.

## The parity argument

The worker does not re-implement analysis. It writes the batch to a tasks file and runs the **same
driver** that measured the existing corpus — `timbre-batch.mjs --tasks` — inside the **same image**
(a `docker save` tarball of the very image the Mac used, fingerprint asserted at boot), with the
same ranged 5 MB GET and the same 90 s window.

Measured 2026-08-25 over 120 stratified songs that already had local vectors: **1,680 axis-values,
zero differences, max |Δ| = 0.** Graviton3 and Apple Silicon produce bit-identical vectors here.

The fingerprint is **`RootFS.Layers` + `Config.Env`**, not the image ID: a `save`/`load` round-trip
legitimately rewrites the image config (and therefore the ID) while the layers are bit-identical.
The first boot of this template failed exactly that way. Layers are content addresses of the
filesystem librosa runs from; `Config.Env` carries the five `*_NUM_THREADS` vars, which are on the
numeric path because a multi-threaded BLAS changes reduction order.

## Pieces

| Path | Role |
|---|---|
| `timbre-sqs-setup.mjs` | creates `pocketdj-timbre-{jobs,results,jobs-dlq}` (idempotent) |
| `timbre-deploy-worker.sh` | pushes worker code + image tarball + fingerprint to `worker-code/` |
| `timbre-worker-userdata.sh` | launch-template boot: docker + node, verify fingerprint, `--serve` |
| `timbre-worker.mjs` | SQS consumer; dedup, run the driver, upload sidecars, post the summary |
| `timbre-batch.mjs --tasks` | the unchanged warm-batch driver, fed a supplied work list |
| `stem-autoscaler.mjs --lane timbre` | scale-up controller, with the cross-lane vCPU guard |
| `timbre-backfill.mjs` | operator enqueue against the S3 manifest |
| `fold-cloud-timbre.mjs` | S3 sidecars → `results/cloud.ndjson` |
| `timbre-coverage.mjs` | the coverage/freeze report |
| `timbre-parity-{enqueue,check}.mjs` | the gate that must pass before any backfill |

Compute: `c7g.2xlarge` (Graviton3, 8 vCPU), **8 warm shards per instance**, max 3 instances.

## Idempotence — four independent layers

1. **`wantTimbre`** (server/CLI): a song analysed at the current version is never enqueued.
2. **Worker dedup**: one S3 prefix listing per batch. Sidecars are **version-prefixed**
   (`rips/timbre/v<N>/<id>.json`), so a `TIMBRE_VERSION` bump invalidates all of them for free.
3. **The SQS claim**: sidecars upload *as each song finishes*, so a crashed or scaled-in worker's
   redelivery re-runs only what was actually in flight.
4. **`foldTimbre`'s LWW**: a re-analysis replaces, never accumulates.

`~/.pocketdj/timbre-batch/state.json` semantics are **unchanged** — it was always a per-run
snapshot, never durable state. The durable state is `results/*.ndjson`; the cloud appends
`results/cloud.ndjson`, and because both `loadDone()` and `readResults()` glob `*.ndjson`, no code
in either changed. **Rollback is `rm results/cloud.ndjson && node scripts/fold-timbre.mjs`** — the
corpus returns byte-exact to the locally-measured rows.

## Runbook

```sh
export AWS_PROFILE=levi
node scripts/timbre-sqs-setup.mjs
bash scripts/timbre-deploy-worker.sh --image        # --image only when the image itself changed

# GATE — never skip; a mixed-provenance corpus corrupts every comparison silently
node scripts/timbre-parity-enqueue.mjs --n 120
node scripts/stem-autoscaler.mjs --lane timbre
node scripts/timbre-parity-check.mjs                # exits 1 on FAIL

# BACKFILL
node scripts/timbre-backfill.mjs --manifest s3 --dry-run
node scripts/timbre-backfill.mjs --manifest s3
node scripts/stem-autoscaler.mjs --lane timbre      # repeat until the queue drains

# FOLD (order matters: aliases BEFORE the fold — analysed songs flip from alias source to target)
node scripts/fold-cloud-timbre.mjs
node scripts/build-timbre-aliases.mjs
node scripts/fold-timbre.mjs
node scripts/build-rec-features.mjs
node scripts/timbre-coverage.mjs

# CONFIRM SCALE-TO-ZERO
aws ec2 describe-instances --filters Name=tag:pocketdj-timbre-worker,Values=1 \
  Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId'
```

A boot failure ships its log to `s3://pocketdj-rips-011183829623/worker-logs/<instance>.log` —
a worker that dies during boot terminates itself and leaves an empty EC2 console.

## The ongoing path (event-driven, no new credential)

| | Trigger | Where |
|---|---|---|
| T1 | on capture / on cut / on ingest | `rip-server.mjs` beside `enqueueAnalysis` |
| T2 | on add-to-collection | `CollectionsStore.save()` → `TimbreEnrollment` → `POST /analyze-timbre` |
| T3 | backstop sweep, 6 h + at startup | `rip-server.mjs` `sweepTimbre()` |
| T4 | publish the corpus | `am-sync-nightly.sh` fold step |
| T5 | freeze signal | `/health.timbre`, the backlog log line, `timbre-coverage.mjs` |

T3 lives **inside the rip server** — already running, already holding the manifest and its
credentials — deliberately. `install-rec-audio-nightly.sh` was never run and its job is a no-op
until `~/.pocketdj/rec-audio.env` holds `REC_ENGINE_BASE` + `REC_ENROLL_SECRET`, which that script
cannot invent. A nightly gated on an empty credential file is precisely how this froze for 14 days.

T2 hangs off **persistence**, not off the add buttons: `addSongs(_:to:)` misses
`MusicWithFriendsStore`'s direct `addSong(_:toPocket:)` and `CarPlayModel`'s own add, so a
per-call-site hook is incomplete *today*. `save()` is the one funnel every mutation shares.
