#!/usr/bin/env node
// Idempotent SPOT switch for the stem-worker EC2 launch template (`pocketdj-stem-worker`).
// Creates a NEW launch-template version whose only difference is `InstanceMarketOptions` (spot),
// then makes it the default. Launch templates are immutable, so "switching to spot" is exactly
// this: one more version. `stem-autoscaler.mjs` launches `Version=$Latest`, so the next reconcile
// pass (~60 s) launches spot instances — no autoscaler change, no worker change, no re-bake.
//
// PICK ONE MECHANISM — read before `--apply`. `stem-autoscaler.mjs` asks for spot PER LAUNCH
// (`--instance-market-options` on run-instances, `LANES.stem.market`), which is what lets it retry
// a capacity refusal on-demand. `RunInstances` cannot un-set a template's market options —
// `MarketType` has no `on-demand` value — so baking spot into the TEMPLATE silently defeats that
// fallback: the on-demand retry launches spot again and fails again. While the autoscaler owns the
// market, leave the template on-demand and use this script for `--status`. Bake it in only if the
// market moves out of the autoscaler (a hand-run run-instances, a Lambda, an ASG with no fallback
// of its own), and set POCKETDJ_STEM_MARKET=on-demand in the same change so the two agree.
//
// WHY THIS WORKLOAD IS SPOT-SAFE — the fleet is a herd of stateless SQS consumers. A job is
// claimed by the queue's visibility timeout (1800 s), never by the instance; the worker deletes
// the message only after the result is posted. A spot reclamation kills an instance mid-Demucs
// and loses nothing but that separation's CPU minutes: the un-deleted message returns to visible
// and another worker (or a replacement the autoscaler launches on the next tick) picks it up.
// Three receives without a delete → DLQ → `pumpStemDlq` marks the job errored, same as any other
// failure. `stem-worker.mjs` also watches IMDS for the ~2-minute reclaim notice and hands its
// in-flight job straight back (re-sent with a fresh delivery count), so the usual case costs
// seconds rather than the visibility timeout — but correctness never depended on that watcher
// firing, which is exactly why this switch is safe.
//
// SPOT SHAPE, and why each field is what it is:
//   MarketType=spot                     — the whole point.
//   SpotInstanceType=one-time           — NOT `persistent`. A persistent request re-launches the
//     instance after ANY termination, including a worker that self-retired on idle
//     (InstanceInitiatedShutdownBehavior=terminate). That would fight the scale-to-zero design
//     and bill forever. One-time = fire and forget; the autoscaler is the only thing that decides
//     to launch.
//   InstanceInterruptionBehavior=terminate — the only behavior a one-time request allows (stop
//     and hibernate need `persistent`), and the one we want: workers are disposable.
//   NO MaxPrice                         — an unset max bids the ON-DEMAND price, so we never pay
//     more than today's on-demand bill and a price spike degrades to on-demand economics instead
//     of leaving the fleet un-launchable with a backlog.
//
// MULTI-AZ — the second thing this script now owns. Spot capacity is per-AZ, and the template
// pinned ONE subnet (us-west-2a), so one AZ's capacity crunch stalled the queue or pushed the whole
// fleet to on-demand. `--multi-az` restructures the template so `stem-autoscaler.mjs` can pick a
// subnet PER LAUNCH and spread across all four AZs. See RESTRUCTURE below for why that is a
// template change and not just an autoscaler flag.
//
//   node scripts/stem-spot-setup.mjs            read-only status (the default — see below)
//   node scripts/stem-spot-setup.mjs --status   same, explicitly
//   node scripts/stem-spot-setup.mjs --apply    new version WITH spot options, set as default
//   node scripts/stem-spot-setup.mjs --multi-az new version that lets run-instances choose the subnet
//   node scripts/stem-spot-setup.mjs --revert   back to on-demand AND the single pinned subnet
//
// The bare run is READ-ONLY on purpose: a mis-typed or half-remembered invocation of a script
// that mutates the live fleet's launch template must not mutate anything. Mutating needs one of
// the explicit verbs, and exactly one at a time.
//
// RESTRUCTURE — why multi-AZ cannot be done from the autoscaler alone. `RunInstances` rejects
// `--subnet-id` when the launch template defines a `NetworkInterfaces` block: the API's own words
// are "If you specify a network interface, you must specify any subnets as part of the network
// interface instead of using this parameter" (same sentence for security groups). The live
// template defines exactly such a block, with the subnet inside it. Two ways out:
//
//   (a) override `--network-interfaces` wholesale on every launch — the caller must then restate
//       DeviceIndex, Groups, AssociatePublicIpAddress and DeleteOnTermination every time, and any
//       future template edit to the ENI block is silently ignored. Network config moves out of the
//       template and into the caller, where it drifts.
//   (b) DROP the block and move the security groups to top-level `SecurityGroupIds`, so a plain
//       `--subnet-id` is legal. One token per launch, template stays the single source of truth.
//
// This script does (b). The catch, and it is the load-bearing one: `AssociatePublicIpAddress`
// exists ONLY inside a NetworkInterfaces block — there is no top-level equivalent in
// `RequestLaunchTemplateData`. Dropping the block therefore drops the explicit public-IP request,
// and public addressing falls back to the SUBNET's `MapPublicIpOnLaunch`. That is safe here only
// because all four subnets in the default VPC have it TRUE, so `--multi-az` REFUSES to run if any
// target subnet is private: workers with no public IP cannot reach SQS, pip or HuggingFace and
// would hang at boot, in an AZ nobody is watching.
//
// A REMOVAL CANNOT BE MERGED. `create-launch-template-version --source-version` merges, and a
// merge can add a field but never remove one — the same reason `--revert` could not simply un-set
// the market options. So `--multi-az` and `--revert` post the FULL LaunchTemplateData explicitly
// (no --source-version) and then diff the result against what they intended, key by key. That
// diff is not decoration: `$Latest` is what the autoscaler launches, so a version that lost
// UserData or the IAM profile breaks EVERY launch the moment it is created — before anyone could
// set a default. Hence the post-condition, and hence the automatic rollback that deletes a version
// that fails it.
//
// Env: AWS_REGION (us-west-2), AWS_PROFILE (levi), POCKETDJ_STEM_LAUNCH_TEMPLATE,
//   POCKETDJ_STEM_PIN_SUBNET (the single subnet `--revert` restores),
//   POCKETDJ_STEM_MAX_WORKERS (read only to compare against the spot quota).
import { execFileSync } from 'node:child_process';

const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const TEMPLATE = process.env.POCKETDJ_STEM_LAUNCH_TEMPLATE || 'pocketdj-stem-worker';
// The AZ the template pinned before the multi-AZ restructure, and the one `--revert` puts back.
const PIN_SUBNET = process.env.POCKETDJ_STEM_PIN_SUBNET || 'subnet-00a23032877bbe190';   // us-west-2a
// Read, never written, from the autoscaler's own env var: `--status` prints it beside the spot
// quota so the mismatch that quietly turned a spot fleet into a full-price one is visible.
const LANE_MAX_WORKERS = Number(process.env.POCKETDJ_STEM_MAX_WORKERS || 30);
const aws = (...a) => execFileSync('aws', [...a, '--region', REGION, '--profile', PROFILE], { encoding: 'utf8' }).trim();
const j = (...a) => JSON.parse(aws(...a, '--output', 'json'));

const SPOT_OPTIONS = {
  MarketType: 'spot',
  SpotOptions: { SpotInstanceType: 'one-time', InstanceInterruptionBehavior: 'terminate' },
};
// us-west-2 Linux on-demand, for the discount column only — nothing is decided from this number,
// so a stale entry costs a wrong percentage in a printout and never a wrong launch.
const ON_DEMAND = { 'm7i.large': 0.1008, 'c7i.xlarge': 0.1785, 'c7g.2xlarge': 0.2890, 'm7g.large': 0.0816 };
// Spot vCPU is its OWN quota, not a slice of the on-demand one — the single most surprising fact
// about this switch. `Running On-Demand Standard instances` is 64; `All Standard Spot Instance
// Requests` is a separate 32, so a spot stem fleet tops out at 16 × m7i.large no matter what
// POCKETDJ_STEM_MAX_WORKERS says. Printed on every run so the ceiling is never a surprise.
const SPOT_QUOTA_CODE = 'L-34B43A08';   // All Standard (A,C,D,H,I,M,R,T,Z) Spot Instance Requests

// The worker's instance role, and the queue whose messages it hands back on a reclaim.
const WORKER_ROLE = process.env.POCKETDJ_STEM_WORKER_ROLE || 'pocketdj-stem-worker';
const WORKER_CODE_BUCKET = process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623';
const JOBS_QUEUE_ARN = process.env.POCKETDJ_STEM_JOBS_QUEUE_ARN
  || 'arn:aws:sqs:us-west-2:011183829623:pocketdj-stem-jobs';

/// PREFLIGHT: can the worker actually execute the release path it now depends on?
///
/// `releaseInflight()` hands a reclaimed job back in one of two ways — re-send the body as a new
/// message (`sqs:SendMessage`), or `ChangeMessageVisibility(0)` (`sqs:ChangeMessageVisibility`).
/// The second is the SAFETY NET: it is what runs when the body cannot be re-sent, when the
/// spot-requeue hop cap is reached, AND in the catch that fires when the re-send itself failed.
/// The stem worker's role was written before any of that existed and grants Receive/Delete/Send
/// only, so every one of those paths currently ends in `STRANDED` and the job waits out the full
/// 1800 s visibility timeout — the exact stall the spot watcher was added to remove. Nothing throws
/// and nothing alarms; it just silently degrades to pre-spot behaviour on the unhappy paths.
///
/// Read-only: `simulate-principal-policy` evaluates, it does not grant. The fix is printed, not run
/// — a script whose job is the launch template must not quietly rewrite an IAM role.
function iamPreflight() {
  const needed = ['sqs:ReceiveMessage', 'sqs:DeleteMessage', 'sqs:SendMessage', 'sqs:ChangeMessageVisibility'];
  let results;
  try {
    results = j('iam', 'simulate-principal-policy',
      '--policy-source-arn', `arn:aws:iam::011183829623:role/${WORKER_ROLE}`,
      '--action-names', ...needed, '--resource-arns', JOBS_QUEUE_ARN).EvaluationResults;
  } catch (e) { console.log(`\n  worker IAM: simulate failed (${e.message.split('\n')[0]})`); return; }
  const missing = results.filter((r) => r.EvalDecision !== 'allowed').map((r) => r.EvalActionName);
  console.log(`\nworker role ${WORKER_ROLE} on the jobs queue`);
  for (const r of results) console.log(`  ${r.EvalDecision === 'allowed' ? 'ok     ' : 'MISSING'}  ${r.EvalActionName}`);
  if (!missing.includes('sqs:ChangeMessageVisibility')) return;
  console.log('\n  ⚠ sqs:ChangeMessageVisibility is NOT granted. The spot release path still works on'
    + '\n    its happy branch (re-send + delete, which only needs SendMessage/DeleteMessage), but its'
    + '\n    FALLBACKS do not: an unparseable body, a job past the spot-requeue hop cap, or a re-send'
    + '\n    that failed all end in STRANDED and wait out the 1800s visibility timeout. Grant it:'
    + `\n\n    aws iam get-role-policy --role-name ${WORKER_ROLE} --policy-name rips-s3 \\`
    + '\n      --query PolicyDocument --output json --profile levi > /tmp/rips-s3.json'
    + '\n    # add "sqs:ChangeMessageVisibility" to the sqs Action list in /tmp/rips-s3.json, then:'
    + `\n    aws iam put-role-policy --role-name ${WORKER_ROLE} --policy-name rips-s3 \\`
    + '\n      --policy-document file:///tmp/rips-s3.json --profile levi\n');
}

/// PREFLIGHT: is the DEPLOYED worker spot-aware? The workers do not run this repo's
/// `stem-worker.mjs` — userdata copies it from `s3://…/worker-code/` at every boot — so the branch
/// merging is not the code the fleet runs. A spot-blind worker takes reclaims with no handler:
/// each one strands its job for the full 1800 s visibility timeout AND spends one of the queue's
/// three deliveries, so three unlucky reclaims dead-letter a song that never failed.
///
/// TWO SIGNALS, and the difference matters when they disagree. `stem-autoscaler.mjs` gates itself
/// on the object's BODY (it greps the deployed bytes for `spot/instance-action`, ETag-cached), so
/// the fleet is protected whoever deployed it. What this reads is the PROVENANCE stamp
/// `stem-deploy-worker.sh` writes after verifying its own upload — which tree, and when. So:
/// stamp present ⇒ verified deploy, spot is safe. Stamp absent ⇒ nobody vouched for these bytes;
/// the autoscaler may still allow spot if the body happens to carry the handler, but an operator
/// should deploy properly before relying on it. Read-only here: one HEAD, no download.
function workerCodePreflight() {
  const key = 'worker-code/stem-worker.mjs';
  let head;
  try {
    head = j('s3api', 'head-object', '--bucket', WORKER_CODE_BUCKET, '--key', key);
  } catch (e) { console.log(`\nworker code: HEAD failed (${e.message.split('\n')[0]})`); return; }
  const meta = head.Metadata || {};
  const stamped = meta['spot-aware'] === 'yes';
  console.log(`\nworker code s3://${WORKER_CODE_BUCKET}/${key}`);
  console.log(`  uploaded ${head.LastModified}  ${head.ContentLength} bytes`);
  if (stamped) {
    console.log(`  ok      spot-aware=yes (deployed ${meta['deployed-at'] || '?'}, sha256 ${(meta.sha256 || '').slice(0, 12)}…)`);
    return;
  }
  console.log('  MISSING spot-aware stamp — no verified deploy has vouched for these bytes.'
    + '\n          (The autoscaler checks the deployed BODY independently and stays on-demand if the'
    + '\n          interruption handler is absent, so this is a provenance gap, not an open door.)'
    + '\n          Deploy the current worker before turning spot on:'
    + '\n\n    bash scripts/stem-deploy-worker.sh --check    # what is deployed now'
    + '\n    bash scripts/stem-deploy-worker.sh            # push + verify + stamp\n');
}

const template = () => j('ec2', 'describe-launch-templates', '--launch-template-names', TEMPLATE).LaunchTemplates[0];
const versions = () => j('ec2', 'describe-launch-template-versions', '--launch-template-name', TEMPLATE)
  .LaunchTemplateVersions.sort((a, b) => a.VersionNumber - b.VersionNumber);
const market = (v) => v.LaunchTemplateData.InstanceMarketOptions || null;
const isSpot = (v) => market(v)?.MarketType === 'spot';
const subnetOf = (d) => d.NetworkInterfaces?.[0]?.SubnetId || d.SubnetId || null;

/// How this template's network is expressed, which is the same question as "can run-instances
/// choose an AZ?". `pinned` = a NetworkInterfaces block owns the subnet, so --subnet-id is illegal
/// and every worker lands in one AZ. `multi-az` = no block, security groups at top level, so the
/// caller passes --subnet-id and picks the pool.
function netOf(d) {
  const ni = d.NetworkInterfaces?.[0];
  if (ni) {
    return { mode: 'pinned', subnet: ni.SubnetId || null, groups: ni.Groups || [], publicIp: ni.AssociatePublicIpAddress === true };
  }
  return { mode: 'multi-az', subnet: d.SubnetId || null, groups: d.SecurityGroupIds || [], publicIp: null };
}

/// The VPC this template launches into — from the pinned subnet if there is one, else from a
/// security group (which is always VPC-scoped). Needed to enumerate the sibling subnets without
/// hardcoding four ids that would rot the first time the VPC changes.
function templateVpc(d) {
  const n = netOf(d);
  try {
    if (n.subnet) return j('ec2', 'describe-subnets', '--subnet-ids', n.subnet).Subnets[0].VpcId;
    if (n.groups.length) return j('ec2', 'describe-security-groups', '--group-ids', n.groups[0]).SecurityGroups[0].VpcId;
  } catch { /* not fatal — callers degrade to "unknown" */ }
  return null;
}

const vpcSubnets = (vpcId) => j('ec2', 'describe-subnets', '--filters', `Name=vpc-id,Values=${vpcId}`)
  .Subnets.map((s) => ({ id: s.SubnetId, az: s.AvailabilityZone, public: s.MapPublicIpOnLaunch === true, free: s.AvailableIpAddressCount }))
  .sort((a, b) => a.az.localeCompare(b.az));

/// `describe-launch-template-versions` returns ResponseLaunchTemplateData, which is NOT accepted
/// verbatim by `create-launch-template-version`. Verified against the botocore EC2 model, exactly
/// ONE field differs for the shape this template uses: `MetadataOptions.State` is response-only.
/// Feed it back and the create is rejected — which is the good outcome; the bad one is a future
/// field that is silently dropped, which is why every full rewrite diffs its result afterwards.
function forRequest(d) {
  const c = JSON.parse(JSON.stringify(d));
  if (c.MetadataOptions) delete c.MetadataOptions.State;
  return c;
}

// Stable stringify so a post-condition diff compares content, not key order.
const stable = (x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? `{${Object.keys(x).sort().map((k) => `${JSON.stringify(k)}:${stable(x[k])}`).join(',')}}`
  : JSON.stringify(x));

/// Every top-level field that differs between two LaunchTemplateData blobs, ignoring the market
/// options we are deliberately adding/removing. A merge that silently dropped UserData or the
/// IAM profile would boot a worker that does nothing and bills anyway — cheap to catch here.
function driftedKeys(before, after) {
  const strip = (d) => { const c = { ...d }; delete c.InstanceMarketOptions; return c; };
  const [a, b] = [strip(before), strip(after)];
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].filter((k) => stable(a[k]) !== stable(b[k]));
}

function spotPrices(instanceType, hereAz) {
  let rows = [];
  try {
    rows = j('ec2', 'describe-spot-price-history', '--instance-types', instanceType,
      '--product-descriptions', 'Linux/UNIX', '--start-time', new Date().toISOString().replace(/\.\d+Z$/, ''))
      .SpotPriceHistory.sort((a, b) => a.AvailabilityZone.localeCompare(b.AvailabilityZone));
  } catch (e) { console.log(`  (spot price lookup failed: ${e.message.split('\n')[0]})`); return; }
  const od = ON_DEMAND[instanceType];
  console.log(`\nspot price now — ${instanceType}, Linux/UNIX, ${REGION}`
    + (od ? ` (on-demand $${od.toFixed(4)}/hr)` : ''));
  for (const r of rows) {
    const p = Number(r.SpotPrice);
    const off = od ? `  ${Math.round((1 - p / od) * 100)}% off` : '';
    console.log(`  ${r.AvailabilityZone}  $${p.toFixed(4)}/hr${off}`
      + (r.AvailabilityZone === hereAz ? '   ← this template pins this AZ' : ''));
  }
}

/// The spot ceiling in instances, printed NEXT TO the lane's own worker cap — because reading
/// either number alone is what produced a full-price fleet. Spot vCPU is its own quota bucket, so
/// a lane sized against the 64-vCPU ON-DEMAND quota (maxWorkers 30 = 60 vCPU) asks for nearly
/// double what the 32-vCPU spot quota can ever grant. The refusal that follows,
/// `MaxSpotInstanceCountExceeded`, is a capacity error, so the autoscaler's fallback retried the
/// WHOLE request on-demand — run-instances quota refusals are all-or-nothing, not "the excess" —
/// and a change meant to save ~60% ran the fleet at full price exactly when it was busiest.
/// Printing both numbers together is the cheap half of the fix; the arithmetic lives in the
/// autoscaler.
function spotCeiling(instanceType) {
  try {
    const vcpu = j('ec2', 'describe-instance-types', '--instance-types', instanceType).InstanceTypes[0].VCpuInfo.DefaultVCpus;
    const q = j('service-quotas', 'get-service-quota', '--service-code', 'ec2', '--quota-code', SPOT_QUOTA_CODE).Quota;
    const ceiling = Math.floor(q.Value / vcpu);
    console.log(`  spot quota:  ${q.Value} vCPU (${SPOT_QUOTA_CODE}) → max ${ceiling} × ${instanceType} on SPOT`);
    console.log(`  lane cap:    POCKETDJ_STEM_MAX_WORKERS=${LANE_MAX_WORKERS} workers = ${LANE_MAX_WORKERS * vcpu} vCPU`
      + ` (sized against the SEPARATE 64-vCPU on-demand quota)`);
    if (LANE_MAX_WORKERS > ceiling) {
      console.log(`  ⚠ MISMATCH: the lane may want ${LANE_MAX_WORKERS} workers but only ${ceiling} fit the spot quota.`
        + `\n    Spot launches must be capped at ${ceiling}; anything above that is on-demand at full price.`
        + `\n    Raise ${SPOT_QUOTA_CODE} to ${LANE_MAX_WORKERS * vcpu} to make the whole lane cheap:`
        + `\n      aws service-quotas request-service-quota-increase --service-code ec2 \\`
        + `\n        --quota-code ${SPOT_QUOTA_CODE} --desired-value ${LANE_MAX_WORKERS * vcpu} --profile ${PROFILE}`);
    } else {
      console.log(`  ok: the lane cap (${LANE_MAX_WORKERS}) fits inside the spot ceiling (${ceiling}).`);
    }
  } catch (e) { console.log(`  spot quota: lookup failed (${e.message.split('\n')[0]})`); }
}

/// The network half of `--status`: how the template expresses its network today, and every subnet
/// it COULD use. `public` is called out per subnet because the multi-AZ shape takes its public IP
/// from the subnet rather than the template — a private one here means workers that boot with no
/// route to SQS.
function networkStatus(d) {
  const n = netOf(d);
  if (n.mode === 'pinned') {
    console.log(`  network:     PINNED to one subnet via a NetworkInterfaces block`
      + `\n               subnet ${n.subnet}  groups ${n.groups.join(', ') || '(none)'}  publicIp=${n.publicIp}`
      + `\n               run-instances CANNOT pass --subnet-id while this block exists, so every`
      + `\n               worker lands in one AZ and draws on one spot pool. --multi-az changes this.`);
  } else {
    console.log(`  network:     MULTI-AZ — no NetworkInterfaces block, groups at top level`
      + `\n               groups ${n.groups.join(', ') || '(none)'}; run-instances chooses the subnet per launch`
      + `\n               public IPs come from the SUBNET's MapPublicIpOnLaunch, not the template`);
  }
  const vpc = templateVpc(d);
  if (!vpc) { console.log('  subnets:     (VPC could not be resolved)'); return; }
  let subs = [];
  try { subs = vpcSubnets(vpc); } catch (e) { console.log(`  subnets: lookup failed (${e.message.split('\n')[0]})`); return; }
  console.log(`  subnets in ${vpc}:`);
  for (const s of subs) {
    console.log(`    ${s.az}  ${s.id}  ${s.public ? 'public ' : 'PRIVATE'}  ${s.free} free IPs`
      + (s.id === n.subnet ? '   ← pinned' : ''));
  }
  const priv = subs.filter((s) => !s.public);
  if (priv.length) {
    console.log(`  ⚠ ${priv.length} subnet(s) are NOT MapPublicIpOnLaunch. In the multi-AZ shape a worker`
      + `\n    there gets no public IP and cannot reach SQS/pip/HuggingFace. --multi-az refuses to run`
      + `\n    while that is true; fix the subnet or exclude the AZ.`);
  }
}

function status() {
  const t = template();
  const vs = versions();
  const latest = vs.find((v) => v.VersionNumber === t.LatestVersionNumber);
  const def = vs.find((v) => v.VersionNumber === t.DefaultVersionNumber);
  const d = latest.LaunchTemplateData;
  const subnet = subnetOf(d);
  let az = null;
  if (subnet) { try { az = j('ec2', 'describe-subnets', '--subnet-ids', subnet).Subnets[0].AvailabilityZone; } catch { /* not fatal */ } }

  console.log(`${TEMPLATE} (${t.LaunchTemplateId})  latest=v${t.LatestVersionNumber}  default=v${t.DefaultVersionNumber}`);
  console.log(`  instance:    ${d.InstanceType}  ami: ${d.ImageId}${az ? `  (pinned AZ ${az})` : ''}`);
  spotCeiling(d.InstanceType);
  networkStatus(d);
  // $Latest is what the autoscaler launches, so THAT is the version whose market options decide
  // the bill; the default version only matters to a human running run-instances by hand.
  console.log(`  v${latest.VersionNumber} ($Latest, what stem-autoscaler.mjs launches): `
    + (isSpot(latest) ? `SPOT ${JSON.stringify(market(latest))}` : 'ON-DEMAND (no InstanceMarketOptions)'));
  if (def && def.VersionNumber !== latest.VersionNumber) {
    console.log(`  v${def.VersionNumber} ($Default): ` + (isSpot(def) ? 'SPOT' : 'ON-DEMAND'));
  }
  for (const v of vs) {
    const n = netOf(v.LaunchTemplateData);
    console.log(`    v${v.VersionNumber}  ${isSpot(v) ? 'spot     ' : 'on-demand'}  ${n.mode === 'pinned' ? '1-az    ' : 'multi-az'}`
      + `  ${v.CreateTime?.slice(0, 10) || ''}  ${v.VersionDescription || ''}`);
  }
  spotPrices(d.InstanceType, az);
  iamPreflight();
  workerCodePreflight();
  return { t, vs, latest };
}

/// Create a version by MERGING onto a source version — AWS's own idiom for "change one field".
/// Everything not named in `data` is inherited verbatim from `sourceVersion`, which is why this
/// script never has to re-post UserData, the IAM profile, tags or the ENI block and never has to
/// keep them in sync with whatever the template holds today.
function newVersion(sourceVersion, data, description) {
  const out = j('ec2', 'create-launch-template-version', '--launch-template-name', TEMPLATE,
    '--source-version', String(sourceVersion), '--version-description', description,
    '--launch-template-data', JSON.stringify(data));
  return out.LaunchTemplateVersion;
}

function setDefault(n) {
  aws('ec2', 'modify-launch-template', '--launch-template-name', TEMPLATE, '--default-version', String(n), '--output', 'json');
}

/// Create a version from FULL data — no --source-version, so nothing is inherited and a field left
/// out is a field REMOVED. That is the only way to take `NetworkInterfaces` back off a template
/// (a merge cannot remove), and it is why every caller here hands over a blob built from the
/// current $Latest rather than a hand-written one.
function newVersionFull(data, description) {
  const out = j('ec2', 'create-launch-template-version', '--launch-template-name', TEMPLATE,
    '--version-description', description, '--launch-template-data', JSON.stringify(data));
  return out.LaunchTemplateVersion;
}

const deleteVersion = (n) => aws('ec2', 'delete-launch-template-versions', '--launch-template-name', TEMPLATE,
  '--versions', String(n), '--output', 'json');

/// Post-condition for a full rewrite, with a ROLLBACK attached. `$Latest` is what the autoscaler
/// launches, so a new version is LIVE the instant it exists — there is no staging step and no
/// "set the default when you're happy". A version that dropped UserData or the IAM profile would
/// therefore break every launch within 60 s, and a fleet that boots into nothing is a full
/// pipeline outage, not a degradation. So: compare what came back against what we asked for, and
/// if they differ, DELETE the version immediately so $Latest falls back to the previous good one.
function assertOrRollback(v, intended, allowedKeys) {
  const got = forRequest(v.LaunchTemplateData);
  const drift = [...new Set([...Object.keys(intended), ...Object.keys(got)])]
    .filter((k) => stable(intended[k]) !== stable(got[k]));
  const unexpected = drift.filter((k) => !allowedKeys.includes(k));
  if (!unexpected.length) return;
  console.error(`\nPOST-CONDITION FAILED on v${v.VersionNumber}: ${unexpected.join(', ')} differ from what was sent.`);
  for (const k of unexpected) {
    console.error(`  ${k}\n    sent: ${stable(intended[k])?.slice(0, 200)}\n    got:  ${stable(got[k])?.slice(0, 200)}`);
  }
  try {
    deleteVersion(v.VersionNumber);
    console.error(`\nROLLED BACK: v${v.VersionNumber} deleted, so $Latest is v${v.VersionNumber - 1} again and launches keep working.`);
  } catch (e) {
    console.error(`\n!! ROLLBACK FAILED (${e.message.split('\n')[0]}).`
      + `\n   v${v.VersionNumber} is $Latest RIGHT NOW and the autoscaler launches $Latest every 60s.`
      + `\n   Delete it by hand immediately:`
      + `\n     aws ec2 delete-launch-template-versions --launch-template-name ${TEMPLATE} \\`
      + `\n       --versions ${v.VersionNumber} --region ${REGION} --profile ${PROFILE}`);
  }
  throw new Error(`launch template rewrite rejected — no change is in effect`);
}

/// --multi-az: drop the NetworkInterfaces block and move its security groups to top-level
/// SecurityGroupIds, so `stem-autoscaler.mjs` can pass `--subnet-id` and spread the fleet across
/// every AZ's spot pool. Everything else — AMI, instance type, IAM profile, key pair, shutdown
/// behaviour, UserData, tags, metadata options, and any market options already present — is
/// carried across verbatim from the current $Latest and then asserted unchanged.
function applyMultiAz() {
  const { t, latest } = status();
  const d = latest.LaunchTemplateData;
  const n = netOf(d);
  if (n.mode === 'multi-az') {
    console.log(`\nalready multi-AZ at v${latest.VersionNumber} — no new version created`);
    return { template: t.LaunchTemplateId, version: latest.VersionNumber, network: 'multi-az', created: false };
  }
  if (!n.groups.length) {
    throw new Error('the pinned NetworkInterfaces block names no security groups — refusing to guess one');
  }
  // PREFLIGHT, and the reason this verb can refuse. Without the ENI block there is no
  // AssociatePublicIpAddress to set (no top-level equivalent exists), so a worker's public IP —
  // its only route to SQS, pip and HuggingFace — comes from the subnet. A private subnet in the
  // rotation produces workers that boot, reach nothing, and idle out, in whichever AZ the
  // autoscaler happened to pick.
  const vpc = templateVpc(d);
  if (!vpc) throw new Error('could not resolve the template VPC — refusing to restructure blind');
  const subs = vpcSubnets(vpc);
  const priv = subs.filter((s) => !s.public);
  if (priv.length) {
    throw new Error(`${priv.map((s) => `${s.id} (${s.az})`).join(', ')} have MapPublicIpOnLaunch=false.`
      + ' In the multi-AZ shape the public IP comes from the subnet, so workers there would have no'
      + ' route to SQS. Enable it on those subnets, or set POCKETDJ_STEM_SUBNETS in the autoscaler'
      + ' to the public ones only, before restructuring.');
  }
  const data = forRequest(d);
  delete data.NetworkInterfaces;
  data.SecurityGroupIds = n.groups;
  const v = newVersionFull(data, `multi-AZ: SecurityGroupIds at top level, subnet chosen per launch (was ${n.subnet})`);
  // NetworkInterfaces/SecurityGroupIds are the only two keys allowed to differ; anything else
  // differing means the rewrite lost a field and the version is deleted before it can launch.
  assertOrRollback(v, data, ['NetworkInterfaces', 'SecurityGroupIds']);
  const after = netOf(v.LaunchTemplateData);
  if (after.mode !== 'multi-az') { deleteVersion(v.VersionNumber); throw new Error(`v${v.VersionNumber} still carries a NetworkInterfaces block — deleted`); }
  setDefault(v.VersionNumber);
  console.log(`\nv${v.VersionNumber} created from v${latest.VersionNumber} and set as default — MULTI-AZ.`);
  console.log(`  security groups now top-level: ${after.groups.join(', ')}`);
  console.log(`  subnets now available to run-instances --subnet-id:`);
  for (const s of subs) console.log(`    ${s.az}  ${s.id}`);
  console.log('\nstem-autoscaler.mjs must now pass --subnet-id on every launch: with no block AND no');
  console.log('--subnet-id, EC2 falls back to a default subnet, which quietly re-pins one AZ.');
  return { template: t.LaunchTemplateId, version: v.VersionNumber, network: 'multi-az', subnets: subs.map((s) => s.id), created: true };
}

function apply() {
  const { t, latest } = status();
  if (isSpot(latest)) {
    console.log(`\nalready spot at v${latest.VersionNumber} — no new version created`);
    if (t.DefaultVersionNumber !== latest.VersionNumber) { setDefault(latest.VersionNumber); console.log(`default → v${latest.VersionNumber}`); }
    return { template: t.LaunchTemplateId, version: latest.VersionNumber, market: market(latest), created: false };
  }
  // Printed, not just documented: whoever runs --apply months from now is the person who most
  // needs to know it turns the autoscaler's on-demand fallback into a no-op.
  console.log('\nNOTE: stem-autoscaler.mjs asks for spot PER LAUNCH by default and retries on-demand when spot'
    + '\n      has no capacity. A spot-baked template cannot be overridden back to on-demand at'
    + '\n      run-instances time, so that fallback stops working. Set POCKETDJ_STEM_MARKET=on-demand'
    + '\n      alongside this change, or use --revert and let the autoscaler own the market.');
  const v = newVersion(latest.VersionNumber, { InstanceMarketOptions: SPOT_OPTIONS },
    `spot: one-time, terminate on interruption, no max price (from v${latest.VersionNumber})`);
  const drift = driftedKeys(latest.LaunchTemplateData, v.LaunchTemplateData);
  if (drift.length) console.log(`\nWARNING: v${v.VersionNumber} differs from v${latest.VersionNumber} beyond the market options: ${drift.join(', ')}`);
  if (!isSpot(v)) throw new Error(`v${v.VersionNumber} did not come back as spot — refusing to make it the default`);
  setDefault(v.VersionNumber);
  console.log(`\nv${v.VersionNumber} created from v${latest.VersionNumber} and set as default — SPOT.`);
  console.log('The autoscaler launches $Latest, so the next reconcile (~60 s) launches spot workers.');
  return { template: t.LaunchTemplateId, version: v.VersionNumber, market: market(v), created: true };
}

/// --revert: the ONE command that puts the template all the way back — ON-DEMAND market AND the
/// single pinned subnet — in a single new version. Both are removals (market options off, the
/// top-level SecurityGroupIds replaced by an ENI block), and a merge cannot remove, so this is a
/// full rewrite built from the current $Latest.
///
/// This is a strict improvement on the old branch-from-an-older-version revert, which reached
/// on-demand by re-posting an ancient version and silently left behind every template edit made
/// since — a new UserData among them. Building from $Latest and deleting only the two things being
/// reverted keeps all of that.
function revert() {
  const { t, latest } = status();
  const d = latest.LaunchTemplateData;
  const n = netOf(d);
  const wasSpot = isSpot(latest);
  const wasMulti = n.mode === 'multi-az';
  if (!wasSpot && !wasMulti) {
    console.log(`\nalready on-demand AND pinned to one subnet at v${latest.VersionNumber} — no new version created`);
    if (t.DefaultVersionNumber !== latest.VersionNumber) { setDefault(latest.VersionNumber); console.log(`default → v${latest.VersionNumber}`); }
    return { template: t.LaunchTemplateId, version: latest.VersionNumber, market: null, network: 'pinned', created: false };
  }
  const groups = n.groups;
  if (wasMulti && !groups.length) throw new Error('no SecurityGroupIds to fold back into a NetworkInterfaces block — refusing to guess');
  const data = forRequest(d);
  delete data.InstanceMarketOptions;                       // → on-demand
  if (wasMulti) {                                          // → back to the one pinned subnet
    delete data.SecurityGroupIds;
    data.NetworkInterfaces = [{
      DeviceIndex: 0, SubnetId: PIN_SUBNET, Groups: groups,
      AssociatePublicIpAddress: true, DeleteOnTermination: true,
    }];
  }
  const what = [wasSpot && 'on-demand', wasMulti && `re-pinned to ${PIN_SUBNET}`].filter(Boolean).join(' + ');
  const v = newVersionFull(data, `revert: ${what} (from v${latest.VersionNumber})`);
  assertOrRollback(v, data, ['InstanceMarketOptions', 'NetworkInterfaces', 'SecurityGroupIds']);
  if (isSpot(v)) { deleteVersion(v.VersionNumber); throw new Error(`v${v.VersionNumber} still carries spot market options — deleted`); }
  const after = netOf(v.LaunchTemplateData);
  if (after.mode !== 'pinned' || after.subnet !== PIN_SUBNET) {
    deleteVersion(v.VersionNumber);
    throw new Error(`v${v.VersionNumber} did not come back pinned to ${PIN_SUBNET} — deleted`);
  }
  setDefault(v.VersionNumber);
  console.log(`\nv${v.VersionNumber} created from v${latest.VersionNumber} and set as default — ON-DEMAND, pinned to ${PIN_SUBNET}.`);
  console.log('NOTE: this reverts the TEMPLATE. stem-autoscaler.mjs asks for spot per launch and picks');
  console.log('      a subnet per launch, so also set POCKETDJ_STEM_MARKET=on-demand (and stop passing');
  console.log('      --subnet-id) or the next reconcile puts both straight back.');
  return { template: t.LaunchTemplateId, version: v.VersionNumber, market: null, network: 'pinned', created: true };
}

const VERBS = ['--apply', '--revert', '--status', '--multi-az'];
const USAGE = 'usage: stem-spot-setup.mjs [--status | --apply | --multi-az | --revert]';
const args = process.argv.slice(2);
const wanted = args.filter((a) => VERBS.includes(a));
const unknown = args.filter((a) => !wanted.includes(a));
if (unknown.length) { console.error(`unknown arg(s): ${unknown.join(' ')}\n${USAGE}`); process.exit(2); }
// One verb at a time, deliberately — `--multi-az --revert` reads like "revert to multi-AZ" and
// means the opposite, and both mutate a template that is live on the next 60s tick.
if (wanted.length > 1) { console.error(`pick ONE of ${VERBS.join(' | ')} (got ${wanted.join(' ')})`); process.exit(2); }
try {
  if (wanted[0] === '--apply') console.log(JSON.stringify(apply(), null, 2));
  else if (wanted[0] === '--multi-az') console.log(JSON.stringify(applyMultiAz(), null, 2));
  else if (wanted[0] === '--revert') console.log(JSON.stringify(revert(), null, 2));
  else {
    status();
    if (!wanted.length) {
      console.log('\nread-only. --multi-az frees run-instances to choose the subnet (spread across AZs),');
      console.log('--apply bakes spot into the template (read the warning first),');
      console.log('--revert puts BOTH back: on-demand and the single pinned subnet.');
    }
  }
} catch (e) {
  console.error(`\nFAILED: ${e.message.split('\n').slice(0, 4).join('\n')}`);
  process.exit(1);
}
