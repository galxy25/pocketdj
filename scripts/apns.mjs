// Dependency-free APNs sender (HTTP/2 + ES256 provider-token auth) for the jukebox
// broker's Music with Friends pushes. Zero packages: node:crypto signs the JWT and the
// DER→JOSE conversion is hand-rolled (covered by a known-vector unit test in
// test-mwf-server.mjs — a malformed JWT fails silently as APNs 403s, so the math must
// be provably right).
//
//   env: APNS_KEY_FILE (path to AuthKey_<KEYID>.p8), APNS_KEY_ID, APNS_TEAM_ID,
//        APNS_TOPIC (default 'com.levi.pocketdj'),
//        APNS_ENV ('production' | 'sandbox', default 'production' — TestFlight builds
//        talk to PRODUCTION APNs; Xcode-run debug builds would need 'sandbox').
//
// Graceful degrade: enabled() is false until the key lands on the iMac (manual portal
// step) — every send resolves {ok:false, disabled:true} and members rely on polling.
import { createSign } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import http2 from 'node:http2';

const CFG = {
  keyFile: process.env.APNS_KEY_FILE || '',
  keyId: process.env.APNS_KEY_ID || '',
  teamId: process.env.APNS_TEAM_ID || '',
  topic: process.env.APNS_TOPIC || 'com.levi.pocketdj',
  env: process.env.APNS_ENV === 'sandbox' ? 'sandbox' : 'production',
};

const HOST = CFG.env === 'sandbox' ? 'https://api.sandbox.push.apple.com'
                                   : 'https://api.push.apple.com';

/// True when a usable key is configured (file exists + key id + team id).
export function enabled() {
  return !!(CFG.keyFile && CFG.keyId && CFG.teamId && existsSync(CFG.keyFile));
}

/// Convert a DER-encoded ECDSA signature (SEQUENCE of two INTEGERs) to the raw
/// 64-byte r‖s JOSE form ES256 JWTs require. Exported for the known-vector unit test.
export function derToJose(der) {
  const buf = Buffer.isBuffer(der) ? der : Buffer.from(der);
  if (buf.length < 8 || buf[0] !== 0x30) throw new Error('not a DER ECDSA signature');
  // SEQUENCE length: short form (≤127) or long form (0x81 <len>) — P-256 sigs are ≤72
  // bytes so at most one length byte follows.
  let offset = buf[1] & 0x80 ? 2 + (buf[1] & 0x7f) : 2;
  const readInt = () => {
    if (buf[offset] !== 0x02) throw new Error('expected DER INTEGER');
    const len = buf[offset + 1];
    let start = offset + 2;
    offset = start + len;
    let bytes = buf.subarray(start, start + len);
    // Strip the sign-padding zero, then left-pad back to exactly 32 bytes.
    while (bytes.length > 32 && bytes[0] === 0x00) bytes = bytes.subarray(1);
    if (bytes.length > 32) throw new Error('DER integer longer than 32 bytes');
    return Buffer.concat([Buffer.alloc(32 - bytes.length), bytes]);
  };
  const r = readInt();
  const s = readInt();
  return Buffer.concat([r, s]);
}

const b64url = (s) => Buffer.from(s).toString('base64url');

let cachedJwt = null;
let cachedAtMs = 0;
const JWT_TTL_MS = 50 * 60 * 1000; // APNs accepts tokens up to 60 min old; refresh at 50.

function providerToken() {
  const now = Date.now();
  if (cachedJwt && now - cachedAtMs < JWT_TTL_MS) return cachedJwt;
  const key = readFileSync(CFG.keyFile, 'utf8');
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: CFG.keyId }));
  const claims = b64url(JSON.stringify({ iss: CFG.teamId, iat: Math.floor(now / 1000) }));
  const signer = createSign('SHA256');
  signer.update(`${header}.${claims}`);
  signer.end();
  const der = signer.sign(key);
  const sig = derToJose(der).toString('base64url');
  cachedJwt = `${header}.${claims}.${sig}`;
  cachedAtMs = now;
  return cachedJwt;
}

/// Send one alert push. Resolves {ok:true} | {gone:true} (410/BadDeviceToken — the
/// caller clears the stored token) | {ok:false, ...} on any other failure. One
/// short-lived HTTP/2 connection per send — fine at party volume.
export async function send(deviceToken, payload, { collapseId, pushType = 'alert' } = {}) {
  if (!enabled()) return { ok: false, disabled: true };
  let jwt;
  try { jwt = providerToken(); } catch (e) { return { ok: false, error: `jwt: ${e.message}` }; }
  return new Promise((resolve) => {
    const client = http2.connect(HOST);
    const finish = (out) => { try { client.close(); } catch { /* already closed */ } resolve(out); };
    client.on('error', (e) => finish({ ok: false, error: e.message }));
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      'authorization': `bearer ${jwt}`,
      'apns-topic': CFG.topic,
      'apns-push-type': pushType,
    };
    if (collapseId) headers['apns-collapse-id'] = collapseId;
    const req = client.request(headers);
    let status = 0;
    let body = '';
    req.on('response', (h) => { status = h[':status'] || 0; });
    req.setEncoding('utf8');
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      if (status === 200) return finish({ ok: true });
      let reason = '';
      try { reason = JSON.parse(body).reason || ''; } catch { /* non-json */ }
      if (status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered') {
        return finish({ gone: true });
      }
      finish({ ok: false, status, error: reason || body || `http ${status}` });
    });
    req.on('error', (e) => finish({ ok: false, error: e.message }));
    req.end(JSON.stringify(payload));
  });
}
