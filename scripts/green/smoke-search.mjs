// Signed search through a proxy URL, exactly like the app: the request is SigV4-signed for the AOSS
// host (service aoss) with the read-only djpocketsearch key, then SENT to the proxy (API Gateway or
// CloudFront /pocketdj/*), which forwards only the signature headers.
//   AK=… SK=… node scripts/green/smoke-search.mjs <aossHost> <proxyBase> [query]
// Credentials come from the environment (never argv, never printed).
import { createHash, createHmac } from 'node:crypto';

const [aossHost, proxyBase, q = 'love'] = process.argv.slice(2);
const creds = { akid: process.env.AK, secret: process.env.SK };
if (!aossHost || !proxyBase || !creds.akid || !creds.secret) { console.error('usage: AK= SK= node smoke-search.mjs <aossHost> <proxyBase> [q]'); process.exit(2); }
const sha = (s) => createHash('sha256').update(s).digest('hex');
const hmac = (k, s) => createHmac('sha256', k).update(s).digest();
const region = 'us-west-2', service = 'aoss', path = '/pocketdj/_search';
const body = JSON.stringify({ size: 3, query: { multi_match: { query: q, fields: ['title', 'artist', 'album'] } } });
const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ''); const day = amzDate.slice(0, 8);
const ph = sha(body);
const signed = 'host;x-amz-content-sha256;x-amz-date';
const creq = ['POST', path, '', `host:${aossHost}\nx-amz-content-sha256:${ph}\nx-amz-date:${amzDate}\n`, signed, ph].join('\n');
const scope = `${day}/${region}/${service}/aws4_request`;
const sts = ['AWS4-HMAC-SHA256', amzDate, scope, sha(creq)].join('\n');
const kS = hmac(hmac(hmac(hmac('AWS4' + creds.secret, day), region), service), 'aws4_request');
const sig = createHmac('sha256', kS).update(sts).digest('hex');
const res = await fetch(proxyBase.replace(/\/$/, '') + path, {
  method: 'POST', body,
  headers: { 'content-type': 'application/json', 'x-amz-date': amzDate, 'x-amz-content-sha256': ph,
    authorization: `AWS4-HMAC-SHA256 Credential=${creds.akid}/${scope}, SignedHeaders=${signed}, Signature=${sig}` },
});
const text = await res.text();
let hits = null; try { const j = JSON.parse(text); hits = { total: j.hits?.total?.value, first: j.hits?.hits?.map((h) => h._source?.title) }; } catch { /* not json */ }
console.log(JSON.stringify({ status: res.status, hits: hits ?? text.slice(0, 200) }));
process.exit(res.status === 200 ? 0 : 1);
