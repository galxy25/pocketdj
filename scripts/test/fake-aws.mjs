#!/usr/bin/env node
// Test fixture: a stand-in for the real `aws` CLI so the rip-server e2e can run with a
// FULLY DETERMINISTIC manifest and zero network / real S3 writes. Put on PATH ahead of
// the real aws via a shim dir (see rip-collection-e2e.mjs). It only handles the two
// shapes the server uses:
//   aws s3 cp s3://<bucket>/rips/manifest.json -   → loadManifest: print a seeded manifest
//   aws s3 cp <anything> <anything>                → saveManifest / uploads: succeed, no-op
// The seed manifest is supplied via FAKE_AWS_MANIFEST (a path to a JSON file); when unset
// or missing it prints {} (empty manifest, same as a cold cache).
//
// SQS SPOOL (opt-in via FAKE_AWS_SQS_DIR): without it every `aws sqs …` call "succeeded
// silently", so a test could not SEE what the server enqueued — the bounded dispatcher's
// message bodies were invisible and no test could assert them. With the dir set:
//   send-message     → append the body as one line to <dir>/<queue-name>.ndjson
//   receive-message  → pop up to N lines from <dir>/<queue-name>.inbox.ndjson as SQS Messages
//   delete-message   → record the receipt handle in <dir>/<queue-name>.deleted.ndjson
//   get-queue-attributes → report the spooled depth
import { existsSync, readFileSync, appendFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
// strip the trailing --profile/--region the server always appends
const args = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--profile' || argv[i] === '--region') { i++; continue; }
  args.push(argv[i]);
}

// ---- SQS spool ----
const SQS_DIR = process.env.FAKE_AWS_SQS_DIR || null;
const qname = (url) => String(url || '').split('/').pop() || 'unknown';
const flagVal = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
if (SQS_DIR && args[0] === 'sqs') {
  mkdirSync(SQS_DIR, { recursive: true });
  const q = qname(flagVal('--queue-url'));
  if (args[1] === 'send-message') {
    appendFileSync(join(SQS_DIR, `${q}.ndjson`), (flagVal('--message-body') || '') + '\n');
    process.stdout.write(JSON.stringify({ MessageId: `m${Date.now()}` }));
    process.exit(0);
  }
  if (args[1] === 'receive-message') {
    const inbox = join(SQS_DIR, `${q}.inbox.ndjson`);
    const lines = existsSync(inbox) ? readFileSync(inbox, 'utf8').split('\n').filter((l) => l.trim()) : [];
    const n = Number(flagVal('--max-number-of-messages') || 1);
    const take = lines.slice(0, n);
    writeFileSync(inbox, lines.slice(take.length).join('\n') + (lines.length > take.length ? '\n' : ''));
    process.stdout.write(JSON.stringify(take.length
      ? { Messages: take.map((Body, i) => ({ Body, ReceiptHandle: `rh-${Date.now()}-${i}` })) } : {}));
    process.exit(0);
  }
  if (args[1] === 'delete-message') {
    appendFileSync(join(SQS_DIR, `${q}.deleted.ndjson`), (flagVal('--receipt-handle') || '') + '\n');
    process.exit(0);
  }
  if (args[1] === 'get-queue-attributes') {
    const f = join(SQS_DIR, `${q}.ndjson`);
    const n = existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter((l) => l.trim()).length : 0;
    process.stdout.write(JSON.stringify({ Attributes: { ApproximateNumberOfMessages: String(n), ApproximateNumberOfMessagesNotVisible: '0' } }));
    process.exit(0);
  }
  process.exit(0);
}

// aws s3 cp <src> <dst>
if (args[0] === 's3' && args[1] === 'cp') {
  const src = args[2];
  const dst = args[3];
  // loadManifest reads the manifest to stdout (dst === '-')
  if (dst === '-' && /\/rips\/manifest\.json$/.test(src || '')) {
    const seed = process.env.FAKE_AWS_MANIFEST;
    if (seed && existsSync(seed)) process.stdout.write(readFileSync(seed, 'utf8'));
    else process.stdout.write('{}');
    process.exit(0);
  }
  // saveManifest uploads the manifest: with FAKE_AWS_MANIFEST set, land it in that same file so
  // load/save round-trip through ONE path and a test can assert that a fold reached DISK — the
  // exact failure this codebase has hit twice (artifact on S3, manifest stamp only in memory).
  if (/\/rips\/manifest\.json$/.test(dst || '') && process.env.FAKE_AWS_MANIFEST && src && existsSync(src)) {
    writeFileSync(process.env.FAKE_AWS_MANIFEST, readFileSync(src, 'utf8'));
    process.exit(0);
  }
  // every other copy (audio uploads) → succeed silently
  process.exit(0);
}

// any other aws subcommand we don't model → succeed silently (server never relies on it)
process.exit(0);
