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
// CROSS-LANE vCPU GUARD: the lanes share ONE account-level standard-vCPU quota (64). Stem max 30
// × 2 vCPU = 60 and timbre max 3 × 8 = 24 sum to 84 — a launch that would exceed the quota fails
// the whole reconcile. reconcile() therefore counts BOTH fleets and refuses to launch past
// POCKETDJ_TOTAL_VCPU_CAP, so one lane can never starve or break the other.
//
// Env: AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE,
//   POCKETDJ_STEM_MAX_WORKERS (cap; gated by EC2 vCPU quota), POCKETDJ_STEM_JOBS_PER_WORKER,
//   POCKETDJ_STEM_LAUNCH_TEMPLATE, POCKETDJ_TIMBRE_JOBS_QUEUE, POCKETDJ_TIMBRE_MAX_WORKERS,
//   POCKETDJ_TIMBRE_JOBS_PER_WORKER, POCKETDJ_TIMBRE_LAUNCH_TEMPLATE, POCKETDJ_TOTAL_VCPU_CAP.
import { execFileSync } from 'node:child_process';

const laneArgIdx = process.argv.indexOf('--lane');
const LANE = laneArgIdx >= 0 ? process.argv[laneArgIdx + 1] : 'stem';
const LANES = {
  stem: {
    jobsQueue: process.env.POCKETDJ_STEM_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-jobs',
    // 2026-07-19: standard-vCPU quota raised 5 → 64 (m7i.large = 2 vCPU ⇒ 32 max); default 30
    // keeps one instance-pair of headroom so an unrelated launch never trips a quota error.
    maxWorkers: Number(process.env.POCKETDJ_STEM_MAX_WORKERS || 30),
    jobsPerWorker: Number(process.env.POCKETDJ_STEM_JOBS_PER_WORKER || 2),
    template: process.env.POCKETDJ_STEM_LAUNCH_TEMPLATE || 'pocketdj-stem-worker',
    tag: 'pocketdj-stem-worker',
    vcpu: 2,                       // m7i.large
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
  },
};
const CFG = {
  region: process.env.AWS_REGION || 'us-west-2',
  totalVcpuCap: Number(process.env.POCKETDJ_TOTAL_VCPU_CAP || 56),
  lane: LANE,
  ...(LANES[LANE] || LANES.stem),
};
if (!LANES[LANE]) { console.error(`unknown --lane ${LANE}; use stem|timbre`); process.exit(2); }
const aws = (...a) => execFileSync('aws', [...a, '--region', CFG.region,
  ...(process.env.AWS_PROFILE ? ['--profile', process.env.AWS_PROFILE] : [])], { encoding: 'utf8' });

// visible = unclaimed backlog (drives scale-up); inflight = messages a worker is processing.
function queueDepth() {
  try {
    const out = aws('sqs', 'get-queue-attributes', '--queue-url', CFG.jobsQueue, '--attribute-names',
      'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', '--output', 'json');
    const a = JSON.parse(out).Attributes || {};
    return { visible: Number(a.ApproximateNumberOfMessages || 0), inflight: Number(a.ApproximateNumberOfMessagesNotVisible || 0) };
  } catch (e) {   // transient AWS error → skip this reconcile pass rather than abort
    console.error('queueDepth error:', e.message);
    return { visible: 0, inflight: 0 };
  }
}

function fleet(tag = CFG.tag) {
  const out = aws('ec2', 'describe-instances', '--filters', `Name=tag:${tag},Values=1`,
    'Name=instance-state-name,Values=pending,running', '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text');
  return out.split(/\s+/).filter(Boolean);
}

/// vCPU currently held by BOTH lanes. The account quota is shared; counting only our own lane is
/// how a reconcile ends up asking for capacity the other lane already spent.
function usedVcpu() {
  let used = 0;
  for (const l of Object.values(LANES)) {
    try { used += fleet(l.tag).length * l.vcpu; } catch { /* transient — treat as 0 for that lane */ }
  }
  return used;
}

function launch(n) {
  try {
    // --count min:max (1:n) launches as MANY as capacity/quota currently allows rather than
    // all-or-nothing — so bumping POCKETDJ_STEM_MAX_WORKERS after a quota increase scales up
    // smoothly instead of failing the whole reconcile when the fleet briefly exceeds capacity.
    const out = aws('ec2', 'run-instances', '--launch-template', `LaunchTemplateName=${CFG.template},Version=$Latest`,
      '--count', `1:${n}`, '--query', 'Instances[].InstanceId', '--output', 'text');
    return out.split(/\s+/).filter(Boolean);
  } catch (e) { console.error('launch error:', e.message); return []; }
}

function enqueue(ids) {
  for (const id of ids) {
    aws('sqs', 'send-message', '--queue-url', CFG.jobsQueue, '--message-body', JSON.stringify({ songId: id }));
    console.log('enqueued', id);
  }
}

/// Pure: how many instances this lane may launch, honouring both its own cap and the shared
/// account vCPU budget. Exported shape kept simple so a test can pin the arithmetic.
export function launchCount({ visible, fleetSize, maxWorkers, jobsPerWorker, vcpu, usedVcpu: used, totalVcpuCap }) {
  const desired = visible > 0 ? Math.min(maxWorkers, Math.ceil(visible / jobsPerWorker)) : 0;
  const byLane = Math.max(0, Math.min(desired - fleetSize, maxWorkers - fleetSize));
  const byQuota = Math.max(0, Math.floor((totalVcpuCap - used) / vcpu));
  return { desired, toLaunch: Math.min(byLane, byQuota), byLane, byQuota };
}

function reconcile({ dryRun }) {
  const { visible, inflight } = queueDepth();
  const f = fleet();
  const used = usedVcpu();
  const { desired, toLaunch, byQuota } = launchCount({
    visible, fleetSize: f.length, maxWorkers: CFG.maxWorkers, jobsPerWorker: CFG.jobsPerWorker,
    vcpu: CFG.vcpu, usedVcpu: used, totalVcpuCap: CFG.totalVcpuCap,
  });
  console.log(`[${CFG.lane}] queue: visible=${visible} inflight=${inflight} | fleet=${f.length}/${CFG.maxWorkers} `
    + `desired=${desired} vcpu=${used}/${CFG.totalVcpuCap} (quota allows ${byQuota}) launch=${toLaunch}`);
  if (dryRun || toLaunch <= 0) return;
  console.log('launched', launch(toLaunch).join(', '));
}

// Entrypoint guard around the WHOLE dispatch: launchCount is imported by tests, and an unguarded
// `--enqueue` branch would have fired real SQS sends the moment a test imported this file.
if (process.argv[1] && process.argv[1].endsWith('stem-autoscaler.mjs')) {
  // `--lane <name>` is consumed by CFG above; strip the flag AND its value before dispatching.
  const args = process.argv.slice(2).filter((x, i, a) => x !== '--lane' && a[i - 1] !== '--lane');
  if (args[0] === '--enqueue') enqueue(args.slice(1));
  else reconcile({ dryRun: args[0] === '--status' });
}
