// Validate a remote endpoint config doc with the SAME rules the clients apply
// (src/config/endpointSchema.ts). deploy.sh runs this before publishing so we never ship a
// document every client would silently reject.
//
//   npx tsx scripts/validate-endpoints.ts config/endpoints.blue.json
import { readFileSync } from 'node:fs';
import { validateEndpointDoc } from '../src/config/endpointSchema';

const file = process.argv[2];
if (!file) {
  console.error('usage: tsx scripts/validate-endpoints.ts <config/endpoints.<env>.json>');
  process.exit(2);
}
let raw: unknown;
try {
  raw = JSON.parse(readFileSync(file, 'utf8'));
} catch (e) {
  console.error(`✗ ${file}: not valid JSON (${(e as Error).message})`);
  process.exit(1);
}
const v = validateEndpointDoc(raw);
if (!v.ok) {
  console.error(`✗ ${file}: REJECTED — ${v.reason}`);
  process.exit(1);
}
console.log(`✓ ${file}: v1 env=${v.config.env}`);
for (const [k, u] of Object.entries(v.config.endpoints)) console.log(`    ${k.padEnd(22)} ${u}`);
console.log(`    ${'capabilities.recEngineEnroll'.padEnd(22)} ${v.config.capabilities?.recEngineEnroll ? '(set, hidden)' : '(absent: compiled constant)'}`);
