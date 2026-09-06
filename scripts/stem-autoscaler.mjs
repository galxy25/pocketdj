#!/usr/bin/env node
// PocketDJ stem-worker autoscaler — the scale-UP controller. Reads the SQS jobs-queue depth and
// the current worker fleet, then launches min(MAX, ceil(visible/JOBS_PER_WORKER)) workers from
// the EC2 launch template. It never scales down — workers self-retire after idle
// (stem-worker.mjs --serve → shutdown → instance-initiated-terminate). Net: fleet tracks queue
// depth up and idle time down. Run on a schedule (launchd/cron ~60s) or a Lambda.
//
//   node stem-autoscaler.mjs               one reconcile pass (launch workers if there's backlog)
//   node stem-autoscaler.mjs --status      print queue depth + fleet, change nothing
//   node stem-autoscaler.mjs --enqueue ID… send stem jobs to SQS (rip-server calls the same path)
//   node stem-autoscaler.mjs --lane timbre [--status]   drive the CLOUD TIMBRE fleet instead
//
// TWO LANES, ONE CONTROLLER. `--lane timbre` points the same proven reconcile loop at the timbre
// queue/template/tag. It is a config block, not a fork — a second copy of this file would drift.
//
// SPOT: the stem lane launches spot instances by default and falls back to on-demand only when
// spot refuses for CAPACITY reasons, so a dry market slows the queue instead of stopping it. The
// timbre lane stays on-demand — see the per-lane comments in LANES for both decisions, and
// POCKETDJ_STEM_MARKET / POCKETDJ_TIMBRE_MARKET (spot|on-demand) to override either.
//
// ── TWO vCPU BUCKETS, NOT ONE (read this before "simplifying" the arithmetic) ────────────────────
// Spot and on-demand are SEPARATE account quotas, and conflating them is a cost bug, not a rounding
// error. Measured 2026-09-06 in us-west-2, account 011183829623:
//     L-34B43A08  All Standard SPOT Instance Requests ....... 32 vCPU  → 16 × m7i.large
//     L-1216C47A  Running On-Demand Standard instances ...... 64 vCPU  → 32 × m7i.large
// The old single `totalVcpuCap` (56) was an ON-DEMAND-shaped budget. Sized against it, a busy
// reconcile asks spot for up to 28 instances; the SPOT quota refuses the WHOLE request with
// MaxSpotInstanceCountExceeded — `--count 1:n` fulfils what CAPACITY allows, but a QUOTA refusal
// rejects the request outright, all-or-nothing — and the capacity fallback then relaunches all 28
// on-demand at 2.7×. A change made to save ~60% would instead run the fleet fully on-demand exactly
// when it is busiest, and nothing in the logs would say so: both calls "succeeded".
//
// So: size the spot ask against the SPOT ceiling, size on-demand against the ON-DEMAND ceiling, and
// count what is already running by its real InstanceLifecycle rather than by which market its lane
// prefers — a stem worker born of a fallback is an ON-DEMAND instance and spends the on-demand
// bucket, whatever LANES.stem says. The cross-lane guard survives all of that: both lanes are
// counted into both buckets, so one lane can still never starve or break the other. See launchPlan.
//
// LANES.stem.maxWorkers (30) is now an ambition, not a promise: on spot the ceiling binds at 16, and
// the remaining 14 are a SHORTFALL. By default the shortfall — and ONLY the shortfall — is topped up
// on-demand, so a 300-message backlog buys 16 cheap + 14 full-price rather than the 28-30 full-price
// the pre-fix code bought when spot was merely quota-capped. That 14 is metered by the fallback
// guard, so it can never quietly become permanent.
//
// POCKETDJ_ONDEMAND_TOPUP=0 turns the top-up OFF and makes the lane strictly spot-only: the fleet
// caps at 16, the shortfall is reported and left un-launched, and the queue drains more slowly for
// about a third of the price. That is the right setting for an unattended backfill and the wrong one
// for a queue somebody is waiting on, which is why it is a knob and not a constant. It gates only the
// QUOTA-CAPPED top-up; the CAPACITY fallback (spot asked and did not deliver) is a separate,
// separately-metered decision and still runs — see onDemandFallbackCount.
//
// ── AZ FAN-OUT, AND THE OUTAGE IT MUST NOT CAUSE ────────────────────────────────────────────────
// Spot capacity is a PER-AZ pool, and the template pins ONE subnet, so one AZ's crunch stalls the
// queue or forces full price while three other zones sit idle. Fanning out is free here: all four
// default-VPC subnets are public, share one route table with an internet-gateway default route, and
// reach S3 privately through the same gateway endpoint.
//
// The hazard is HOW. `RunInstances` REJECTS `--subnet-id` when the launch template defines a
// `NetworkInterfaces` block, and every live version of `pocketdj-stem-worker` (v1–v4) does. Verified
// against the real API 2026-09-06 with `--dry-run`:
//     --launch-template pocketdj-stem-worker --subnet-id subnet-00f9…
//       → InvalidParameterCombination: Network interfaces and an instance-level subnet ID may not
//         be specified on the same request
// That failure is 100% of launches in every AZ, immediately, and InvalidParameterCombination is in
// neither the next-AZ set nor the on-demand fallback set — nothing recovers it. It is a full
// pipeline outage, not a degradation. So `stem-spot-setup.mjs --multi-az` RESTRUCTURES the template
// (drop the block, hoist the groups to top-level SecurityGroupIds) and this controller names a
// subnet ONLY once templateNetMode() has seen that happen. Unknown ⇒ pinned ⇒ exactly the old
// behaviour. The fan-out is ADDITIVE: shipping this file before the restructure costs the fan-out
// and nothing else.
//
// ── FALLBACK BUDGET ─────────────────────────────────────────────────────────────────────────────
// On-demand fallback is metered (see shouldAllowFallback). State lives in
// ~/.pocketdj/stem-autoscaler/<lane>.json because this process is a stateless 60 s LaunchAgent — an
// in-memory counter would reset before it ever counted to two.
//
// BE PRECISE ABOUT WHAT THE METER BOUNDS: the RATE of paid launches, and nothing else. Measured on a
// 300-message backlog against a total spot outage, the fleet still converges to the full-price
// steady state — 16 bought immediately, 12 more after the 600 s cooldown, then 28 on-demand
// (≈$2.82/hr) held there by the on-demand vCPU cap, about ten minutes in. That is the CORRECT
// availability trade (a dead pool means pay or stall) and it is no worse than the pre-spot
// behaviour, but it is emphatically NOT "a multi-hour outage cannot bill unattended". What the meter
// actually buys is (a) no churn from a flapping pool and (b) an hourly alarm naming the cause. If the
// bill during an outage is the thing to cap, the knob is POCKETDJ_STEM_FALLBACK_MAX (or
// POCKETDJ_ONDEMAND_TOPUP=0 for the quota-capped half) — not this comment's optimism.
//
// ── SPOT PREFLIGHT ──────────────────────────────────────────────────────────────────────────────
// Workers do not run this repo's stem-worker.mjs; userdata copies it from s3://…/worker-code/ at
// boot. Requesting spot while THAT copy is spot-blind strands a job for the full 1800 s visibility
// timeout on every reclaim and burns one of its three deliveries — three unlucky reclaims
// dead-letter a song that never failed, and rip-server's pumpStemDlq() then marks it errored
// permanently. spotGate() refuses to request spot until the DEPLOYED bytes prove otherwise. It
// fails SAFE (on-demand), never open.
//
// Env: AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE,
//   POCKETDJ_STEM_MAX_WORKERS (cap; gated by EC2 vCPU quota), POCKETDJ_STEM_JOBS_PER_WORKER,
//   POCKETDJ_STEM_LAUNCH_TEMPLATE, POCKETDJ_STEM_MARKET, POCKETDJ_STEM_SUBNETS,
//   POCKETDJ_STEM_WORKER_CODE, POCKETDJ_TIMBRE_JOBS_QUEUE, POCKETDJ_TIMBRE_MAX_WORKERS,
//   POCKETDJ_TIMBRE_JOBS_PER_WORKER, POCKETDJ_TIMBRE_LAUNCH_TEMPLATE, POCKETDJ_TIMBRE_MARKET,
//   POCKETDJ_TIMBRE_SUBNETS, POCKETDJ_TIMBRE_WORKER_CODE,
//   POCKETDJ_SPOT_VCPU_CAP (32), POCKETDJ_ONDEMAND_VCPU_CAP / POCKETDJ_TOTAL_VCPU_CAP (56),
//   POCKETDJ_ONDEMAND_TOPUP (1),
//   POCKETDJ_ALERT_REPEAT_SEC (3600), POCKETDJ_ALERT_CMD, POCKETDJ_AUTOSCALER_STATE_DIR.
// PER-LANE (the `<LANE>` is STEM or TIMBRE — laneEnv()/laneNum() build the name, so a global
// POCKETDJ_FALLBACK_* is read by nothing; the brake would silently stay at its default):
//   POCKETDJ_<LANE>_FALLBACK_MAX (6)        paid launches per window; 0 means never pay
//   POCKETDJ_<LANE>_FALLBACK_WINDOW_S (3600)
//   POCKETDJ_<LANE>_FALLBACK_COOLDOWN_S (600)
//   POCKETDJ_<LANE>_FALLBACK_STATE          override the state-file path outright
//   POCKETDJ_<LANE>_PREFLIGHT_TTL_S (600)   how long a spot-preflight verdict is cached
//   POCKETDJ_<LANE>_TEMPLATE_TTL_S (600)    how long the template's network shape is cached
// There is no stale-pass grace knob: an unverifiable worker-code object is always on-demand.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

const laneArgIdx = process.argv.indexOf('--lane');
const LANE = laneArgIdx >= 0 ? process.argv[laneArgIdx + 1] : 'stem';

/// Every AZ in the default VPC, one subnet each.
///
/// MEASURED 2026-09-06 (us-west-2, account 011183829623). vpc-003b55e5582595910 is the default VPC
/// and the only one. All four subnets are public (MapPublicIpOnLaunch=true) and share the one main
/// route table rtb-06c8f8ef5811a718f — internet-gateway default route, plus S3 gateway endpoint
/// vpce-0341241602a451680, so S3 is private and free from every AZ while the public path (SQS, pip,
/// HuggingFace) is identical from every one. There is no per-AZ reason to prefer one; the fan-out is
/// free. Verified with a dry-run spot RunInstances in all four.
///
/// The AZ names ride along rather than being resolved from `describe-subnets` each tick: they are
/// static facts, and a per-tick API call to re-learn them is a failure mode (and a log line reading
/// "subnet-0c62…" instead of "us-west-2c") bought for nothing. A wrong-but-well-formed id here is
/// the nasty case — only the launches that pick that AZ fail, so it reads as flaky spot capacity for
/// weeks rather than as a typo.
const DEFAULT_VPC_SUBNETS = [
  { az: 'us-west-2a', subnetId: 'subnet-00a23032877bbe190' },   // the AZ the template pins today
  { az: 'us-west-2b', subnetId: 'subnet-00f9be279c616ff01' },
  { az: 'us-west-2c', subnetId: 'subnet-0c623f93e8a27ea34' },
  { az: 'us-west-2d', subnetId: 'subnet-055bd6cc3fb64e8b7' },
];
/// `POCKETDJ_STEM_SUBNETS` takes bare subnet ids (`subnet-a,subnet-b`) or `az:subnet` pairs. A bare
/// id keeps its real AZ label when we know it, so pinning the walk to one zone to reproduce a
/// capacity report still logs a zone name rather than an id.
function parseSubnets(spec) {
  const out = [];
  for (const item of String(spec || '').split(',').map((x) => x.trim()).filter(Boolean)) {
    const [a, b] = item.split(':');
    const subnetId = b || a;
    out.push({ az: b ? a : (DEFAULT_VPC_SUBNETS.find((s) => s.subnetId === subnetId)?.az || subnetId), subnetId });
  }
  return out.length ? out : null;
}
/// The subnets THIS lane may launch into. Exported because the AZ walk is the part most likely to be
/// got wrong silently, and a test that cannot see the list cannot check it covers the region.
export const SUBNETS = parseSubnets(process.env[`POCKETDJ_${LANE.toUpperCase()}_SUBNETS`])
  || (LANE === 'stem' ? DEFAULT_VPC_SUBNETS : []);

const bool = (s) => /^(1|true|yes|on)$/i.test(String(s || ''));
const LANES = {
  stem: {
    jobsQueue: process.env.POCKETDJ_STEM_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-jobs',
    // 2026-07-19: standard-vCPU quota raised 5 → 64 (m7i.large = 2 vCPU ⇒ 32 max); default 30
    // keeps one instance-pair of headroom so an unrelated launch never trips a quota error.
    // On SPOT the real ceiling is lower still (32 spot vCPU ⇒ 16) — see the two-buckets note above.
    maxWorkers: Number(process.env.POCKETDJ_STEM_MAX_WORKERS || 30),
    jobsPerWorker: Number(process.env.POCKETDJ_STEM_JOBS_PER_WORKER || 2),
    template: process.env.POCKETDJ_STEM_LAUNCH_TEMPLATE || 'pocketdj-stem-worker',
    tag: 'pocketdj-stem-worker',
    vcpu: 2,                       // m7i.large
    // SPOT. One stem message = one song, claimed by the queue's visibility timeout and redelivered
    // whole if the worker dies holding it, so an interruption costs one song's Demucs run and
    // nothing else — exactly the workload spot is priced for. August: 427 on-demand hours, $43;
    // m7i.large spot runs ~$0.038–0.045 against $0.1008 on-demand, so ~60% of that comes back.
    market: process.env.POCKETDJ_STEM_MARKET || 'spot',
    // The bytes a booting worker ACTUALLY runs (userdata copies this over the AMI's copy). The spot
    // preflight reads THIS object, not scripts/stem-worker.mjs — the repo's opinion of the worker is
    // worth nothing to an instance that never sees it.
    workerCode: process.env.POCKETDJ_STEM_WORKER_CODE || 's3://pocketdj-rips-011183829623/worker-code/stem-worker.mjs',
  },
  timbre: {
    jobsQueue: process.env.POCKETDJ_TIMBRE_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-timbre-jobs',
    // Each timbre message is a BATCH of ~50 songs run across 8 warm shards, so a small fleet
    // absorbs a large backlog: 3 × c7g.2xlarge = 24 warm shards.
    maxWorkers: Number(process.env.POCKETDJ_TIMBRE_MAX_WORKERS || 3),
    jobsPerWorker: Number(process.env.POCKETDJ_TIMBRE_JOBS_PER_WORKER || 16),
    template: process.env.POCKETDJ_TIMBRE_LAUNCH_TEMPLATE || 'pocketdj-timbre-worker',
    tag: 'pocketdj-timbre-worker',
    vcpu: 8,                       // c7g.2xlarge
    // ON-DEMAND, deliberately, even though the stem lane is spot. A timbre message is a BATCH of
    // ~50 songs across 8 warm shards behind a docker-image load, so an interruption throws away
    // far more than one song — and worse, every interruption spends one of the batch's three
    // redeliveries, so a batch that gets unlucky three times lands in the DLQ and needs a manual
    // re-enqueue instead of just costing time. The fleet is at most 3 instances run in occasional
    // backfill waves, so the dollars at stake are small next to that. Set POCKETDJ_TIMBRE_MARKET=
    // spot for a big, restartable backfill where a lost batch is cheaper than the bill.
    market: process.env.POCKETDJ_TIMBRE_MARKET || 'on-demand',
    // SUBNETS is empty for this lane unless POCKETDJ_TIMBRE_SUBNETS says otherwise: AZ fan-out
    // exists to dodge per-AZ SPOT scarcity, and on-demand capacity for three c7g.2xlarge is never
    // the binding constraint. An empty list means "launch exactly as before, from the template's own
    // subnet", which keeps this lane byte-for-byte unchanged.
    workerCode: process.env.POCKETDJ_TIMBRE_WORKER_CODE || 's3://pocketdj-rips-011183829623/worker-code/timbre-worker.mjs',
  },
};
const CFG = {
  region: process.env.AWS_REGION || 'us-west-2',
  // Two ceilings because there are two quotas. The spot default is the measured L-34B43A08 value.
  // The on-demand default stays at the repo's long-standing 56 rather than the raw L-1216C47A 64:
  // that 8 vCPU of headroom is one c7g.2xlarge of room for an unrelated launch, and a quota refusal
  // is all-or-nothing, so trading a little throughput for never tripping it is the right side to err
  // on. The spot ceiling is DISCOVERED at run time (see spotQuotaCap) rather than trusted from this
  // default, because the failure it prevents is silent in the expensive direction: a quota raised to
  // 64 that nobody mirrored here caps the lane at 16 forever and quietly tops the rest up on-demand,
  // which reads as "spot is capacity-starved" rather than as a stale constant. This value is the
  // floor used before the first successful lookup and whenever the lookup fails.
  //   aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08   (spot)
  //   aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A   (on-demand)
  spotVcpuCap: Number(process.env.POCKETDJ_SPOT_VCPU_CAP || 32),
  // An EXPLICIT cap is an operator pinning the value (reproducing a capacity report, throttling a
  // lane by hand); discovery must not argue with it. Unset means "go and look".
  spotVcpuCapPinned: process.env.POCKETDJ_SPOT_VCPU_CAP !== undefined
    && process.env.POCKETDJ_SPOT_VCPU_CAP !== '',
  onDemandVcpuCap: Number(process.env.POCKETDJ_ONDEMAND_VCPU_CAP || process.env.POCKETDJ_TOTAL_VCPU_CAP || 56),
  // DEFAULT ON. `bool()` alone would read "unset" as false and silently cap every spot lane at the
  // spot ceiling — the opposite of the tested behaviour, and a throughput cut nobody asked for. Only
  // an EXPLICIT falsey value turns the top-up off.
  onDemandTopup: process.env.POCKETDJ_ONDEMAND_TOPUP === undefined
    || process.env.POCKETDJ_ONDEMAND_TOPUP === ''
    ? true : bool(process.env.POCKETDJ_ONDEMAND_TOPUP),
  subnets: SUBNETS,
  lane: LANE,
  ...(LANES[LANE] || LANES.stem),
};
if (!LANES[LANE]) { console.error(`unknown --lane ${LANE}; use stem|timbre`); process.exit(2); }
// A mistyped market must NOT be coerced: silently reading `Spot` as on-demand would quietly bill
// full price for months, and reading an unknown value as spot would put the timbre lane somewhere
// its operator never asked for. Refuse the pass instead.
if (CFG.market !== 'spot' && CFG.market !== 'on-demand') {
  console.error(`unknown market "${CFG.market}" for lane ${LANE}; use spot|on-demand`); process.exit(2);
}
const aws = (...a) => execFileSync('aws', [...a, '--region', CFG.region,
  ...(process.env.AWS_PROFILE ? ['--profile', process.env.AWS_PROFILE] : [])], { encoding: 'utf8' });
/// The AWS CLI answers `--output json` with an empty line when a query matches nothing, and a
/// stubbed or future CLI can answer with whitespace or prose. JSON.parse throws on all three and
/// would take the whole reconcile down with it, so every parse of CLI output goes through here.
function parseJson(text, fallback) {
  const t = String(text || '').trim();
  if (!t) return fallback;
  try { return JSON.parse(t); } catch { return fallback; }
}

// ── PERSISTENT STATE ────────────────────────────────────────────────────────────────────────────
// This process lives ~2 seconds and is re-launched every 60 s, so ANY memory it needs across ticks
// — the fallback meter, the cached preflight verdict, which AZ led last time, which warnings have
// already been shouted — has to be on disk. Same idiom as the rest of the repo's long-running jobs
// (~/.pocketdj/<subsystem>/…). One file per lane: the two lanes have independent fallback histories
// and sharing a file would let a timbre backfill silence a stem alert.
const laneEnv = (suffix) => process.env[`POCKETDJ_${LANE.toUpperCase()}_${suffix}`];
const laneNum = (suffix, dflt) => Number(laneEnv(suffix) ?? dflt);
const STATE_FILE = laneEnv('FALLBACK_STATE')
  || join(process.env.POCKETDJ_AUTOSCALER_STATE_DIR || join(homedir(), '.pocketdj', 'stem-autoscaler'), `${LANE}.json`);
/// A PLAIN OBJECT, always — never whatever happened to be in the file.
///
/// parseJson only guards against text that will not parse. `null`, `"nope"` and `[]` all parse
/// perfectly well, and each one detonates on the first `state.x ||= {}` a few lines later. That is
/// not a cosmetic difference: the throw escapes reconcile, the LaunchAgent restarts in 60 s, reads
/// the SAME file, and throws again — every minute, for ever, with the fleet frozen at whatever size
/// it happened to be. The `finally` even writes the bad shape straight back, so it is self-sealing.
/// A half-written file is the safe case (it fails to parse); a hand-edit or an `echo null >` is the
/// one that wedges. Everything the state holds is a cache or a counter, so discarding an unusable
/// one costs a re-check and nothing else.
const plainObject = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
function readState() {
  try { return plainObject(parseJson(readFileSync(STATE_FILE, 'utf8'), {})) || {}; } catch { return {}; }
}
/// The same guard one level down, for the sub-objects. A file that parses as an object can still
/// carry `"notices": "x"` or `"workerCode": 123`, and `||=` keeps a truthy non-object — so the
/// assignment that follows throws exactly as above. Read-or-replace, per branch.
function slot(state, key) {
  const cur = plainObject(state[key]);
  if (cur) return cur;
  state[key] = {};
  return state[key];
}
function writeState(s) {
  // A state file we cannot write must never take the pipeline down with it — worst case we lose the
  // meter for a tick and re-verify the preflight, both of which fail toward "be careful".
  try { mkdirSync(dirname(STATE_FILE), { recursive: true }); writeFileSync(STATE_FILE, JSON.stringify(s)); }
  catch (e) { console.error('state write failed (continuing):', e.message); }
}

const ALERT_REPEAT_MS = Number(process.env.POCKETDJ_ALERT_REPEAT_SEC || 3600) * 1000;
/// Say something ONCE per state change — and, for an ALARM (`repeat`), once an hour for as long as
/// it stays true. Logging a warning every 60 s is the same as not logging it: the one tick that
/// matters is buried under 1,439 identical ones and `tail` shows only the noise. But a warning
/// logged exactly once, four hours ago, has scrolled away just as completely — so the states that
/// cost money get a slow heartbeat and the states that mean "fine" do not. `value` is the CONDITION,
/// not the message, so a message may carry changing numbers without re-firing the alert.
function notice(state, key, value, message, repeat = false) {
  const seen = slot(state, 'notices');
  const v = String(value).slice(0, 120);   // the file is a counter and a cache, not a log
  const prev = seen[key];
  const now = Date.now();
  if (prev && prev.value === v && (!repeat || now - (prev.atMs || 0) < ALERT_REPEAT_MS)) return false;
  seen[key] = { value: v, atMs: now };
  console.error(message);
  // Escape hatch, not a channel: whoever runs this decides what "loud" means (push notification,
  // Slack webhook, `say`). Hard-coding a channel here would rot; hard-coding NONE is how the
  // invisible-fallback problem happened. Failures are swallowed — alerting must never break a pass.
  if (process.env.POCKETDJ_ALERT_CMD) {
    try {
      execFileSync('/bin/sh', ['-c', process.env.POCKETDJ_ALERT_CMD],
        { encoding: 'utf8', env: { ...process.env, POCKETDJ_ALERT_TEXT: message } });
    } catch { /* alerting is best-effort */ }
  }
  return true;
}

// visible = unclaimed backlog (drives scale-up); inflight = messages a worker is processing.
function queueDepth() {
  try {
    const out = aws('sqs', 'get-queue-attributes', '--queue-url', CFG.jobsQueue, '--attribute-names',
      'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', '--output', 'json');
    const a = parseJson(out, {}).Attributes || {};
    return { visible: Number(a.ApproximateNumberOfMessages || 0), inflight: Number(a.ApproximateNumberOfMessagesNotVisible || 0) };
  } catch (e) {   // transient AWS error → skip this reconcile pass rather than abort
    console.error('queueDepth error:', e.message);
    return { visible: 0, inflight: 0 };
  }
}

/// One lane's instances WITH the market each is actually billed under and the state it is in.
///
/// InstanceLifecycle ("spot" on a spot instance, absent otherwise) is the only honest answer to
/// "which quota does this spend": a stem worker born of the on-demand fallback is an ON-DEMAND
/// instance no matter what LANES.stem.market says, and billing it to the spot bucket is how the two
/// buckets get conflated again.
///
/// The state filter is WIDER than the scale-up question needs, on purpose. `shutting-down` and
/// `stopping` instances still HOLD their vCPU against the quota until they are fully terminated, and
/// these workers self-retire constantly, so there is nearly always one on the way out. Counting only
/// pending+running under-reports usage, which makes the next ask overshoot the quota — and a quota
/// refusal is all-or-nothing, so the whole launch dies (or, on spot, looks like a capacity failure
/// and spends the fallback budget rescuing a problem we invented). Callers take the narrower `LIVE`
/// view for "how many workers can actually take a job".
const LIVE = new Set(['pending', 'running']);
function fleetDetail(tag = CFG.tag) {
  const out = aws('ec2', 'describe-instances', '--filters', `Name=tag:${tag},Values=1`,
    'Name=instance-state-name,Values=pending,running,shutting-down,stopping', '--query',
    'Reservations[].Instances[].{id:InstanceId,lifecycle:InstanceLifecycle,state:State.Name}', '--output', 'json');
  const rows = parseJson(out, []);
  return Array.isArray(rows) ? rows.map((i) => ({ id: i.id, spot: i.lifecycle === 'spot', state: i.state })) : [];
}

/// vCPU currently held by BOTH lanes, split by billing bucket, plus this lane's own WORKING
/// instances. The account quotas are shared across lanes; counting only our own lane is how a
/// reconcile ends up asking for capacity the other lane already spent.
function surveyFleets() {
  const held = { spot: 0, onDemand: 0 };
  let own = [];
  for (const [name, l] of Object.entries(LANES)) {
    let d;
    // Our OWN lane is not guarded: if we cannot see our fleet we do not know whether we already have
    // sixteen workers, and launching on a guess is worse than skipping the tick. Throwing here ends
    // the pass and launchd retries in 60 s. The OTHER lane IS best-effort — stalling the stem queue
    // because the timbre describe blipped is the worse trade, and under-counting it costs at most
    // one refused launch that the next tick repeats correctly.
    if (name === CFG.lane) { d = fleetDetail(l.tag); own = d.filter((i) => LIVE.has(i.state)); }
    else { try { d = fleetDetail(l.tag); } catch { d = []; } }
    for (const i of d) held[i.spot ? 'spot' : 'onDemand'] += l.vcpu;
  }
  return { own, ...held };
}

// ── ERROR CLASSIFICATION ────────────────────────────────────────────────────────────────────────
// The AWS CLI reports a refused launch as `An error occurred (Code) when calling the RunInstances
// operation: …` on stderr, and execFileSync repeats that text in the thrown error's message — so the
// CODE is what we match, never the prose.
//
// TWO SETS, deliberately not one. They answer different questions, and their difference is the whole
// point of the AZ ring:
//   • AZ_CAPACITY_ERRORS  — "would a DIFFERENT AZ answer differently?" Only pool-scoped refusals.
//   • SPOT_CAPACITY_ERRORS — "is paying on-demand right now the answer?" Also the REGIONAL spot
//     quota, because that bucket is separate from the on-demand one, so full price really can get
//     the queue moving again.
// MaxSpotInstanceCountExceeded is the code that separates them: it is a REGIONAL quota, so every AZ
// hits the identical wall and fanning out turns one refusal into four wasted calls — yet on-demand
// has its own bucket, so the fallback is still correct. VcpuLimitExceeded and InstanceLimitExceeded
// are in NEITHER: those are the on-demand limits, and a retry hits the same wall anywhere.
// AZ_CAPACITY_ERRORS is a strict SUBSET of SPOT_CAPACITY_ERRORS — nothing may advance to another AZ
// that would not also justify paying, or the ring would burn four calls on a refusal it then
// swallows.
const AZ_CAPACITY_ERRORS = new Set([
  'InsufficientInstanceCapacity',
  'InsufficientHostCapacity',
  'SpotMaxPriceTooLow',          // the spot price floor is per-AZ, so another zone may be cheaper
]);
const SPOT_CAPACITY_ERRORS = new Set([...AZ_CAPACITY_ERRORS, 'MaxSpotInstanceCountExceeded']);

function matches(set, stderr) {
  const text = String(stderr || '');
  const m = /An error occurred \(([A-Za-z0-9_.-]+)\)/.exec(text);
  if (m) return set.has(m[1]);
  // No recognisable envelope (a CLI-shape change, a wrapped error) — still honour a bare code if one
  // is in there, but never guess from wording like "capacity", which quota errors also use.
  return [...set].some((code) => text.includes(code));
}

/// Pure: may this FAILED spot launch be retried on-demand? Only a capacity refusal qualifies — spot
/// having no room is a market condition, and paying on-demand to drain the queue is the whole point
/// of the fallback. Every other failure (a denied instance profile, a template that no longer
/// exists, the standard-vCPU quota, the `--subnet-id`/NetworkInterfaces combination error) fails
/// identically on-demand, so falling back would either double the error or, worse, succeed and
/// quietly spend real money on a config nobody has noticed is broken. An UNRECOGNISED failure
/// therefore does not fall back: the reconcile runs again in a minute, and a stalled queue is a
/// cheaper way to learn about a broken launch path than a bill.
export function shouldFallbackToOnDemand(stderr) { return matches(SPOT_CAPACITY_ERRORS, stderr); }

/// Pure: should the ring advance to the NEXT AZ after this refusal? True only for AZ-scoped
/// capacity, which is why this is not simply shouldFallbackToOnDemand. The asymmetry matters:
/// fanning out on a config error turns one clear message into four identical ones plus three wasted
/// calls, while NOT fanning out on real pool scarcity is the bug this whole change exists to fix.
export function shouldTryNextAz(stderr) { return matches(AZ_CAPACITY_ERRORS, stderr); }

/// Pure: the order to try AZs in this pass — a PERMUTATION of `subnets`.
///
/// Two properties, and they pull against each other. EXACTLY ONCE: dropping a subnet silently halves
/// the capacity the fleet can reach, and duplicating one spends a retry on a pool that just said no,
/// so the list is deduped BEFORE it is rotated. NOT ALWAYS THE SAME LEAD: the lead AZ supplies the
/// bulk of a pass (later zones are only reached after a refusal), so a fixed order piles the fleet
/// into 2a whenever 2a has room — the concentration that lets one AZ's reclaim wave take out every
/// worker at once.
///
/// Rotation rather than shuffle: deterministic for a given cursor, so the order in the log is the
/// order that was tried and stays re-derivable afterwards; the zone that led last tick becomes this
/// tick's last resort, so a dry zone is demoted rather than dropped; and it visits everything in a
/// bounded n steps. The cursor is a persisted counter rather than a clock — at a 60 s cadence a
/// clock-derived seed can beat against the list length and lead with the same zone every tick.
export function azOrder(seed = 0, subnets = SUBNETS) {
  const uniq = [];
  for (const s of Array.isArray(subnets) ? subnets : []) {
    // A malformed entry has no subnet to launch into; keeping it would spend a whole AZ's turn
    // producing an argv with `--subnet-id undefined`.
    if (s && typeof s === 'object' && s.subnetId && !uniq.some((u) => u.subnetId === s.subnetId)) uniq.push(s);
  }
  if (uniq.length < 2) return uniq;
  const n = uniq.length;
  // `((seed % n) + n) % n`, not a bare remainder: JS `%` keeps the sign, and `slice(-1)` would
  // silently return a ONE-element order, leaving three AZs unreachable.
  const k = ((Math.trunc(Number(seed)) || 0) % n + n) % n;
  return [...uniq.slice(k), ...uniq.slice(0, k)];
}

/// Pure: may a launch from this template name a subnet at all?
///
/// 'pinned' whenever a NON-EMPTY NetworkInterfaces block is present — the API refuses the
/// `--subnet-id` combination on the PRESENCE of an interface spec, not on whether it happens to
/// carry a SubnetId — and 'pinned' for anything that is not a readable object, because "we do not
/// know" must fail toward the old behaviour. An EMPTY list is the one place "no block" is spelled
/// differently: it specifies no interface, so a plain --subnet-id is legal.
///
/// Guessing 'multi-az' wrongly fails 100% of launches in every AZ with an error nothing recovers
/// from. Guessing 'pinned' wrongly costs the fan-out and nothing else.
export function templateNetMode(launchTemplateData) {
  const d = launchTemplateData;
  if (!d || typeof d !== 'object' || Array.isArray(d)) return 'pinned';
  return Array.isArray(d.NetworkInterfaces) && d.NetworkInterfaces.length ? 'pinned' : 'multi-az';
}

// MaxPrice is deliberately UNSET — an unset maximum bids the on-demand price, which is the correct
// non-throttling choice. A hardcoded ceiling looks prudent and is the classic way to starve a fleet:
// the day the spot price crosses it, every launch is refused, the queue backs up, and nothing in the
// logs says "you set a limit". `one-time`, not `persistent`: a persistent request would re-launch a
// reclaimed worker behind the autoscaler's back and fight scale-to-zero. Spot is requested
// per-run-instances rather than baked into the template because the template is shared with anything
// else that launches these workers by hand, and the market is a policy this controller owns.
const SPOT_MARKET_OPTIONS = JSON.stringify({
  MarketType: 'spot',
  SpotOptions: { SpotInstanceType: 'one-time', InstanceInterruptionBehavior: 'terminate' },
});

/// Pure: the `aws ec2 run-instances …` argv for ONE attempt.
///
/// `--count 1:n` is why partial capacity FILLS what it can instead of failing the pass — it matters
/// doubly on spot, where a partial fill is the normal case, and doubly again now that each AZ is a
/// separate attempt. (It does NOT save us from a quota REFUSAL: those are all-or-nothing, which is
/// why launchPlan sizes the ask against the right bucket rather than relying on this.)
///
/// The subnet is named ONLY when netMode is exactly 'multi-az'. Nothing here hand-rolls
/// `--network-interfaces`: overriding the whole block per launch would mean restating DeviceIndex,
/// Groups, AssociatePublicIpAddress and DeleteOnTermination in this file forever, and every future
/// edit to the template's ENI block would be silently ignored. The template owns network config.
export function runInstancesArgs({ template, count, market, subnetId, netMode }) {
  return [
    '--launch-template', `LaunchTemplateName=${template},Version=$Latest`,
    '--count', `1:${count}`,
    ...(netMode === 'multi-az' && subnetId ? ['--subnet-id', subnetId] : []),
    ...(market === 'spot' ? ['--instance-market-options', SPOT_MARKET_OPTIONS] : []),
    '--query', 'Instances[].InstanceId', '--output', 'text',
  ];
}

// ── SPOT PREFLIGHT (do not request spot for a spot-blind fleet) ─────────────────────────────────
// ONE DEFINITION OF "SPOT-AWARE", agreed by four files that never call each other:
//   scripts/stem-worker.mjs         CONTAINS the marker `spot/instance-action` — it is the code that
//                                   polls IMDS and releases the in-flight message on a reclaim.
//   scripts/stem-deploy-worker.sh   REFUSES to deploy a worker without it, verifies the bytes it
//                                   reads back, and STAMPS the object x-amz-meta-spot-aware=yes.
//   this file                       REFUSES to request spot until the DEPLOYED object carries that
//                                   stamp.
//   scripts/stem-worker-userdata.sh is why "deployed" means that S3 prefix and not the repo.
// The marker string lives here too so the agreement is greppable from either end: rename the
// handler and the deploy script quietly refuses forever, which is the safe direction.
const SPOT_AWARE_MARKER = 'spot/instance-action';
const WORKER_CHECK_TTL_MS = laneNum('PREFLIGHT_TTL_S', 600) * 1000;

/// The Service Quotas code for the spot vCPU bucket this lane's instance families spend.
const SPOT_QUOTA_CODE = 'L-34B43A08';
const SPOT_QUOTA_TTL_MS = laneNum('SPOT_QUOTA_TTL_S', 21600) * 1000;

/// Pure: the spot ceiling to plan against, given a cached lookup and the configured floor.
///
/// Discovery may only RAISE the floor, never lower it. A lookup that comes back smaller than the
/// configured value is far more likely to be a wrong answer (a throttled call parsed as a number, a
/// quota renamed under us) than a genuine reduction — and believing it would cap the fleet on bad
/// data. Believing a larger value costs at worst one MaxSpotInstanceCountExceeded, which the
/// capacity fallback already handles.
export function spotCapFrom(cached, floor) {
  const v = Number(cached);
  return Number.isFinite(v) && v > floor ? v : floor;
}

/// The live spot vCPU quota, cached on disk.
///
/// This exists because the alternative is a constant that has to be hand-edited the day a quota
/// request is approved, and the symptom of forgetting is not an error — it is the lane silently
/// capping at the old ceiling and topping the difference up on-demand at 2.7x, which looks exactly
/// like spot capacity being tight. A quota changes a few times a year, so the TTL is hours, not
/// minutes: four calls a day to never be wrong about the number that decides how much of the fleet
/// is cheap.
///
/// Never throws and never blocks a launch: any failure keeps the last known value, and failing that
/// the configured floor. A reconcile that cannot reach Service Quotas still scales the fleet.
function spotQuotaCap(state, now) {
  const floor = CFG.spotVcpuCap;
  if (CFG.spotVcpuCapPinned) return floor;
  const c = slot(state, 'spotQuota');
  if (c.checkedAtMs && now - c.checkedAtMs < SPOT_QUOTA_TTL_MS) return spotCapFrom(c.vcpu, floor);
  try {
    const q = parseJson(aws('service-quotas', 'get-service-quota', '--service-code', 'ec2',
      '--quota-code', SPOT_QUOTA_CODE, '--output', 'json'), null);
    const v = Number(q?.Quota?.Value);
    if (Number.isFinite(v) && v > 0) { c.vcpu = v; c.checkedAtMs = now; }
  } catch {
    // Throttling, no network, a principal without servicequotas:GetServiceQuota. Stamp the attempt
    // so a hard-down endpoint is retried on the TTL rather than on every 60s tick.
    c.checkedAtMs = now;
  }
  return spotCapFrom(c.vcpu, floor);
}

/// Pure: is the worker code a booting instance will actually run spot-aware?
///
/// `head` is the parsed `aws s3api head-object` JSON for the deployed object, or a null/undefined
/// when the call failed. TRUE only for an explicit `x-amz-meta-spot-aware: yes`. Nothing else counts
/// — not a recent LastModified, not a plausible ContentLength, not a truthy near-miss like 'true' or
/// 'YES'. Those are circumstantial; the stamp is a claim the deploy script only makes after it has
/// read the bytes back and found the marker.
///
/// An unknown is NOT a yes, because the cost of being wrong is asymmetric: guessing on-demand
/// overpays for a few minutes, while guessing spot strands a job for the full 1800 s visibility
/// timeout on every reclaim and burns one of its three deliveries — and three unlucky reclaims
/// dead-letter a song that never failed, which pumpStemDlq() then marks errored permanently.
export function isDeployedWorkerSpotAware(head) {
  return head?.Metadata?.['spot-aware'] === 'yes';
}

/// Pure: the gate. Spot only when the lane ASKED for spot and the deployed worker PROVED it can
/// survive a reclaim. Everything else is on-demand — expensive, correct, and loud.
export function effectiveMarket({ market, spotAware }) {
  return market === 'spot' && spotAware === true ? 'spot' : 'on-demand';
}

/// The cached gate: a STAMP if the deploy script left one, otherwise the BYTES.
///
/// The stamp is the fast path and the normal one — stem-deploy-worker.sh writes it only after
/// reading the object back and finding the marker, so it is a claim somebody already checked. But an
/// unstamped object is not automatically spot-blind: a hand-run `aws s3 cp` from a current checkout
/// deploys a perfectly good worker and stamps nothing. Rather than demand a redeploy, spend one
/// download and look at the bytes.
///
/// Never by TIMESTAMP or SIZE. "Newer than the branch, so it must be fine" is wrong twice: a hand-run
/// copy from a STALE checkout is recent AND spot-blind, and clock skew between S3 and a laptop makes
/// the comparison a coin flip.
///
/// Cached ON DISK, because every tick is a brand-new process — an in-process cache would be one S3
/// call per minute forever for an object that changes about once a month. The HEAD is cheap and its
/// ETag is what says whether a download is needed at all.
function spotGate(state, now) {
  const c = slot(state, 'workerCode');
  const uri = CFG.workerCode;
  if (c.uri === uri && c.checkedAtMs && now - c.checkedAtMs < WORKER_CHECK_TTL_MS) {
    return { ok: !!c.spotAware, reason: c.reason };
  }
  const m = /^s3:\/\/([^/]+)\/(.+)$/.exec(uri || '');
  if (!m) return { ok: false, reason: `unparseable worker-code URI ${uri}` };
  try {
    const head = parseJson(aws('s3api', 'head-object', '--bucket', m[1], '--key', m[2], '--output', 'json'), null);
    let spotAware = isDeployedWorkerSpotAware(head);
    if (!spotAware) {
      // Unstamped. If these are bytes we have already searched (same ETag) trust the stored verdict
      // rather than downloading them again every TTL.
      spotAware = c.uri === uri && c.etag && c.etag === head?.ETag
        ? !!c.spotAware
        : aws('s3', 'cp', uri, '-').includes(SPOT_AWARE_MARKER);
    }
    Object.assign(c, {
      uri, etag: head?.ETag, checkedAtMs: now, spotAware, deployedAt: head?.LastModified,
      reason: spotAware ? '' : `${uri} is not spot-aware: no x-amz-meta-spot-aware=yes stamp and no `
        + `${SPOT_AWARE_MARKER} handler in the deployed bytes (run scripts/stem-deploy-worker.sh)`,
    });
    return { ok: spotAware, reason: c.reason };
  } catch (e) {
    const why = String(e.message).split('\n').filter(Boolean).pop() || e.message;
    // NO stale-pass grace. The tempting policy — "we verified it an hour ago, carry on" — would let a
    // week-old yes authorise spot for ever after a credentials change or a bucket-policy edit. An
    // object we cannot read is exactly as unproven as one that was never stamped, and the cost of
    // being wrong here is songs, not dollars.
    return { ok: false, reason: `cannot verify deployed worker code (${why})` };
  }
}

// The template's network shape, cached the same way and for the same reason. Fails to 'pinned'.
const TEMPLATE_CACHE_MS = laneNum('TEMPLATE_TTL_S', 600) * 1000;
function netModeCached(state, now) {
  const c = slot(state, 'netMode');
  if (c.template === CFG.template && c.atMs && now - c.atMs < TEMPLATE_CACHE_MS) return c.mode;
  let mode = 'pinned';
  try {
    const raw = parseJson(aws('ec2', 'describe-launch-template-versions',
      '--launch-template-name', CFG.template, '--versions', '$Latest', '--output', 'json'), null);
    // Accept the full envelope or an already-projected LaunchTemplateData, so adding a `--query`
    // later cannot silently pin every launch to one AZ.
    mode = templateNetMode(raw?.LaunchTemplateVersions?.[0]?.LaunchTemplateData ?? raw);
  } catch (e) {
    notice(state, 'netmode', 'unreadable',
      `[${CFG.lane}] cannot read launch template ${CFG.template} (${String(e.message).split('\n')[0]}) — staying single-AZ`);
  }
  Object.assign(c, { template: CFG.template, atMs: now, mode });
  return mode;
}

// ── ON-DEMAND FALLBACK GUARD ────────────────────────────────────────────────────────────────────
// WHY A CEILING *AND* A COOLDOWN. They stop different failures, and either alone leaves the other
// open. The COOLDOWN bounds a BURST: ten reconciles inside ten minutes during one flapping pool
// would otherwise each start a full-price fleet. The WINDOW CEILING bounds a SIEGE: a six-hour
// regional capacity outage would otherwise pay on every one of 360 ticks, and the operator would
// learn about it from the invoice.
//
// The brake is on PRICE, NOT ON WORK. Spot is still attempted on every tick while the guard is
// engaged, so a pool that recovers at any minute drains the queue immediately; only the full-price
// substitute is rationed. A guard that stopped launching altogether would convert a cost problem
// into a pipeline outage — a strictly worse trade for a music library.
//
// It meters a lane that WANTED spot and had to pay instead. It does NOT meter a lane with no spot
// half at all: the timbre lane running on-demand by design, or a stem lane the preflight is holding
// back. That hold is a safety hold whose fix is one deploy command, and throttling it would turn a
// config lapse into a stalled queue — it gets the hourly alarm instead.
//
// `?? 6`, not `|| 6`: POCKETDJ_STEM_FALLBACK_MAX=0 means "never pay", and reading a deliberate zero
// as "unset, use the default" is how a knob meant as a brake becomes an accelerator.
const FALLBACK = {
  max: Number(laneEnv('FALLBACK_MAX') ?? 6),                 // paid launches permitted per window
  windowMs: laneNum('FALLBACK_WINDOW_S', 3600) * 1000,
  cooldownMs: laneNum('FALLBACK_COOLDOWN_S', 600) * 1000,
};

/// Pure: may this pass pay for on-demand? `f` is the persisted counter — `{ windowStartMs, count,
/// lastAtMs }`, as `state.fallback` holds it — and `next` is what to persist IF the launch happens,
/// so a refused launch never charges a budget it did not spend.
///
/// The FIRST fallback is always allowed: the guard is a brake, not a block, and refusing it would
/// mean one unlucky minute of spot scarcity stalls the pipeline — worse than the bill it saves. It
/// is also deliberately forgiving about the counter itself, which comes off disk: a truncated write,
/// a hand-edit, `{"fallback":null}`, or a shape from an older version is not evidence of a storm, so
/// all of them allow and re-count rather than throwing and killing the reconcile every 60 s for ever.
///
/// The CEILING is reported before the cooldown when both apply: it is the more expensive brake, and
/// its remedy differs (raise the limit, or fix spot capacity — not "wait").
export function shouldAllowFallback(f, now = Date.now(), cfg = FALLBACK) {
  const m = f && typeof f === 'object' ? f : {};
  const rolled = !m.windowStartMs || now - m.windowStartMs >= cfg.windowMs;
  const windowStartMs = rolled ? now : m.windowStartMs;
  const count = rolled ? 0 : (Number(m.count) || 0);
  const next = { windowStartMs, count: count + 1, lastAtMs: now };
  if (count >= cfg.max) {
    return { allow: false, next, count,
      reason: `ceiling: ${count}/${cfg.max} paid launches in the last ${Math.round(cfg.windowMs / 60000)} min` };
  }
  const since = now - (m.lastAtMs || 0);
  if (m.lastAtMs && !rolled && since < cfg.cooldownMs) {
    return { allow: false, next, count,
      reason: `cooldown: ${Math.round(since / 1000)}s since the last paid launch, need ${Math.round(cfg.cooldownMs / 1000)}s` };
  }
  return { allow: true, next, count, reason: '' };
}

function runInstances(count, market, subnetId, netMode) {
  const out = aws('ec2', 'run-instances', ...runInstancesArgs({ template: CFG.template, count, market, subnetId, netMode }));
  return out.split(/\s+/).filter(Boolean);
}

function enqueue(ids) {
  for (const id of ids) {
    aws('sqs', 'send-message', '--queue-url', CFG.jobsQueue, '--message-body', JSON.stringify({ songId: id }));
    console.log('enqueued', id);
  }
}

/// Pure: how many instances this lane may launch, honouring both its own cap and ONE shared vCPU
/// budget. Exported shape kept simple so a test can pin the arithmetic.
///
/// LEGACY / SINGLE-BUCKET, and deliberately market-blind. The live controller uses launchPlan()
/// instead, because spot and on-demand draw on DIFFERENT account quotas (32 vs 56 vCPU) and one
/// `totalVcpuCap` cannot express that — see the two-buckets note at the top of this file. Do not
/// "unify" these by making reconcile call this one again: that is the cost bug, restored.
export function launchCount({ visible, fleetSize, maxWorkers, jobsPerWorker, vcpu, usedVcpu: used, totalVcpuCap }) {
  const desired = visible > 0 ? Math.min(maxWorkers, Math.ceil(visible / jobsPerWorker)) : 0;
  const byLane = Math.max(0, Math.min(desired - fleetSize, maxWorkers - fleetSize));
  const byQuota = Math.max(0, Math.floor((totalVcpuCap - used) / vcpu));
  return { desired, toLaunch: Math.min(byLane, byQuota), byLane, byQuota };
}

/// Pure: the two-bucket plan. Same backlog arithmetic as launchCount, then split against the quota
/// that actually applies to each market.
///
///   spot      instances to request on SPOT — never more than the SPOT bucket can hold, so the
///             request is never refused wholesale for MaxSpotInstanceCountExceeded.
///   onDemand  the part the spot ceiling cannot hold, clipped by the on-demand bucket. Reporting it
///             is the point; whether reconcile actually BUYS it is policy (POCKETDJ_ONDEMAND_TOPUP),
///             not arithmetic, because silently buying half a fleet at 2.7× on every busy day is the
///             exact trap this function exists to close.
///
/// Both buckets are counted across BOTH lanes by the caller, so the guard that stops one lane from
/// starving the other is unchanged — it simply now knows which quota each running instance spends.
export function launchPlan({
  visible, fleetSize, maxWorkers, jobsPerWorker, vcpu, market,
  spotVcpuCap = Infinity, usedSpotVcpu = 0,
  onDemandVcpuCap = Infinity, usedOnDemandVcpu = 0, onDemandTopup = true,
}) {
  const desired = visible > 0 ? Math.min(maxWorkers, Math.ceil(visible / jobsPerWorker)) : 0;
  const byLane = Math.max(0, Math.min(desired - fleetSize, maxWorkers - fleetSize));
  const bySpotQuota = Math.max(0, Math.floor((spotVcpuCap - usedSpotVcpu) / vcpu));
  const byOnDemandQuota = Math.max(0, Math.floor((onDemandVcpuCap - usedOnDemandVcpu) / vcpu));
  const spot = market === 'spot' ? Math.min(byLane, bySpotQuota) : 0;
  // What the spot ceiling could not hold. REPORTED ALWAYS, bought only when the top-up is on — the
  // ceiling notice and --status need this number even when the answer is "and we are not buying it",
  // or a lane pinned at 16/30 looks like a bug instead of a setting.
  const shortfall = Math.max(0, byLane - spot);
  // An on-demand LANE has no spot half and no top-up question: its whole ask is its own market, so
  // the gate must key on the spot half existing, never on the lane's name.
  const wantOnDemand = market === 'spot' && !onDemandTopup ? 0 : shortfall;
  const onDemand = Math.min(wantOnDemand, byOnDemandQuota);
  return {
    desired, byLane, bySpotQuota, byOnDemandQuota, shortfall, spot, onDemand,
    toLaunch: spot + onDemand,
  };
}

/// Pure: how many instances the CAPACITY fallback may add when the spot half of `plan` came up
/// short. `launched` is what spot actually delivered across every AZ.
///
/// The shortfall, clipped by what is LEFT of the on-demand bucket after the plan's own on-demand
/// half — never `plan.toLaunch`, and never the caller's original `n`. That distinction IS the fix: a
/// quota or capacity refusal is all-or-nothing, so the old code relaunched the WHOLE request at 2.7×
/// when spot said no. A spot ask of 16 that delivered 12 needs 4 more, not 16.
export function onDemandFallbackCount(plan, launched = 0) {
  return Math.max(0, Math.min(plan.spot - launched, plan.byOnDemandQuota - plan.onDemand));
}

/// Walk the AZ ring for the spot half of the plan, then buy whatever on-demand is warranted.
function launchFleet(plan, state, now, netMode) {
  const out = { spot: [], onDemand: [] };
  let missed = plan.spot;
  let configFailure = false;
  if (plan.spot > 0) {
    // In 'pinned' mode there is exactly one stop and no subnet is ever named — the fan-out is
    // additive, so a template that has not been restructured behaves exactly as it always did.
    const stops = netMode === 'multi-az' && CFG.subnets.length
      ? azOrder(state.azCursor || 0, CFG.subnets)
      : [{ az: 'the template AZ', subnetId: null }];
    // Advance the head EVERY pass that tries, whether or not it succeeded, so a persistently dry 2a
    // does not make 2b the permanent second choice for the rest of the week.
    state.azCursor = ((state.azCursor || 0) + 1) % Math.max(1, stops.length);
    for (const { az, subnetId } of stops) {
      let got;
      try {
        got = runInstances(missed, 'spot', subnetId, netMode);
      } catch (e) {
        // execFileSync surfaces the CLI's stderr both on `.stderr` and appended to `.message`; read
        // both so the decision never turns on which Node version is running the autoscaler.
        const err = `${e.stderr || ''}\n${e.message || ''}`;
        if (shouldTryNextAz(err)) { console.error(`  spot: no capacity in ${az}`); continue; }
        // Not pool-scoped. A denied instance profile, a deleted template, the regional spot quota:
        // every other AZ answers identically, so retrying three more times is a storm, not a
        // recovery. Whether to PAY is a separate question that shouldFallbackToOnDemand answers.
        console.error(`launch error (spot in ${az}):`, e.message);
        configFailure = !shouldFallbackToOnDemand(err);
        // DROP THE CACHED NET MODE so the next tick re-reads the template instead of repeating this.
        //
        // The cache is what makes `--revert` dangerous. Reverting re-pins the template, but this
        // process keeps its 600 s-old 'multi-az' verdict and keeps passing `--subnet-id` — which the
        // API refuses with InvalidParameterCombination, which is in NEITHER error set, so every
        // launch fails and nothing falls back. That is a total scale-up outage for up to ten minutes
        // in the middle of a rollback, i.e. exactly when the operator is already firefighting. The
        // opposite direction (a stale 'pinned' after --multi-az) merely costs the fan-out, so the
        // asymmetry is real. Invalidating on ANY non-pool failure is deliberately broader than the
        // one error code: the cost is one describe-launch-template-versions on the next tick, and a
        // config error we misclassify is one we then never re-read.
        slot(state, 'netMode').atMs = 0;
        break;
      }
      if (got.length) { out.spot.push(...got); missed -= got.length; console.error(`  spot: ${got.length} in ${az}`); }
      if (missed <= 0) break;
    }
    if (missed > 0 && out.spot.length) console.error(`  spot: ${missed} short after ${stops.length} AZ(s)`);
  }

  // A launch path that is BROKEN rather than full fails identically on-demand, so paying would
  // either double the error or quietly spend real money on a config nobody has noticed is broken.
  if (configFailure) return out;

  // ONE on-demand ask per pass: the shortfall the SPOT ceiling cannot hold, plus whatever spot was
  // asked for and did not deliver. Never the original request — a spot ask of 16 that delivered 12
  // needs 4 more, not 16, and that distinction IS the 2.7× fix. Sixteen cheap plus the gap beats
  // both "30 on-demand" (the bug) and "the queue stalls at 16" (the over-correction).
  // On-demand STANDS IN for spot, so it never buys more than the spot fleet we asked for. Without
  // that cap a total pool failure would buy the quota gap AND a full replacement for the 16 spot
  // workers — 28 instances at 2.7×, which is the very shape this branch exists to prevent. When
  // spot is healthy the cap is inert (the gap is smaller than the spot ask); when spot is dead it is
  // what keeps a capacity outage from quietly costing more than the bug did. An on-demand lane has
  // no spot half, so its own ask is the bound and nothing is clipped.
  const want = Math.min(plan.onDemand + onDemandFallbackCount(plan, out.spot.length),
    Math.max(plan.spot, plan.onDemand));
  if (want <= 0) {
    if (plan.spot > 0) notice(state, 'fallback', 'healthy', `[${CFG.lane}] spot covering the backlog — paying nothing`);
    return out;
  }

  // Metered only when there WAS a spot half to fall short. A lane with none is not falling back, it
  // is working — see the guard's comment.
  if (plan.spot > 0) {
    const g = shouldAllowFallback(state.fallback, now, FALLBACK);
    if (!g.allow) {
      notice(state, 'fallback', `withheld:${g.reason.split(':')[0]}`,
        `!! [${CFG.lane}] on-demand WITHHELD (${g.reason}) — spot is ${want} worker(s) short and the queue `
        + `will drain slowly rather than silently bill 2.7×. Spot is still attempted on every tick. `
        + `Raise POCKETDJ_${LANE.toUpperCase()}_FALLBACK_MAX, or fix spot capacity.`, true);
      return out;
    }
    notice(state, 'fallback', 'paying',
      `[${CFG.lane}] paying on-demand for ${want} worker(s) spot could not supply `
      + `(${g.count + 1}/${FALLBACK.max} paid launches this window)`);
    // Charge BEFORE the call, from `next`: a launch that only half-fills still consumed this pass's
    // one permitted fallback, and a meter that counted only whole successes would let a flapping
    // market buy a fleet a minute.
    state.fallback = g.next;
  }
  try { out.onDemand.push(...runInstances(want, 'on-demand', null, netMode)); }
  catch (e) { console.error('launch error (on-demand):', e.message); }
  return out;
}

function reconcile({ dryRun }) {
  const now = Date.now();
  const state = readState();
  try {
    const { visible, inflight } = queueDepth();
    const { own, spot: usedSpotVcpu, onDemand: usedOnDemandVcpu } = surveyFleets();

    // PREFLIGHT before anything else: a fleet whose deployed worker cannot hear a reclaim notice
    // must not be asked for spot, however good the price is. Fail safe, and say so once (then
    // hourly) — a hold that scrolls past at 03:00 and never repeats is a 2.7× bill nobody connects
    // to a cause.
    let market = CFG.market;
    let held = '';
    if (market === 'spot') {
      const gate = spotGate(state, now);
      if (!gate.ok) { market = 'on-demand'; held = gate.reason; }
      notice(state, 'spot-gate', gate.ok ? 'ok' : gate.reason,
        gate.ok ? `[${CFG.lane}] spot preflight OK — deployed worker handles ${SPOT_AWARE_MARKER}`
          : `!! [${CFG.lane}] SPOT HELD, launching on-demand at ~2.7×: ${gate.reason}`, !gate.ok);
    }

    // Resolved ONCE and threaded through both the plan and every line that reports it. Reading the
    // configured floor in the log while the plan used the discovered ceiling is how an operator ends
    // up debugging a fleet size the logs say is impossible.
    const spotCap = spotQuotaCap(state, now);
    const plan = launchPlan({
      visible, fleetSize: own.length, maxWorkers: CFG.maxWorkers, jobsPerWorker: CFG.jobsPerWorker,
      vcpu: CFG.vcpu, market, spotVcpuCap: spotCap, usedSpotVcpu,
      onDemandVcpuCap: CFG.onDemandVcpuCap, usedOnDemandVcpu, onDemandTopup: CFG.onDemandTopup,
    });

    // A spot lane's on-demand half is a SHORTFALL REPORT by default, not a shopping list.
    // Log shape preserved for the operators (and greps) that read it; the bucket breakdown is
    // appended, never spliced in. `vcpu=` reports the bucket this lane is spending.
    const used = market === 'spot' ? usedSpotVcpu : usedOnDemandVcpu;
    const cap = market === 'spot' ? spotCap : CFG.onDemandVcpuCap;
    const byQuota = market === 'spot' ? plan.bySpotQuota : plan.byOnDemandQuota;
    console.log(`[${CFG.lane}] queue: visible=${visible} inflight=${inflight} | fleet=${own.length}/${CFG.maxWorkers} `
      + `desired=${plan.desired} vcpu=${used}/${cap} (quota allows ${byQuota}) launch=${plan.toLaunch} market=${market}`
      + `${held ? ' (spot held)' : ''} [spot ${usedSpotVcpu}/${spotCap} · on-demand ${usedOnDemandVcpu}/${CFG.onDemandVcpuCap}]`);

    // The spot ceiling binding below the lane cap is normal, not an error — but an operator staring
    // at fleet=16/30 deserves to be told why, with the knob that changes it. Only ever announced for
    // a lane actually on spot, and "clear" only to someone who was told "capped" first: an
    // unprompted all-clear on a fresh state file just teaches people to skim.
    // Keyed on the SHORTFALL, not on what we chose to buy: with the top-up off the shortfall is the
    // whole story and plan.onDemand is 0, so keying on the purchase would go silent in exactly the
    // configuration where the operator most needs telling why the fleet stopped at 16/30.
    const capped = market === 'spot' && plan.shortfall > 0;
    if (capped || state.notices?.['spot-ceiling']?.value === 'capped') {
      notice(state, 'spot-ceiling', capped ? 'capped' : 'clear',
        capped ? `[${CFG.lane}] SPOT vCPU ceiling (${spotCap}) caps this lane at ${own.length + plan.spot}/${CFG.maxWorkers} `
          + `workers; the remaining ${plan.shortfall} ${plan.onDemand > 0
            ? `come from the METERED on-demand budget`
            : `are NOT being bought (POCKETDJ_ONDEMAND_TOPUP=0) — the queue drains at ${own.length + plan.spot} workers`}`
          : `[${CFG.lane}] spot vCPU ceiling no longer binding`, capped);
    }

    // --status is the operator's window into everything reconcile() decides silently: the fallback
    // meter, the preflight verdict and its age, and the exact AZ order the next launch would walk.
    // Resolving the net mode here also exercises the launch-template introspection WITHOUT launching
    // anything — the cheapest way to find out that a template edit broke the fan-out is to ask
    // before a backlog does.
    if (dryRun) {
      const f = state.fallback || {};
      const c = state.workerCode || {};
      // Only a lane that actually asks for spot has a preflight verdict; reporting the empty cache
      // as "NOT spot-aware" would libel a timbre worker nobody ever checked.
      const gate = CFG.market !== 'spot' ? `n/a (lane is ${CFG.market})`
        : `${c.spotAware ? 'spot-aware' : 'NOT spot-aware'}${c.deployedAt ? ` (deployed ${c.deployedAt})` : ''}`;
      const netMode = netModeCached(state, now);
      const where = netMode === 'multi-az' && CFG.subnets.length
        ? azOrder(state.azCursor || 0, CFG.subnets).map((s) => s.az).join(' → ')
        : `pinned to the template's AZ (run stem-spot-setup.mjs --multi-az to fan out)`;
      const g = shouldAllowFallback(f, now, FALLBACK);
      console.log(`[${CFG.lane}] fallback: ${g.count}/${FALLBACK.max} paid this window `
        + `(${g.allow ? 'armed' : `withheld — ${g.reason}`}) | worker-code: ${gate} | AZ order: ${where}`);
      return;
    }
    if (plan.toLaunch <= 0) return;

    // Log the market that actually WON, not the one we asked for: a run of silent on-demand
    // fallbacks is the only warning that this lane's spot capacity has dried up and the bill is back
    // to full price.
    const { spot, onDemand } = launchFleet(plan, state, now, netModeCached(state, now));
    const ids = [...spot, ...onDemand];
    const won = spot.length && onDemand.length ? `${spot.length} spot + ${onDemand.length} on-demand`
      : spot.length ? 'spot' : 'on-demand';
    console.log(ids.length ? `launched ${ids.length} on ${won}: ${ids.join(', ')}` : `launched none (${market})`);
  } finally {
    writeState(state);
  }
}

// Entrypoint guard around the WHOLE dispatch: the pure functions above are imported by tests, and an
// unguarded `--enqueue` branch would have fired real SQS sends the moment a test imported this file.
if (process.argv[1] && process.argv[1].endsWith('stem-autoscaler.mjs')) {
  // `--lane <name>` is consumed by CFG above; strip the flag AND its value before dispatching.
  const args = process.argv.slice(2).filter((x, i, a) => x !== '--lane' && a[i - 1] !== '--lane');
  if (args[0] === '--enqueue') enqueue(args.slice(1));
  else reconcile({ dryRun: args[0] === '--status' });
}
