#!/usr/bin/env node
// PocketDJ stem-worker autoscaler — the SCALE-UP half. A stateless reconcile pass meant to run
// on a schedule (launchd/cron every ~60s, or a Lambda on an EventBridge rule): it reads the
// job-queue depth and the current worker fleet, then launches just enough workers (up to a cap)
// to cover the backlog. It never scales DOWN — each worker retires itself after it has sat idle
// (stem-worker.mjs --serve → shutdown → instance-initiated-terminate), so the fleet drains to
// zero on its own. Net: fleet size tracks queue depth on the way up and idle time on the way down.
//
//   node stem-autoscaler.mjs                 one reconcile pass (launch workers if there's backlog)
//   node stem-autoscaler.mjs --status        print queue depth + fleet, change nothing
//   node stem-autoscaler.mjs --enqueue ID…   drop job markers (the rip server calls this same path)
//
// Env: POCKETDJ_RIPS_BUCKET, AWS_REGION,
//   POCKETDJ_STEM_MAX_WORKERS      hard cap on fleet size (gated by your EC2 vCPU quota), default 2
//   POCKETDJ_STEM_JOBS_PER_WORKER  queued jobs that justify one worker, default 2
//   POCKETDJ_STEM_LAUNCH_TEMPLATE  EC2 launch template name, default pocketdj-stem-worker
import { execFileSync } from 'node:child_process';

const CFG = {
  bucket: process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: process.env.AWS_REGION || 'us-west-2',
  maxWorkers: Number(process.env.POCKETDJ_STEM_MAX_WORKERS || 2),
  jobsPerWorker: Number(process.env.POCKETDJ_STEM_JOBS_PER_WORKER || 2),
  template: process.env.POCKETDJ_STEM_LAUNCH_TEMPLATE || 'pocketdj-stem-worker',
};
const JOBS_PREFIX = 'rips/stem-jobs/';
const aws = (...a) => execFileSync('aws', [...a, '--region', CFG.region], { encoding: 'utf8' });

// Pending jobs = .job.json markers only. A worker renames its marker to .claimed.json the moment
// it starts, so in-progress songs don't count as backlog and don't trigger redundant launches.
function queueDepth() {
  let out;
  try { out = aws('s3', 'ls', `s3://${CFG.bucket}/${JOBS_PREFIX}`); } catch { return []; }
  return out.split('\n').map((l) => l.trim().split(/\s+/).pop())
    .filter((n) => n && n.endsWith('.job.json')).map((n) => n.replace(/\.job\.json$/, ''));
}

function fleet() {
  const out = aws('ec2', 'describe-instances',
    '--filters', 'Name=tag:pocketdj-stem-worker,Values=1',
    'Name=instance-state-name,Values=pending,running',
    '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text');
  return out.split(/\s+/).filter(Boolean);
}

function launch(n) {
  const out = aws('ec2', 'run-instances',
    '--launch-template', `LaunchTemplateName=${CFG.template},Version=$Latest`, '--count', String(n),
    '--query', 'Instances[].InstanceId', '--output', 'text');
  return out.split(/\s+/).filter(Boolean);
}

function enqueue(ids) {
  for (const id of ids) {
    execFileSync('aws', ['s3', 'cp', '-', `s3://${CFG.bucket}/${JOBS_PREFIX}${id}.job.json`,
      '--content-type', 'application/json', '--region', CFG.region, '--only-show-errors'],
      { input: JSON.stringify({ songId: id, enqueuedAt: Date.now() }) });
    console.log('enqueued', id);
  }
}

function reconcile({ dryRun }) {
  const jobs = queueDepth();
  const f = fleet();
  const desired = jobs.length > 0 ? Math.min(CFG.maxWorkers, Math.ceil(jobs.length / CFG.jobsPerWorker)) : 0;
  const toLaunch = Math.max(0, Math.min(desired - f.length, CFG.maxWorkers - f.length));
  console.log(`queue=${jobs.length} fleet=${f.length}/${CFG.maxWorkers} desired=${desired} launch=${toLaunch}`);
  if (dryRun || toLaunch <= 0) return;
  console.log('launched', launch(toLaunch).join(', '));
}

const arg = process.argv[2];
if (arg === '--enqueue') enqueue(process.argv.slice(3));
else reconcile({ dryRun: arg === '--status' });
