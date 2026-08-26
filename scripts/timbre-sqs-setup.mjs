#!/usr/bin/env node
// Idempotent SQS setup for the CLOUD TIMBRE lane. Mirrors scripts/stem-sqs-setup.mjs exactly —
// same three-queue shape, same redrive policy — but on its OWN queues:
//   pocketdj-timbre-jobs-dlq   dead-letter queue for poison batches
//   pocketdj-timbre-jobs       jobs queue: redrive to DLQ after 3 receives; 1800s visibility
//                              (a 50-song warm batch is ~4 min of compute — enormous margin)
//   pocketdj-timbre-results    workers post {batchId, songs:[…]}; rip-server folds the stamps
//
// WHY SEPARATE QUEUES AND NOT tasks:['timbre'] ON pocketdj-stem-jobs — the decisive reason:
// the stem fleet is x86_64 m7i and cannot run the arm64 pocketdj-audio image at all. Worse, a
// timbre job landing on the stem queue would be CLAIMED by a stem worker, fall through
// processJob with no matching branch, post an empty {ok:true} result and DELETE the message.
// The job vanishes, the DLQ stays empty, and nothing looks wrong. A shared queue with two
// heterogeneous fleets is unsafe by construction. Everything else — the bounded dispatcher, the
// results pump, the DLQ drain, the autoscaler — is REUSED rather than reinvented.
//
// Prints the queue URLs. Run once: node scripts/timbre-sqs-setup.mjs
import { execFileSync } from 'node:child_process';
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const aws = (...a) => execFileSync('aws', [...a, '--region', REGION, '--profile', PROFILE], { encoding: 'utf8' }).trim();
const createQueue = (name, attrs) => JSON.parse(aws('sqs', 'create-queue', '--queue-name', name,
  ...(attrs ? ['--attributes', JSON.stringify(attrs)] : []), '--output', 'json')).QueueUrl;
const arnOf = (url) => JSON.parse(aws('sqs', 'get-queue-attributes', '--queue-url', url,
  '--attribute-names', 'QueueArn', '--output', 'json')).Attributes.QueueArn;

const dlqUrl = createQueue('pocketdj-timbre-jobs-dlq');
const jobsUrl = createQueue('pocketdj-timbre-jobs', {
  VisibilityTimeout: '1800',
  RedrivePolicy: JSON.stringify({ deadLetterTargetArn: arnOf(dlqUrl), maxReceiveCount: '3' }),
});
// 14-day retention (vs the 4-day default) on the RESULTS queue: results carry the manifest
// stamps, and the rip server is the only consumer. A backfill run while the server is on an
// older build — or simply down for a long weekend — must not lose its stamps to queue expiry.
// The S3 sidecars are the source of truth either way, but re-deriving stamps costs a fleet run.
const resultsUrl = createQueue('pocketdj-timbre-results', { MessageRetentionPeriod: '1209600' });
console.log(JSON.stringify({ jobsUrl, resultsUrl, dlqUrl, jobsArn: arnOf(jobsUrl), resultsArn: arnOf(resultsUrl), dlqArn: arnOf(dlqUrl) }, null, 2));
