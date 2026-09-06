# Cloud stem-separation offload + autoscaling

Moves Demucs stem separation **off the iMac** onto autoscaling cloud workers fed by an **SQS**
queue, so many users can stem/download in parallel. `scripts/rip-server.mjs` used to run stems
inline on the one Mac, and `realtimeCaptureActive()` deliberately **blocked stems during a
capture** (CPU/thermal contention with the latency-sensitive Apple Music capture). Stems don't
need the Mac or Apple Music — only the ripped mp3, already in the public rips bucket — so they
move here. Pure compute on already-ripped audio; the capture rig is untouched.

## Data flow

```
rip-server.mjs                SQS pocketdj-stem-jobs         stem-worker.mjs --serve (SPOT fleet)
  offloadStem() ── send ─────▶ {songId} (1800s visibility ── receive ▶ demucs htdemucs (cpu/gpu)
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
| `scripts/stem-sqs-setup.mjs` | Idempotent SQS setup: creates the jobs queue (redrive→DLQ, 1800s visibility), results queue, DLQ. |
| `scripts/stem-spot-setup.mjs` | Spot + network **inspector and template surgeon**. `--status` (read-only, and the bare default) prints the market config, the **spot vCPU quota beside the lane's `maxWorkers`** so the Problem-1 mismatch is visible at a glance, the network shape (pinned vs multi-AZ) with every subnet and its public flag, live per-AZ spot prices, the worker role's SQS grants, and whether the deployed worker was verified. `--multi-az` restructures the template so `run-instances` can choose a subnet; `--apply` moves spot options INTO the template (rarely wanted); `--revert` puts **both** back — on-demand *and* the single pinned subnet — in one version. |
| `scripts/stem-worker-userdata.sh` | Launch-template boot: fetch worker code from `s3://…/worker-code/`, `--serve`, then `shutdown` (instance launches with `InstanceInitiatedShutdownBehavior=terminate`). |
| `scripts/stem-deploy-worker.sh` | **Pushes the worker code to `s3://…/worker-code/`** — the step the userdata's `aws s3 cp` depends on, and the thing that closes the rollout race. Reads every object **back** from S3 and compares byte-for-byte (an `aws s3 cp` exit code proves nothing), asserts the read-back worker carries the interruption path, cross-checks that FILES still covers everything userdata fetches, and stamps `x-amz-meta-spot-aware=yes` **only after** that verification passes. `--check` answers "what is deployed right now" and exits non-zero on any drift. |
| Golden AMI / launch template / IAM role / SG / keypair | `pocketdj-stem-worker`: m7i.large, code fetched from S3 at boot, IAM scoped to the rips bucket + the 3 SQS queues. Historically pinned to `subnet-00a23032877bbe190` (us-west-2a) — one AZ, so **one spot pool**; the autoscaler now spreads across all four (see **Multi-AZ** below). The template itself is **market-neutral**: the autoscaler asks for spot per launch, which is what leaves it room to retry on-demand. |
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
- **Sideways (spot reclaim):** EC2 may terminate a worker mid-job. That is just an early
  "down" — the job is still on the queue and comes back. See **Spot fleet** below.

## Spot fleet

The stem workers run on **spot**. Almost nothing had to change to make that safe — **the queue
already owned the job, not the instance**, so a reclaimed worker is indistinguishable from a worker
that crashed, and that path was load-bearing from day one.

- A message is claimed by the **1800 s visibility timeout**, not by a lease the instance holds.
- The worker deletes the message only **after** the result is posted (`poll()`), so an instance
  that dies mid-Demucs leaves the job un-deleted by construction.
- A stems job only counts as done when **all 4** stems are on S3 (`stemsFromListing`), so the 1–3
  stems a reclaimed instance may have uploaded can never read as a finished job.
- Worst case, an un-deleted job goes visible again after the visibility timeout and is redelivered;
  three receives without a delete send it to the DLQ, where `pumpStemDlq()` marks it errored.

**Where the market is chosen:** `stem-autoscaler.mjs` passes `--instance-market-options` on
`run-instances` (`LANES.stem.market = 'spot'`, `POCKETDJ_STEM_MARKET` to override). It is
requested **per launch, not baked into the launch template** — deliberately, because that is what
keeps the on-demand fallback possible (see *Template-level switch* below). The same call chooses
the **subnet** per launch, so the market and the AZ are both scheduling decisions this controller
owns. The timbre lane stays on-demand: its message is a 50-song batch, so an interruption throws
away far more than one song.

**Four things had to be true** for the switch to actually save money rather than quietly cost it,
and each is its own section below: the worker must handle a reclaim (*it does, and the queue
already made it safe*), the spot ask must respect the **separate spot quota** (*Ceiling*), the
fleet must not depend on one AZ's pool (*Multi-AZ*), and the on-demand fallback must be **bounded
and loud** (*fallback budget*). Getting any one of them wrong turns a 60% saving into a 2.7×
bill — three of them did, in the first cut.

```
spot reclaim notice at IMDS /latest/meta-data/spot/instance-action (~2 min warning)
   │  stem-worker.mjs --serve polls it every 5s (armSpotWatch; inert off EC2 and on on-demand)
   ▼
releaseInflight() ─▶ RE-SEND the job as a new message (fresh ApproximateReceiveCount, hop counter
   │                 `spotRequeues` ≤3 in the body), then delete the old one — send BEFORE delete,
   │                 so a failure costs a duplicate (dedup eats it), never a lost job
   ├─ past the hop cap / unparseable body ─▶ ChangeMessageVisibility(0): instantly visible again,
   │                 receive count keeps climbing so the DLQ stays reachable
   └─ release itself fails ─▶ the job simply redelivers after the 1800s visibility timeout
                              (the un-handled path — correct, just slow)
next reconcile (~60s) launches a replacement if the backlog needs one ─▶ separation re-runs whole
```

**Two prerequisites, both silent when missing** — `stem-spot-setup.mjs` (bare run) checks the
second, `stem-deploy-worker.sh --check` the first:

1. **The worker code must be DEPLOYED — and the autoscaler enforces it.** The launch template's
   userdata copies `stem-worker.mjs` from `s3://…/worker-code/` on every boot, so **the workers do
   not run this repo's file** and everything above is dead code until
   `bash scripts/stem-deploy-worker.sh` has run. This was a live trap, not a hypothetical: the
   deployed object was dated **2026-07-20**, was 16,625 bytes against the repo's 32,400, and
   contained **zero** occurrences of `instance-action`. Merging the branch would have flipped the
   fleet to spot on the LaunchAgent's next 60 s tick while every booting worker was spot-blind —
   each reclaim stranding its job for the full 1800 s AND spending one of the three deliveries, so
   three unlucky reclaims dead-letter a song that never failed and `pumpStemDlq()` marks it
   errored permanently.

   **Closed in code, not in a checklist.** Before requesting spot, `stem-autoscaler.mjs` reads the
   deployed object and refuses unless the body contains `spot/instance-action`. The result is
   cached across the 60 s cadence and re-validated by **ETag**, so the usual tick costs one HEAD
   and no download. It **fails safe**: an unreadable object, an unparseable URI, or an expired
   grace window all resolve to *on-demand*, never to spot. `POCKETDJ_STEM_WORKER_CODE` points at
   the object; `POCKETDJ_WORKER_CHECK_TTL_SEC` / `..._GRACE_SEC` tune the cache.

   Deploying early is always safe — the spot code is inert on an on-demand instance (IMDS answers
   404 forever, `armSpotWatch` logs and stands down) — so the ordering has no downside.
2. **The worker role needs `sqs:ChangeMessageVisibility` on the jobs queue.** The re-send branch
   only needs `SendMessage`+`DeleteMessage` (both already granted), but every FALLBACK —
   unparseable body, past the hop cap, or a re-send that itself failed — calls
   `ChangeMessageVisibility(0)`. Without the grant those branches end in `STRANDED` and degrade
   silently to the pre-spot 1800 s wait. `node scripts/stem-spot-setup.mjs` simulates the role and
   prints the exact `put-role-policy` fix.

- **What an interruption actually costs:** the wasted CPU minutes of one separation (~3.5 min on
  m7i.large) and **seconds** of latency — the watcher hands the job back before the box dies. Only
  when the release fails does it become the ≤30 min visibility-timeout wait.
- **Why the re-send instead of just visibility-0:** SQS offers no way to give back a delivery
  attempt. With `maxReceiveCount: 3`, a song reclaimed three times would be dead-lettered with
  nothing wrong with it. A new message is the only reset SQS actually has — bounded at 3 hops so a
  job that keeps being released can still reach the DLQ instead of circling forever.
- **A duplicate is harmless, a lost job is not** — hence send-then-delete. `existingStems` /
  `existingLyrics` skip the re-run and folding a duplicate result is idempotent (same keys).
- **A finished job is DELETED, not re-sent.** The notice can land in the window between "result
  posted to the results queue" and "job deleted"; re-sending there would buy a duplicate separation
  for a song that is already stemmed, so `releasePlan` deletes once `resultPosted` is set.
- **A job that FAILED on its own merits is not requeued** — it keeps its normal receive count and
  its normal march to the DLQ, so a reclaim can never reset a poison job's attempts. Residual: that
  job still waits out the full visibility timeout before redelivery, exactly as it did pre-spot.
- **Partial uploads cannot masquerade as done.** `s3 cp` is one atomic `PutObject` under the
  multipart threshold, and above it the object only materialises at `CompleteMultipartUpload` — so
  no truncated stem can appear, and a partial *set* is caught by the all-4 gate. The residual is
  **cost, not correctness**: an interrupted multipart upload leaves orphaned parts that bill until
  aborted. The rips bucket has **no lifecycle rule** today; add an `AbortIncompleteMultipartUpload`
  rule (7 days) once reclaims are routine. `aws s3api list-multipart-uploads --bucket
  pocketdj-rips-011183829623` reads the current orphan count (0 at the time of the switch).

**Request shape** — `MarketType=spot`, `SpotInstanceType=one-time`, `InstanceInterruptionBehavior=terminate`, **no `MaxPrice`**:

| Field | Why this value |
|---|---|
| `one-time` | **Not `persistent`.** A persistent request re-launches after *any* termination — including a worker that self-retired on idle — which would fight scale-to-zero and bill forever. One-time leaves the autoscaler as the only thing that decides to launch. |
| `terminate` | The only interruption behavior a one-time request allows (`stop`/`hibernate` need `persistent`), and the one the fleet wants: workers are disposable and `InstanceInitiatedShutdownBehavior` is already `terminate`. |
| no `MaxPrice` | An unset max bids the **on-demand** price, so the bill can never exceed today's and a price spike degrades to on-demand economics instead of leaving a backlog with an un-launchable fleet. |

**Fallback.** When spot refuses for **capacity** reasons — `InsufficientInstanceCapacity`,
`InsufficientHostCapacity`, `SpotMaxPriceTooLow`, `MaxSpotInstanceCountExceeded` —
`launch()` immediately retries the same launch **on-demand**, so a dry market slows the queue
instead of stopping it (`shouldFallbackToOnDemand`, unit-tested). Every other failure fails
identically on-demand, so it is NOT retried: a stalled queue is a cheaper way to learn about a
broken launch path than a bill. The reconcile line logs the market that actually won
(`launched 3 on on-demand: …`) — a run of those is the only warning that spot has dried up.
To leave spot entirely, `POCKETDJ_STEM_MARKET=on-demand`.

**The fallback has a BUDGET, and it shouts.** A multi-hour capacity outage used to bill at 2.7×
for as long as it lasted, capped by nothing and announced by nothing — the only instrument was
grepping a log nobody reads at 3am. The autoscaler is a **stateless 60 s LaunchAgent**, so an
in-memory counter would reset before it ever counted to two; the meter therefore lives in a small
state file, matching how the rest of the repo persists small state:

```
~/.pocketdj/stem-autoscaler/<lane>.json     # POCKETDJ_AUTOSCALER_STATE_DIR to relocate
```

**It counts instances, not incidents.** What costs money is on-demand workers started, not
consecutive failures — one fallback that starts 14 instances costs more than fourteen that start
one each. So the budget is **16 on-demand launches per rolling hour**
(`POCKETDJ_FALLBACK_BUDGET` / `POCKETDJ_FALLBACK_WINDOW_SEC`), which is generous for draining a
real backlog and caps the unattended blast radius of a total spot outage at well under a dollar an
hour.

**Exhausting the budget does not stop the pipeline.** Spot keeps being attempted every tick, so a
market that recovers drains the queue immediately; what stops is the *silent* full-price fleet.
The alarm fires once on the state change and then hourly for as long as it lasts
(`POCKETDJ_ALERT_REPEAT_SEC`), because a warning logged once four hours ago has scrolled away just
as completely as one never logged. `POCKETDJ_ALERT_CMD` receives the text in `POCKETDJ_ALERT_TEXT`
if you want it to page rather than just log.

```
grep -c 'retrying on-demand' ~/.pocketdj/stem-autoscaler.log   # fallbacks so far
grep 'launched .* on on-demand' ~/.pocketdj/stem-autoscaler.log | tail
cat ~/.pocketdj/stem-autoscaler/stem.json                      # budget spend + notice state
```

`POCKETDJ_STEM_MARKET=on-demand` (or pausing the LaunchAgent) remains the manual brake.

**Verify it is really spot** — a running worker reports a spot lifecycle (on-demand instances
report none), which is the ground truth whichever mechanism asked for it:

```
aws ec2 describe-instances --profile levi --region us-west-2 \
  --filters Name=tag:pocketdj-stem-worker,Values=1 Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceLifecycle,InstanceType]' --output text
```

**Economics** (measured August 2026: 1,148 launches, **10,988** SQS jobs completed, **3,693** songs
fully processed — stems + analysis + lyrics):

| | On-demand (billed) | Spot (same volume) |
|---|---|---|
| m7i.large, us-west-2 | $0.1008/hr | $0.0375–0.0446/hr (~56–63% off) |
| fleet hours | 426.9 | 426.9 (interruptions add a little re-work) |
| **monthly bill** | **$43.04** | **~$17–19** |
| **per song fully processed** | **1.35¢** | **~0.7¢** |
| **saved** | — | **~$24–26/mo** (≈60%) |

The per-song number is the one worth remembering: **$43.04 ÷ 3,693 songs = 1.35 cents** to take a
song from raw audio to 4 stems + analysis + timed lyrics, falling to roughly **0.7 cents** on spot.
At that unit cost the corpus is not the expensive part of this system, which is exactly why the
fallback budget is set to cap a runaway rather than to squeeze the bill.

Per-AZ prices move; `stem-spot-setup.mjs --status` prints all four live next to the on-demand
price, so the discount is never a guess.

**Networking costs, and why the public IPs stay.** An **S3 gateway endpoint**
(`vpce-0341241602a451680`) was added to the main route table `rtb-06c8f8ef5811a718f`, so
worker↔S3 traffic — every source mp3 down and every stem up, by far the largest flow — is now
private and **free** from all four AZs. It does **not** remove the need for public IPs: workers
still reach SQS, pip and HuggingFace over the internet gateway. Removing that public path costs
more than it saves:

| Option | Cost | vs the $2.19/mo of public IPv4 it would save |
|---|---|---|
| Public IPv4 today | ~$2.19/mo | baseline |
| NAT gateway | ~$32/mo + data processing | **~15× worse** |
| SQS interface endpoints | ~$7.30/mo **per AZ** (≈$29 across four) | **~13× worse** |

So the public IP is the cheap option, and the gateway endpoint already captured the part of the
bill that was actually large. Revisit only if egress volume changes shape.

**Ceiling — spot vCPU is its OWN quota, and conflating it with on-demand ran the fleet at full
price.** This is the single most expensive fact about the switch, so it is worth stating plainly:

| Quota | Code | Value | Buys |
|---|---|---|---|
| Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) | `L-1216C47A` | **64 vCPU** | 32 × m7i.large on-demand |
| All Standard (A,C,D,H,I,M,R,T,Z) **Spot** Instance Requests | `L-34B43A08` | **32 vCPU** | **16 × m7i.large on spot** |

They are **separate buckets**, not two views of one budget. The first cut of the spot switch missed
that: `LANES.stem.maxWorkers` was 30 and the launch arithmetic reasoned about
`POCKETDJ_TOTAL_VCPU_CAP` (56) — both sized against the **on-demand** 64. So on any real backlog the
autoscaler asked for more spot than the spot quota could ever grant, EC2 refused with
`MaxSpotInstanceCountExceeded`, and because that code is (correctly) in the capacity-error set, the
fallback retried on-demand.

The sharp edge is that **a run-instances quota refusal is all-or-nothing** — it does not partially
fulfil, and `--count 1:n` does not save you, because the refusal happens before any instance is
placed. So the retry relaunched the **entire** request at $0.1008 instead of just the excess above
16. A change meant to save ~60% put the fleet on **100% on-demand exactly when it was busiest**,
and nothing in the log said anything louder than `launched 20 on on-demand`.

**The fix — size the ask against the bucket it will actually draw on.** `planLaunch()` takes
`spotVcpuCap` (32) and `onDemandVcpuCap` (64) as *separate* budgets and caps the spot ask at what
spot can grant. Anything above that is a **`shortfall`**, reported on every pass, and by default
topped up on-demand — **the genuine excess and only the excess**. On a 300-message backlog that is
16 spot + 14 on-demand (≈$2.08/hr), against the ~28 on-demand (≈$2.82/hr) the pre-fix code bought
when spot was merely quota-capped. The 14 is metered by the fallback guard, so it cannot silently
become permanent.

Set **`POCKETDJ_ONDEMAND_TOPUP=0`** to make the lane strictly spot-only: the fleet caps at 16
(≈$0.67/hr), the shortfall is reported and left un-launched, and the queue drains more slowly. Right
for an unattended backfill, wrong for a queue somebody is waiting on. It gates only the
**quota-capped top-up** — the **capacity fallback** (spot asked and did not deliver) is a separate,
separately-metered decision and still runs. Two consequences worth internalising:

- **The two lanes now draw on different buckets.** Stem is spot, timbre is on-demand, so a single
  `totalVcpuCap` cannot express the truth: stem's 16 spot workers and timbre's 3 on-demand
  instances do not compete at all. The old single cap is kept only as a legacy alias for the
  on-demand one.
- **The fallback is for capacity, not for quota.** A quota refusal means "this bucket is full", and
  the answer to that is a bigger ask on the other bucket *or* a quota increase — never a silent
  full-price relaunch of the whole request.

Raise `L-34B43A08` to 60 vCPU to make the whole 30-worker lane cheap:

```
aws service-quotas request-service-quota-increase --service-code ec2 \
  --quota-code L-34B43A08 --desired-value 60 --profile levi
```

`stem-spot-setup.mjs --status` prints the quota, the ceiling it implies, and the lane's
`maxWorkers` **on the same screen**, with a ⚠ when they disagree — so this can be seen in five
seconds instead of reconstructed from a bill.

### Multi-AZ — four subnets, four spot pools

Spot capacity is **per availability zone**. While the launch template pinned one subnet
(`subnet-00a23032877bbe190`, us-west-2a) the fleet drew on exactly one pool, so a capacity crunch
in 2a stalled the queue or pushed everything to on-demand even though 2b/2c/2d were fine. Prices
diverge too: on the day this was measured, 2d was **$0.0376** against 2a's **$0.0442** — a 15%
spread on the same instance type, in the same region, at the same moment.

The default VPC `vpc-003b55e5582595910` has one subnet per AZ, **all public**
(`MapPublicIpOnLaunch=true`), all served by the one main route table `rtb-06c8f8ef5811a718f`:

| AZ | Subnet |
|---|---|
| us-west-2a | `subnet-00a23032877bbe190` (the one the template pinned) |
| us-west-2b | `subnet-00f9be279c616ff01` |
| us-west-2c | `subnet-0c623f93e8a27ea34` |
| us-west-2d | `subnet-055bd6cc3fb64e8b7` |

**The API constraint that shapes the design:** `RunInstances` rejects `--subnet-id` when the launch
template defines a `NetworkInterfaces` block — the API's own words are *"If you specify a network
interface, you must specify any subnets as part of the network interface instead of using this
parameter"*, and the same sentence applies to security groups. The live template defines exactly
such a block, with the subnet inside it. Getting this wrong fails **every** launch, so both legal
shapes are supported and the autoscaler detects which one it is looking at:

| Template shape | How a subnet is chosen | Notes |
|---|---|---|
| `NetworkInterfaces` present (today) | `--network-interfaces` override, restating DeviceIndex + Groups + AssociatePublicIpAddress + DeleteOnTermination | Works with **no template change**. The caller must restate the ENI, so later template edits to that block are ignored. |
| No `NetworkInterfaces`, groups at top level (`--multi-az`) | plain `--subnet-id` | The simpler shape, and the preferred one. Template stays the single source of truth. |

`networkPlan()` reads `$Latest` (cached 10 min), picks the legal call, and if the template cannot
be read at all it launches with no override — the template's own AZ. Degrade, never break. A NIC
block with **no** security groups disables the spread rather than guessing, because a NIC override
without groups silently lands the worker in the VPC default group, where it cannot reach SQS.

`node scripts/stem-spot-setup.mjs --multi-az` performs the restructure: drop the block, move the
security groups to top-level `SecurityGroupIds`. Two things make it safe to run:

- **It refuses if any subnet is private.** `AssociatePublicIpAddress` exists *only* inside a
  NetworkInterfaces block — there is no top-level equivalent — so dropping the block hands public
  addressing to the subnet's `MapPublicIpOnLaunch`. That is fine here because all four are public,
  but a private subnet in the rotation would produce workers that boot, reach nothing, and idle
  out in an AZ nobody is watching.
- **It verifies the rewrite and rolls back.** A removal cannot be merged (`--source-version`
  merges, and a merge can add a field but never remove one), so the new version is posted as
  **full** `LaunchTemplateData` built from the current `$Latest`. Since the autoscaler launches
  `$Latest`, a version that lost UserData or the IAM profile would break every launch within 60 s —
  there is no staging step. So the created version is diffed field-by-field against what was sent,
  and **deleted immediately** if anything but the two intended keys moved.

`--revert` undoes both axes in one version: on-demand market **and** the single pinned subnet. It
builds from `$Latest` too, so template edits made in the meantime (a new UserData, say) survive —
the old revert branched off an ancient version and silently dropped them.

### Template-level switch — `scripts/stem-spot-setup.mjs`

The launch template can carry the spot options itself. It is the **second** way to be on spot, and
the two must not both be on:

- **`--status`** (also the bare run, read-only): the template's market config and full version
  list, the spot vCPU quota with the instance ceiling it implies, and the live per-AZ spot price
  beside on-demand. This is the operator's answer to *are we on spot, and what is it costing today*
  — worth running whichever mechanism owns the market.
- **`--apply`** — new template version with `InstanceMarketOptions{spot}`, set as default.
  **PICK ONE MECHANISM.** `RunInstances` cannot un-set a template's market options — `MarketType`
  has no `on-demand` value — so a spot-baked template silently defeats the autoscaler's capacity
  fallback: the "on-demand" retry launches spot again and fails again. While the autoscaler owns
  the market (today's default), **leave the template on-demand**. Bake it in only if the market
  moves out of the autoscaler — a hand-run `run-instances`, a Lambda, an ASG with no fallback of
  its own — and set `POCKETDJ_STEM_MARKET=on-demand` at the same time so the two never disagree.
- **`--multi-az`** — the restructure described above: drop the `NetworkInterfaces` block, move its
  security groups to top-level `SecurityGroupIds`, so `run-instances --subnet-id` becomes legal.
  Refuses if any subnet in the VPC is private; posts full `LaunchTemplateData`, diffs the result,
  and deletes the new version if anything but the two intended keys moved.
- **`--revert`** — **both axes at once**: on-demand market *and* the single pinned subnet
  (`POCKETDJ_STEM_PIN_SUBNET`), in one new version built from `$Latest`, so unrelated template
  edits survive. It reminds you to set `POCKETDJ_STEM_MARKET=on-demand` too — reverting the
  template alone does nothing while the autoscaler still asks for spot per launch.

The autoscaler launches `Version=$Latest`, so every direction takes effect on the next reconcile —
which is also why a bad version is an outage rather than a staged change, and why the mutating
verbs verify and roll themselves back.

## RUNBOOK — turning spot on, and turning it off

**The one ordering rule: DEPLOY THE WORKER BEFORE THE AUTOSCALER ASKS FOR SPOT.** The autoscaler
defaults to `market: 'spot'`, runs from the repo on a 60 s LaunchAgent, and launches `$Latest` — so
**merging this branch is itself the deploy**, with no further command. The preflight in step 1
makes forgetting survivable rather than catastrophic (the autoscaler refuses spot for a spot-blind
fleet), but the ordering below is what makes it a non-event.

```
# ── 1. WORKER CODE FIRST — safe to run at any time, on an on-demand fleet, days early.
bash scripts/stem-deploy-worker.sh --check     # what is deployed right now? (exit 1 = drift)
bash scripts/stem-deploy-worker.sh             # push + read back + verify + stamp

# ── 2. PREFLIGHT — one read-only command answers "is it safe to go spot?"
node scripts/stem-spot-setup.mjs               # IAM grants · spot quota vs maxWorkers · network
                                               # shape · per-AZ price · deployed-worker provenance
#    Expect: ChangeMessageVisibility "ok", worker code "spot-aware=yes", and NO ⚠ MISMATCH.
#    A ⚠ MISMATCH is not a blocker — spot is capped at the ceiling and the rest simply is not
#    launched — but it is the difference between a 16-worker cheap fleet and a 30-worker one.

# ── 3. (optional, recommended) MULTI-AZ — spread across four spot pools instead of one.
node scripts/stem-spot-setup.mjs --multi-az    # restructure; self-verifies and rolls back on drift
node scripts/stem-spot-setup.mjs               # confirm: network = MULTI-AZ, all four subnets listed
#    Skipping this is fine: the autoscaler falls back to a --network-interfaces override and still
#    spreads. The restructure just makes the simpler --subnet-id path legal.

# ── 4. MERGE. The LaunchAgent picks up the new autoscaler within 60 s and spot begins.
node scripts/stem-autoscaler.mjs --status      # dry run: queue, fleet, plan, market — launches nothing

# ── 5. WATCH THE FIRST HOUR.
aws ec2 describe-instances --profile levi --region us-west-2 \
  --filters Name=tag:pocketdj-stem-worker,Values=1 Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceLifecycle,Placement.AvailabilityZone]' --output text
#    InstanceLifecycle must read "spot" (on-demand instances report nothing), and the AZ column
#    should not be all one value once there is enough backlog to need more than a couple of workers.
grep 'retrying on-demand\|fallback budget' ~/.pocketdj/stem-autoscaler.log | tail
```

**REVERTING.** The template and the autoscaler are separate switches and the autoscaler wins, so
revert the autoscaler first — that alone is the whole brake:

```
# Fastest brake (no deploy, no merge): pin the lane to on-demand and restart the agent.
launchctl setenv POCKETDJ_STEM_MARKET on-demand    # or set it in the LaunchAgent plist
launchctl kickstart -k gui/$(id -u)/com.pocketdj.stem-autoscaler

# Full revert of the TEMPLATE too — on-demand AND back to the single pinned subnet, one command:
node scripts/stem-spot-setup.mjs --revert
node scripts/stem-spot-setup.mjs                   # confirm: ON-DEMAND, network PINNED, 1-az
```

Reverting needs **no worker rollback**: the spot-aware worker is strictly a superset of the old
one and is inert on an on-demand instance. Running workers keep their code until they retire; only
the next boot picks anything up.

## Run it

```
node scripts/stem-sqs-setup.mjs                       # one-time: create the queues
node scripts/stem-spot-setup.mjs                      # read-only preflight (see RUNBOOK above)
node scripts/stem-spot-setup.mjs --multi-az           # let run-instances choose the subnet
node scripts/stem-spot-setup.mjs --apply              # move spot INTO the template (read the warning)
node scripts/stem-spot-setup.mjs --revert             # on-demand AND re-pin one subnet
bash scripts/stem-deploy-worker.sh [--check]          # deploy the worker code (see RUNBOOK above)
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

- **Quota:** the standard **on-demand** vCPU quota was raised 5 → **64** (2026-07-19), which is why
  the stem lane's `maxWorkers` is 30 (30 × 2 = 60). **Spot vCPU is a different, smaller quota** —
  **32** (`L-34B43A08`) — and the two are separate buckets, so a lane sized against the on-demand
  64 asks for roughly double what spot can grant. That is the *Ceiling* section above, and it is
  the defect that made the first cut of this change bill at full price. `planLaunch()` now sizes
  the spot ask against `POCKETDJ_SPOT_VCPU_CAP` (32) and the on-demand ask against
  `POCKETDJ_ONDEMAND_VCPU_CAP` (64) **independently**; `POCKETDJ_TOTAL_VCPU_CAP` survives only as
  a legacy alias for the on-demand cap. Because the lanes now draw on different buckets when stem
  is spot and timbre is on-demand, they no longer contend at all — the old single shared cap could
  not express that and was merely conservative. GPU (G) is still **0**: `g5`/`g4dn` with
  `POCKETDJ_STEM_DEVICE=cuda` would cut a separation to ~5–10 s if that quota ever lands.
- **Multipart orphans:** unchanged by spot in kind, more likely in frequency. An interrupted
  multipart upload leaves parts that bill until aborted; the rips bucket still has **no lifecycle
  rule**. Add `AbortIncompleteMultipartUpload` (7 days) once reclaims are routine —
  `aws s3api list-multipart-uploads --bucket pocketdj-rips-011183829623` reads the current count.
- **Graviton: decided NO for the stem lane (2026-09-06).** ARM would need an AMI re-bake — the
  fleet AMI `ami-0e042d0c5d176a86c` is x86-64, and demucs/torch need an ARM build — and the prize
  is small: `m7g.large` spot ($0.0327–0.0431) vs `m7i.large` spot ($0.0375–0.0446) is roughly
  **7%**, and in the AZ the template actually pins (us-west-2a) it was 2.5% on the day this was
  measured. A ~$1/mo edge that evaporates entirely if ARM demucs is even ~8% slower per job — and
  nobody has benchmarked that. **Revisit only behind a throughput benchmark**, not a price table.
  (The timbre lane is already `c7g.2xlarge` ARM because its image was built ARM from the start.)
- **Torch:** the AMI pulled the CUDA torch build; on CPU-only workers install the CPU wheel
  (`pip install torch --index-url https://download.pytorch.org/whl/cpu`) to shrink the AMI.
- **Idempotency:** a rip-server restart re-sends outstanding wants to SQS (SQS may still hold the
  originals) → at worst a duplicate separation; folding a duplicate result is idempotent (same keys).
- **Custom audio** (`/stemify-custom`, Studio/Demuxer ids) is intentionally **not** offloaded — the
  audio is uploaded to the server, not in the rips bucket, so it separates locally.
```
