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
//
// Env: AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE,
//   POCKETDJ_STEM_MAX_WORKERS (cap; gated by EC2 vCPU quota), POCKETDJ_STEM_JOBS_PER_WORKER,
//   POCKETDJ_STEM_LAUNCH_TEMPLATE.
import { execFileSync } from 'node:child_process';

const CFG = {
  region: process.env.AWS_REGION || 'us-west-2',
  jobsQueue: process.env.POCKETDJ_STEM_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-jobs',
  // 2026-07-19: standard-vCPU quota raised 5 → 64 (m7i.large = 2 vCPU ⇒ 32 max); default 30
  // keeps one instance-pair of headroom so an unrelated launch never trips a quota error.
  maxWorkers: Number(process.env.POCKETDJ_STEM_MAX_WORKERS || 30),
  jobsPerWorker: Number(process.env.POCKETDJ_STEM_JOBS_PER_WORKER || 2),
  template: process.env.POCKETDJ_STEM_LAUNCH_TEMPLATE || 'pocketdj-stem-worker',
};
const aws = (...a) => execFileSync('aws', [...a, '--region', CFG.region], { encoding: 'utf8' });

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

function fleet() {
  const out = aws('ec2', 'describe-instances', '--filters', 'Name=tag:pocketdj-stem-worker,Values=1',
    'Name=instance-state-name,Values=pending,running', '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text');
  return out.split(/\s+/).filter(Boolean);
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

function reconcile({ dryRun }) {
  const { visible, inflight } = queueDepth();
  const f = fleet();
  const desired = visible > 0 ? Math.min(CFG.maxWorkers, Math.ceil(visible / CFG.jobsPerWorker)) : 0;
  const toLaunch = Math.max(0, Math.min(desired - f.length, CFG.maxWorkers - f.length));
  console.log(`queue: visible=${visible} inflight=${inflight} | fleet=${f.length}/${CFG.maxWorkers} desired=${desired} launch=${toLaunch}`);
  if (dryRun || toLaunch <= 0) return;
  console.log('launched', launch(toLaunch).join(', '));
}

const arg = process.argv[2];
if (arg === '--enqueue') enqueue(process.argv.slice(3));
else reconcile({ dryRun: arg === '--status' });
