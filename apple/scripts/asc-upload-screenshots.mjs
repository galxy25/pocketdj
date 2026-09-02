#!/usr/bin/env node
// asc-upload-screenshots.mjs — upload App Store screenshots for a version localization.
//
//   node asc-upload-screenshots.mjs <localizationId> <displayType> <png...>
//
// displayType: APP_IPHONE_69 | APP_IPAD_PRO_3GEN_129 | ... (App Store Connect enum)
// Creates (or reuses) the appScreenshotSet for the display type, then for each PNG runs the
// three-step dance: POST appScreenshots (reserve) → PUT bytes to the returned uploadOperations
// → PATCH uploaded=true + sourceFileChecksum. Order in the set follows argv order.
import { readFileSync } from 'node:fs';
import { createHash, createSign, createPrivateKey } from 'node:crypto';
import { homedir } from 'node:os';
import { basename } from 'node:path';

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

async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → HTTP ${res.status}\n${text.slice(0, 600)}`);
  return text ? JSON.parse(text) : null;
}

const [locId, displayType, ...files] = process.argv.slice(2);
if (!locId || !displayType || files.length === 0) {
  console.error('usage: asc-upload-screenshots.mjs <localizationId> <displayType> <png...>');
  process.exit(1);
}

// 1. Find or create the screenshot set for this display type.
const sets = await api('GET', `/v1/appStoreVersionLocalizations/${locId}/appScreenshotSets`);
let set = sets.data.find((s) => s.attributes.screenshotDisplayType === displayType);
if (!set) {
  const created = await api('POST', '/v1/appScreenshotSets', {
    data: {
      type: 'appScreenshotSets',
      attributes: { screenshotDisplayType: displayType },
      relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: locId } } },
    },
  });
  set = created.data;
  console.log(`created set ${set.id} (${displayType})`);
} else {
  console.log(`reusing set ${set.id} (${displayType})`);
}

// 2. Per file: reserve → upload → commit.
for (const file of files) {
  const bytes = readFileSync(file);
  const name = basename(file);
  const reserved = await api('POST', '/v1/appScreenshots', {
    data: {
      type: 'appScreenshots',
      attributes: { fileName: name, fileSize: bytes.length },
      relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } },
    },
  });
  const shot = reserved.data;
  for (const op of shot.attributes.uploadOperations) {
    const chunk = bytes.subarray(op.offset, op.offset + op.length);
    const headers = {};
    for (const h of op.requestHeaders || []) headers[h.name] = h.value;
    const up = await fetch(op.url, { method: op.method, headers, body: chunk });
    if (!up.ok) throw new Error(`upload chunk → HTTP ${up.status}`);
  }
  const md5 = createHash('md5').update(bytes).digest('hex');
  await api('PATCH', `/v1/appScreenshots/${shot.id}`, {
    data: {
      type: 'appScreenshots',
      id: shot.id,
      attributes: { uploaded: true, sourceFileChecksum: md5 },
    },
  });
  console.log(`uploaded ${name} (${bytes.length} bytes) → ${shot.id}`);
}
console.log('done');
