// PocketDJ online-search proxy (regional Lambda, Function URL origin behind CloudFront).
//
// Why this exists: the app's PWA must reach OpenSearch Serverless from the browser, but
// aoss has no CORS, so the browser fetches a same-origin CloudFront path (/pocketdj/*)
// that forwards to an origin. Forwarding straight to the aoss origin FAILS on NextGen:
// CloudFront injects an `x-amz-cf-id` header the browser can't sign, and NextGen rejects
// it ("x-amz-cf-id header must be signed in SigV4"). This Lambda sits in between and makes
// a CLEAN outbound request to aoss, forwarding ONLY the browser's SigV4 headers — so aoss
// sees exactly what the browser signed and validates it. No re-signing, no creds in the
// Lambda: the browser's djpocketsearch signature still does the auth (invalid sigs → 403
// from aoss, so a public Function URL is safe — it's a dumb, auth-preserving pipe).
//
// Host comes from the AOSS_HOST env var, so a collection swap is a config change (no code
// deploy) — mirrors public/search-config.json.

const AOSS_HOST = process.env.AOSS_HOST; // e.g. mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws

// Only these request headers are part of the browser's SigV4 signature (or needed by aoss).
// Everything else CloudFront/Function-URL adds (host, x-amz-cf-id, via, x-forwarded-*, …)
// is DROPPED so it can't break the signature.
const FORWARD = new Set([
  'authorization',
  'x-amz-date',
  'x-amz-content-sha256',
  'x-amz-security-token',
  'content-type',
]);

export const handler = async (event) => {
  if (!AOSS_HOST) return { statusCode: 500, body: 'AOSS_HOST not configured' };

  const http = event.requestContext?.http ?? {};
  const method = http.method ?? 'POST';
  const rawPath = event.rawPath || '/';
  const qs = event.rawQueryString ? `?${event.rawQueryString}` : '';
  const url = `https://${AOSS_HOST}${rawPath}${qs}`;

  const headers = {};
  for (const [k, v] of Object.entries(event.headers ?? {})) {
    if (FORWARD.has(k.toLowerCase())) headers[k] = v;
  }

  const body =
    event.body == null ? undefined : event.isBase64Encoded ? Buffer.from(event.body, 'base64') : event.body;

  let res, text;
  try {
    res = await fetch(url, { method, headers, body });
    text = await res.text();
  } catch (e) {
    return { statusCode: 502, body: `proxy error: ${String(e).slice(0, 200)}` };
  }

  return {
    statusCode: res.status,
    headers: { 'content-type': res.headers.get('content-type') ?? 'application/json' },
    body: text,
  };
};
