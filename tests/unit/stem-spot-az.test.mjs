// MULTI-AZ SPOT — one AZ's capacity crunch must not stall the queue or force full price.
//
// Spot capacity is a PER-AZ pool. The launch template pins ONE subnet (subnet-00a23032877bbe190,
// us-west-2a), so before this change every stem worker competed for one pool: when us-west-2a ran
// dry, every 60 s reconcile in that window either launched nothing or paid on-demand at 2.7×, for
// hours, while the other three AZs sat wide open.
//
// MEASURED VPC FACTS (us-west-2, account 011183829623, verified 2026-09-06). vpc-003b55e5582595910
// is the default VPC and the only one. FOUR subnets, one per AZ, ALL public
// (MapPublicIpOnLaunch=true), ONE main route table (rtb-06c8f8ef5811a718f) with an internet-gateway
// default route serving all four, plus S3 gateway endpoint vpce-0341241602a451680 — so S3 is private
// and free from every AZ, and the public path (SQS, pip, HuggingFace) is identical from every AZ.
// There is no per-AZ reason to prefer one over another; the fan-out is free.
//
// ── THE CONSTRAINT THAT MAKES THIS DANGEROUS ────────────────────────────────────────────────────
// `RunInstances` REJECTS `--subnet-id` when the launch template defines a `NetworkInterfaces` block
// ("If you specify a network interface, you must specify any subnets as part of the network
// interface instead of using this parameter"). Every live version of `pocketdj-stem-worker` (v1–v4,
// all identical) defines exactly such a block, with NO top-level SubnetId and NO top-level
// SecurityGroupIds:
//     NetworkInterfaces: [{ DeviceIndex: 0, SubnetId: subnet-00a23032877bbe190,
//                           AssociatePublicIpAddress: true, DeleteOnTermination: true,
//                           Groups: [sg-053afe62aa1e78bf9] }]
//
// `stem-spot-setup.mjs --multi-az` restructures the template so a plain `--subnet-id` becomes legal.
// That restructure and this autoscaler ship independently, which is the whole reason
// `templateNetMode` exists: sending `--subnet-id` at a template that still carries the block fails
// EVERY launch, in every AZ, immediately — `InvalidParameterCombination`, which is in neither the
// next-AZ set nor the on-demand fallback set, so nothing recovers it. That is a full pipeline
// outage, not a degradation. The fail-safe direction is the OLD behaviour: one pinned AZ, which
// merely costs the fan-out.
import { describe, it, expect } from 'vitest';
import {
  SUBNETS, azOrder, shouldTryNextAz, templateNetMode, runInstancesArgs, shouldFallbackToOnDemand,
} from '../../scripts/stem-autoscaler.mjs';

// The live VPC, as measured. A typo in any of these ids fails every launch that picks that AZ — and
// only that AZ, so it would look like intermittent capacity trouble rather than a bug.
const MEASURED = {
  'us-west-2a': 'subnet-00a23032877bbe190',
  'us-west-2b': 'subnet-00f9be279c616ff01',
  'us-west-2c': 'subnet-0c623f93e8a27ea34',
  'us-west-2d': 'subnet-055bd6cc3fb64e8b7',
};
const SG = 'sg-053afe62aa1e78bf9';

// `describe-launch-template-versions --launch-template-name pocketdj-stem-worker`, v4 ($Latest at
// the time of writing), trimmed to the fields this decision reads. This is the shape live TODAY.
const LIVE_PINNED = {
  InstanceType: 'm7i.large',
  NetworkInterfaces: [{
    AssociatePublicIpAddress: true, DeleteOnTermination: true, DeviceIndex: 0,
    Groups: [SG], SubnetId: MEASURED['us-west-2a'],
  }],
};
// What `stem-spot-setup.mjs --multi-az` produces: no block, groups hoisted to the top level.
const RESTRUCTURED = { InstanceType: 'm7i.large', SecurityGroupIds: [SG] };

const CMD = 'Command failed: aws ec2 run-instances --launch-template '
  + 'LaunchTemplateName=pocketdj-stem-worker,Version=$Latest --count 1:16 --region us-west-2\n';
const awsErr = (code, detail) => `${CMD}\nAn error occurred (${code}) when calling the RunInstances operation: ${detail}`;

const NO_CAPACITY_HERE = awsErr('InsufficientInstanceCapacity',
  'We currently do not have sufficient m7i.large capacity in the Availability Zone you requested '
  + '(us-west-2a). Our system will be working on provisioning additional capacity.');
const NO_HOST_CAPACITY = awsErr('InsufficientHostCapacity',
  'There is no available capacity for the requested instance type.');
const PRICE_TOO_LOW = awsErr('SpotMaxPriceTooLow',
  'Your Spot request price of 0.02 is lower than the minimum required Spot request fulfillment price of 0.0375.');
const SPOT_QUOTA = awsErr('MaxSpotInstanceCountExceeded', 'Max spot instance count exceeded');
const UNAUTHORIZED = awsErr('UnauthorizedOperation',
  'You are not authorized to perform: ec2:RunInstances in us-west-2.');
const NO_TEMPLATE = awsErr('InvalidLaunchTemplateName.NotFoundException',
  'At least one of the launch templates specified in the request does not exist.');
const BAD_NET = awsErr('InvalidParameterCombination',
  'Network interfaces and an instance-level subnet ID may not be specified on the same request');

describe('SUBNETS — all four AZs, spelled the way the account spells them', () => {
  it('covers every AZ in the default VPC exactly once', () => {
    expect(SUBNETS).toHaveLength(4);
    expect(SUBNETS.map((s) => s.az).sort()).toEqual(['us-west-2a', 'us-west-2b', 'us-west-2c', 'us-west-2d']);
    expect(new Set(SUBNETS.map((s) => s.subnetId)).size).toBe(4);
  });

  it('maps each AZ to the subnet id that actually exists there', () => {
    // A wrong-but-well-formed id is the nasty case: run-instances refuses only the launches that
    // pick that AZ, so a quarter of passes fail and it reads as flaky spot capacity for weeks.
    for (const { az, subnetId } of SUBNETS) expect(subnetId).toBe(MEASURED[az]);
  });

  it('still includes the AZ the template pins today — the fan-out ADDS pools, it does not move them', () => {
    expect(SUBNETS.map((s) => s.subnetId)).toContain(MEASURED['us-west-2a']);
  });
});

describe('azOrder — every subnet exactly once, and not always the same one first', () => {
  const ids = (o) => o.map((s) => s.subnetId);
  const ALL = [...SUBNETS];

  it('is a PERMUTATION for every seed', () => {
    // Duplicates would double-ask one pool and skip another; a missing entry would leave a whole
    // AZ's capacity permanently unused, which is exactly what this change exists to fix.
    for (const seed of [0, 1, 2, 3, 4, 7, 41, 1757, 1_757_167_200_000]) {
      const order = azOrder(seed);
      expect(order).toHaveLength(ALL.length);
      expect(ids(order).sort()).toEqual(ids(ALL).sort());
      expect(new Set(ids(order)).size).toBe(ALL.length);
    }
  });

  it('varies the LEAD across passes — a fixed lead is the single-pool bug with extra steps', () => {
    expect(new Set([0, 1, 2, 3].map((s) => azOrder(s)[0].az)).size).toBeGreaterThan(1);
  });

  it('gives every AZ a turn at the front, within one lap of the cursor', () => {
    // The lead AZ is where the bulk of a pass's instances come from, since later zones are only
    // reached after a refusal. An ordering that led with 2a most of the time would keep the fleet in
    // one pool and only look multi-AZ.
    expect(new Set([0, 1, 2, 3].map((s) => azOrder(s)[0].az)))
      .toEqual(new Set(['us-west-2a', 'us-west-2b', 'us-west-2c', 'us-west-2d']));
  });

  it('rotates rather than reshuffles — the whole list advances by one each tick', () => {
    // Rotation is what makes the order predictable enough to log and to re-derive afterwards: the AZ
    // that led last tick becomes the last resort this tick, so a dry zone is demoted, not dropped.
    expect(azOrder(0)).toEqual(ALL);
    expect(azOrder(1)).toEqual([ALL[1], ALL[2], ALL[3], ALL[0]]);
    expect(azOrder(3)).toEqual([ALL[3], ALL[0], ALL[1], ALL[2]]);
    expect(azOrder(4)).toEqual(ALL);          // the cursor wraps
  });

  it('is DETERMINISTIC — the same cursor plans the same way twice', () => {
    for (const seed of [0, 2, 9, 1_757_167_200_000]) expect(azOrder(seed)).toEqual(azOrder(seed));
  });

  it('DEDUPES — a duplicated subnet must not spend a retry on a pool that just refused', () => {
    // POCKETDJ_STEM_SUBNETS is a comma-separated env var; a copy-paste repeat is the obvious way it
    // gets one twice, and the cost is a wasted launch attempt during exactly the capacity crunch the
    // walk exists to survive.
    const dupes = [ALL[0], ALL[1], ALL[0], ALL[2], ALL[1], ALL[3]];
    expect(azOrder(0, dupes)).toEqual(ALL);
    expect(new Set(ids(azOrder(2, dupes))).size).toBe(4);
  });

  it('drops malformed entries rather than launching into an undefined subnet', () => {
    expect(azOrder(0, [null, undefined, {}, { az: 'us-west-2z' }, ALL[0]])).toEqual([ALL[0]]);
  });

  it('handles a one-AZ list and an empty one without throwing or looping', () => {
    // POCKETDJ_STEM_SUBNETS pinning a single AZ (to reproduce a capacity report, say) must not
    // produce an empty plan; an EMPTY list must mean "no override", never "no launch".
    expect(azOrder(0, [ALL[2]])).toEqual([ALL[2]]);
    expect(azOrder(7, [ALL[2]])).toEqual([ALL[2]]);
    expect(azOrder(0, [])).toEqual([]);
    expect(azOrder(9, [])).toEqual([]);
  });

  it('never throws on a nonsense seed or a non-list, and still returns a permutation', () => {
    // The cursor is read from a JSON state file that a half-finished write can corrupt. A throw here
    // kills the whole reconcile before it ever reaches the queue.
    for (const seed of [NaN, -1, -7, 1.5, Infinity, -Infinity, undefined, null, 'x', {}]) {
      expect(() => azOrder(seed)).not.toThrow();
      expect(ids(azOrder(seed)).sort()).toEqual(ids(ALL).sort());
    }
    for (const bad of [null, 'subnet-x', 7, {}]) {
      expect(() => azOrder(0, bad)).not.toThrow();
      expect(azOrder(0, bad)).toEqual([]);
    }
  });

  it('walks a NEGATIVE cursor forward, not off the end of the array', () => {
    // `((seed % n) + n) % n` rather than a bare remainder, which is negative in JS: `slice(-1)` would
    // silently return a ONE-element order, leaving three AZs unreachable.
    expect(azOrder(-1)).toHaveLength(4);
    expect(azOrder(-1)).toEqual(azOrder(3));
  });

  it('is pure — it does not mutate the list it was handed', () => {
    const input = [...ALL];
    azOrder(2, input);
    expect(input).toEqual(ALL);
  });
});

describe('shouldTryNextAz — fan out on a POOL refusal, stand still on anything else', () => {
  it('advances when THIS AZ has no capacity — the next pool is a different answer', () => {
    expect(shouldTryNextAz(NO_CAPACITY_HERE)).toBe(true);
    expect(shouldTryNextAz(NO_HOST_CAPACITY)).toBe(true);
  });

  it('advances when THIS AZ\'s spot price floor is above our bid — prices are per-AZ', () => {
    // stem-spot-setup.mjs prints per-AZ prices precisely because they differ; a floor that is too
    // high in us-west-2a says nothing about us-west-2d.
    expect(shouldTryNextAz(PRICE_TOO_LOW)).toBe(true);
  });

  it('does NOT advance on MaxSpotInstanceCountExceeded — the spot quota is REGIONAL', () => {
    // The one input that separates the two questions, and the reason there are two functions. Paying
    // on-demand for this IS right (that bucket is separate), but retrying it in another AZ is four
    // identical refusals against the same 32-vCPU account quota. Same error, opposite answers.
    expect(shouldTryNextAz(SPOT_QUOTA)).toBe(false);
    expect(shouldFallbackToOnDemand(SPOT_QUOTA)).toBe(true);
  });

  it('does NOT fan out across all four on a config failure', () => {
    // An IAM denial or a missing template fails identically in every AZ. Fanning out turns one clear
    // error into four and buries the real one under three copies.
    expect(shouldTryNextAz(UNAUTHORIZED)).toBe(false);
    expect(shouldTryNextAz(NO_TEMPLATE)).toBe(false);
  });

  it('does NOT advance on the malformed-request error this very change could introduce', () => {
    // If `--subnet-id` reaches a still-pinned template, EVERY AZ rejects it. Retrying around the
    // ring would make a total outage look like a capacity shortage and hide it behind the fallback —
    // which is also why this code is in neither set.
    expect(shouldTryNextAz(BAD_NET)).toBe(false);
    expect(shouldFallbackToOnDemand(BAD_NET)).toBe(false);
  });

  it('does not advance on an empty, absent, or unrecognised error', () => {
    for (const e of ['', '   ', undefined, null, 'aws: error: connection reset by peer',
      awsErr('RequestLimitExceeded', 'Request limit exceeded.')]) {
      expect(() => shouldTryNextAz(e)).not.toThrow();
      expect(shouldTryNextAz(e)).toBe(false);
    }
  });

  it('keys on the CODE, not on an AZ name appearing in the prose', () => {
    // Every fixture here mentions us-west-2 somewhere; a /us-west-2/ matcher passes the positives and
    // gets the negatives wrong.
    expect(UNAUTHORIZED).toContain('us-west-2');
    expect(shouldTryNextAz(UNAUTHORIZED)).toBe(false);
  });

  it('is a strict SUBSET of the fallback set — nothing may advance that would not also pay', () => {
    // Structural: an error worth another AZ is by definition a capacity condition, so it must also
    // be worth on-demand once every AZ has refused. The reverse does not hold (the regional quota).
    for (const e of [NO_CAPACITY_HERE, NO_HOST_CAPACITY, PRICE_TOO_LOW, SPOT_QUOTA, UNAUTHORIZED, NO_TEMPLATE, BAD_NET]) {
      if (shouldTryNextAz(e)) expect(shouldFallbackToOnDemand(e)).toBe(true);
    }
  });
});

// A pass walks `azOrder(...)` and stops at the first AZ that either succeeds or refuses for a reason
// no other AZ would fix. That loop is the point of the two functions above, so it is exercised here
// rather than described: the driver below mirrors launchFleet().
function attemptRing(order, refusalFor) {
  const tried = [];
  for (const { az } of order) {
    tried.push(az);
    const err = refusalFor(az);
    if (!err) return { tried, launchedIn: az };
    if (!shouldTryNextAz(err)) return { tried, launchedIn: null, stoppedOn: err };
  }
  return { tried, launchedIn: null, exhausted: true };
}

describe('the AZ ring — a capacity refusal advances, a config refusal stops', () => {
  it('walks past the dry pools and lands in the first one with capacity', () => {
    const order = azOrder(0);
    const dry = new Set(order.slice(0, 2).map((s) => s.az));
    const r = attemptRing(order, (az) => (dry.has(az) ? NO_CAPACITY_HERE : null));
    expect(r.tried).toHaveLength(3);
    expect(r.launchedIn).toBe(order[2].az);
  });

  it('tries ALL FOUR before giving up when the whole region is dry — then, and only then, pay', () => {
    const r = attemptRing(azOrder(2), () => NO_CAPACITY_HERE);
    expect(r.tried).toHaveLength(4);
    expect(new Set(r.tried).size).toBe(4);          // four DIFFERENT pools, not one tried four times
    expect(r.exhausted).toBe(true);
    expect(shouldFallbackToOnDemand(NO_CAPACITY_HERE)).toBe(true);   // …and only now is on-demand right
  });

  it('STOPS AT THE FIRST AZ on a non-capacity failure — one error, not four', () => {
    for (const err of [UNAUTHORIZED, NO_TEMPLATE, BAD_NET, SPOT_QUOTA]) {
      const r = attemptRing(azOrder(0), () => err);
      expect(r.tried).toHaveLength(1);
      expect(r.stoppedOn).toBe(err);
    }
  });

  it('does not retry an AZ that already refused within the same pass', () => {
    const seen = [];
    attemptRing(azOrder(3), (az) => { seen.push(az); return NO_CAPACITY_HERE; });
    expect(new Set(seen).size).toBe(seen.length);
  });
});

describe('templateNetMode — may this launch name a subnet at all?', () => {
  it('reads the LIVE template as pinned — it still carries a NetworkInterfaces block', () => {
    expect(templateNetMode(LIVE_PINNED)).toBe('pinned');
  });

  it('reads the restructured template as multi-az', () => {
    expect(templateNetMode(RESTRUCTURED)).toBe('multi-az');
  });

  it('treats an unreadable template as PINNED — fail safe, never fail open', () => {
    // A describe that failed, a shape from a future API version, a scalar where an object was
    // expected: all mean "we do not know". Guessing multi-az there sends --subnet-id at a template
    // that may still refuse it, and that refusal is 100% of launches. Guessing pinned costs the
    // fan-out and nothing else.
    for (const d of [undefined, null, '', 0, [], 'pinned', 7]) {
      expect(() => templateNetMode(d)).not.toThrow();
      expect(templateNetMode(d)).toBe('pinned');
    }
  });

  it('is pinned even when the block names no subnet — the BLOCK is what makes --subnet-id illegal', () => {
    // The API refuses the combination on the PRESENCE of an interface spec, not on whether it
    // happens to carry a SubnetId.
    expect(templateNetMode({ NetworkInterfaces: [{ DeviceIndex: 0, Groups: [SG] }] })).toBe('pinned');
  });

  it('an EMPTY NetworkInterfaces list is multi-az — there is no interface spec to conflict with', () => {
    // Deliberate, and the one place "no block" is spelled differently: an empty list means the
    // request specifies no interface, so a plain --subnet-id is legal.
    expect(templateNetMode({ NetworkInterfaces: [] })).toBe('multi-az');
  });
});

describe('runInstancesArgs — name a subnet only when the template can accept one', () => {
  const base = {
    template: 'pocketdj-stem-worker', count: 4, market: 'spot',
    subnetId: MEASURED['us-west-2d'], netMode: 'multi-az',
  };

  it('passes --subnet-id once the template has been restructured', () => {
    for (const { subnetId } of SUBNETS) {
      const args = runInstancesArgs({ ...base, subnetId });
      expect(args).toContain('--subnet-id');
      expect(args[args.indexOf('--subnet-id') + 1]).toBe(subnetId);
    }
  });

  it('NEVER passes --subnet-id while the template is still PINNED — that is the outage', () => {
    // `InvalidParameterCombination` fails 100% of launches in every AZ, immediately, and is in
    // neither the next-AZ set nor the on-demand fallback set — so the queue just stops, with a line
    // in a log file nobody is reading. Costing the fan-out is the cheap direction to be wrong in.
    for (const market of ['spot', 'on-demand']) {
      for (const netMode of ['pinned', undefined, null, 'unknown']) {
        const args = runInstancesArgs({ ...base, market, netMode });
        expect(args).not.toContain('--subnet-id');
        for (const { subnetId } of SUBNETS) expect(args).not.toContain(subnetId);
      }
    }
  });

  it('does not fabricate a subnet when none was chosen', () => {
    expect(runInstancesArgs({ ...base, subnetId: undefined })).not.toContain('--subnet-id');
    expect(runInstancesArgs({ ...base, subnetId: null })).not.toContain('--subnet-id');
  });

  it('does NOT hand-roll --network-interfaces — the template owns the network config', () => {
    // The rejected alternative. Overriding the whole block per launch means restating DeviceIndex,
    // Groups, AssociatePublicIpAddress and DeleteOnTermination in the autoscaler forever, and every
    // future template edit to the ENI block would be silently ignored.
    for (const netMode of ['multi-az', 'pinned']) {
      expect(runInstancesArgs({ ...base, netMode })).not.toContain('--network-interfaces');
    }
  });

  it('still launches from the template at $Latest, and still uses --count 1:n', () => {
    // `--count 1:n` is why partial capacity fills what it can instead of failing the pass; it matters
    // doubly on spot, and doubly again now that each AZ is a separate attempt.
    const args = runInstancesArgs(base);
    expect(args.join(' ')).toContain('LaunchTemplateName=pocketdj-stem-worker,Version=$Latest');
    expect(args).toContain('1:4');
  });

  it('asks for spot ONLY when the market is spot', () => {
    const spot = runInstancesArgs({ ...base, market: 'spot' }).join(' ');
    expect(spot).toContain('--instance-market-options');
    expect(spot).toContain('"MarketType":"spot"');
    expect(spot).toContain('"SpotInstanceType":"one-time"');   // NOT persistent: it would fight scale-to-zero
    expect(runInstancesArgs({ ...base, market: 'on-demand' })).not.toContain('--instance-market-options');
  });

  it('sets no MaxPrice — an unset maximum bids the on-demand price and never starves the fleet', () => {
    // A hardcoded ceiling is the classic way to wedge a spot fleet: the day the price crosses it,
    // every launch is refused, the queue backs up, and nothing in the logs says "you set a limit".
    expect(runInstancesArgs(base).join(' ')).not.toContain('MaxPrice');
  });

  it('still asks for just the instance ids, in the shape the caller splits on', () => {
    const args = runInstancesArgs(base);
    expect(args).toContain('Instances[].InstanceId');
    expect(args).toContain('text');
  });

  it('is pure — building the args twice gives the same argv', () => {
    expect(runInstancesArgs(base)).toEqual(runInstancesArgs(base));
  });
});
