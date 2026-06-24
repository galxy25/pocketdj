#!/usr/bin/env node
// Test fixture: a stand-in for the real `aws` CLI so the rip-server e2e can run with a
// FULLY DETERMINISTIC manifest and zero network / real S3 writes. Put on PATH ahead of
// the real aws via a shim dir (see rip-collection-e2e.mjs). It only handles the two
// shapes the server uses:
//   aws s3 cp s3://<bucket>/rips/manifest.json -   → loadManifest: print a seeded manifest
//   aws s3 cp <anything> <anything>                → saveManifest / uploads: succeed, no-op
// The seed manifest is supplied via FAKE_AWS_MANIFEST (a path to a JSON file); when unset
// or missing it prints {} (empty manifest, same as a cold cache).
import { existsSync, readFileSync } from 'node:fs';

const argv = process.argv.slice(2);
// strip the trailing --profile/--region the server always appends
const args = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--profile' || argv[i] === '--region') { i++; continue; }
  args.push(argv[i]);
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
  // every other copy (saveManifest upload, audio uploads) → succeed silently
  process.exit(0);
}

// any other aws subcommand we don't model → succeed silently (server never relies on it)
process.exit(0);
