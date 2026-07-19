#!/usr/bin/env node
// Idempotent SQS setup for the stem-offload queue. Creates:
//   pocketdj-stem-jobs-dlq   dead-letter queue for poison jobs
//   pocketdj-stem-jobs       jobs queue: redrive to DLQ after 3 receives; 1800s visibility (≥ the
//                            rip-server 30m stem deadline) so a slow CPU separation isn't redelivered
//   pocketdj-stem-results    workers post {songId, stems, …}; rip-server folds into manifest.json
// Prints the queue URLs. Run once: node scripts/stem-sqs-setup.mjs
import { execFileSync } from 'node:child_process';
const REGION = process.env.AWS_REGION || 'us-west-2';
const aws = (...a) => execFileSync('aws', [...a, '--region', REGION], { encoding: 'utf8' }).trim();
const createQueue = (name, attrs) => JSON.parse(aws('sqs', 'create-queue', '--queue-name', name,
  ...(attrs ? ['--attributes', JSON.stringify(attrs)] : []), '--output', 'json')).QueueUrl;
const arnOf = (url) => JSON.parse(aws('sqs', 'get-queue-attributes', '--queue-url', url,
  '--attribute-names', 'QueueArn', '--output', 'json')).Attributes.QueueArn;

const dlqUrl = createQueue('pocketdj-stem-jobs-dlq');
const jobsUrl = createQueue('pocketdj-stem-jobs', {
  VisibilityTimeout: '1800',
  RedrivePolicy: JSON.stringify({ deadLetterTargetArn: arnOf(dlqUrl), maxReceiveCount: '3' }),
});
const resultsUrl = createQueue('pocketdj-stem-results');
console.log(JSON.stringify({ jobsUrl, resultsUrl, dlqUrl }, null, 2));
