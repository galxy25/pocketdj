#!/usr/bin/env node
// Probe whether a Media Services key can sign ShazamKit developer tokens.
//
// Mints a short-lived token with EXACTLY the header/claims scripts/rip-server.mjs mintMusicKitToken()
// uses ({alg:ES256,kid,typ:JWT} / {iss,iat,exp}) and asks both Apple APIs whether they accept it:
//   - api.music.apple.com   (MusicKit)   GET a catalog song         -> 200 when the key has MusicKit
//   - api.shazam.apple.com  (ShazamKit)  POST /match with an empty body -> 401 = token REJECTED
//                                         (bare 401, identical to no token at all); anything else = past auth
// The token itself is never printed. --out <file> writes it (mode 600) for the instrumented match
// test (android ShazamRealMatchInstrumentedTest); delete it after use.
//
//   node scripts/shazam-token-probe.mjs [--key ~/.config/pocketdj/AuthKey_9JRN4H68X4.p8] [--kid 9JRN4H68X4] [--team EC27UF79GL] [--out file]
import { createPrivateKey, sign } from 'node:crypto';
import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const kid = arg('kid', process.env.MUSICKIT_KID || '9JRN4H68X4');
const team = arg('team', process.env.MUSICKIT_TEAM || 'EC27UF79GL');
const keyPath = arg('key', process.env.MUSICKIT_P8 || `${homedir()}/.config/pocketdj/AuthKey_${kid}.p8`).replace(/^~/, homedir());
const out = arg('out');

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const now = Math.floor(Date.now() / 1000);
const header = { alg: 'ES256', kid, typ: 'JWT' };
const claims = { iss: team, iat: now, exp: now + 3600 };
const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(readFileSync(keyPath)), dsaEncoding: 'ieee-p1363' });
const token = `${input}.${b64url(sig)}`;

const auth = { Authorization: `Bearer ${token}` };
const am = await fetch('https://api.music.apple.com/v1/catalog/us/songs/203709340', { headers: auth });
const sz = await fetch('https://api.shazam.apple.com/v1/catalog/us/match?types=shazam-songs', {
  method: 'POST', headers: { ...auth, 'Content-Type': 'application/json; charset=utf-8' }, body: '{}',
});
console.log(`header ${JSON.stringify(header)} claims ${JSON.stringify(claims)}`);
console.log(`MusicKit  api.music.apple.com   -> ${am.status} ${am.status === 200 ? 'accepted' : 'REJECTED'}`);
console.log(`ShazamKit api.shazam.apple.com  -> ${sz.status} ${sz.status === 401 ? 'REJECTED (key/Media ID not provisioned for ShazamKit)' : 'accepted'}`);
// mode only applies on create: chmod too so a pre-existing file is not left world-readable.
if (out) { writeFileSync(out, token, { mode: 0o600 }); chmodSync(out, 0o600); console.log(`token written to ${out} (delete after use)`); }
process.exit(sz.status === 401 ? 1 : 0);
