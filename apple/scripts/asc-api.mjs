// asc-api.mjs — minimal App Store Connect API client (no deps; node >= 18).
// Usage:
//   node asc-api.mjs GET /v1/apps
//   node asc-api.mjs POST /v1/certificates '<json-body>'
import { readFileSync } from 'node:fs';
import { createSign, createPrivateKey } from 'node:crypto';
import { homedir } from 'node:os';

const KEY_ID = process.env.ASC_KEY_ID || 'C2G2V625FZ';
const ISSUER = process.env.ASC_ISSUER_ID || '69a6de86-a921-47e3-e053-5b8c7c11a4d1';
const P8 = process.env.ASC_KEY_PATH || `${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;

const b64url = (buf) => Buffer.from(buf).toString('base64url');
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  const key = createPrivateKey(readFileSync(P8, 'utf8'));
  const sign = createSign('SHA256');
  sign.update(`${header}.${payload}`);
  const sig = sign.sign({ key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${payload}.${b64url(sig)}`;
}

const [method, path, body] = process.argv.slice(2);
const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
  method,
  headers: {
    Authorization: `Bearer ${jwt()}`,
    'Content-Type': 'application/json',
  },
  body: body || undefined,
});
const text = await res.text();
if (!res.ok) {
  console.error(`HTTP ${res.status}`);
  console.error(text);
  process.exit(1);
}
console.log(text);
