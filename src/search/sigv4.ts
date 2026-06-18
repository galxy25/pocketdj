// Minimal AWS SigV4 request signer for the browser (Web Crypto). Used to sign
// OpenSearch Serverless (service "aoss") search requests with the user's read-only
// djpocketsearch IAM key/secret entered in Settings.
//
// We sign with the REAL OpenSearch host (so aoss validates the signature) but the
// app fetches a SAME-ORIGIN proxy path (a CloudFront behavior forwards it to the
// aoss origin, preserving Host) — that sidesteps the lack of CORS on aoss.

export interface SigV4Creds {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

const enc = new TextEncoder();
const toHex = (buf: ArrayBuffer): string =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

async function sha256Hex(data: string): Promise<string> {
  return toHex(await crypto.subtle.digest('SHA-256', enc.encode(data)));
}
async function hmac(key: ArrayBuffer | Uint8Array, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey('raw', key as ArrayBuffer, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return crypto.subtle.sign('HMAC', k, enc.encode(data));
}

/**
 * Sign a request and return the headers to send. `host` is the value aoss will
 * see (the real collection host), `path` is the exact request path aoss receives.
 */
export async function signRequest(opts: {
  method: string;
  host: string;
  path: string;
  body: string;
  region: string;
  service: string; // 'aoss'
  creds: SigV4Creds;
}): Promise<Record<string, string>> {
  const { method, host, path, body, region, service, creds } = opts;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ''); // YYYYMMDDTHHMMSSZ
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = await sha256Hex(body);

  const canonicalHeaders =
    `host:${host}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n` +
    (creds.sessionToken ? `x-amz-security-token:${creds.sessionToken}\n` : '');
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date' + (creds.sessionToken ? ';x-amz-security-token' : '');

  const canonicalUri = path.split('/').map((s) => encodeURIComponent(s)).join('/') || '/';
  const canonicalRequest = [method, canonicalUri, '', canonicalHeaders, signedHeaders, payloadHash].join('\n');

  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest)].join('\n');

  const kDate = await hmac(enc.encode('AWS4' + creds.secretAccessKey), dateStamp);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  const kSigning = await hmac(kService, 'aws4_request');
  const signature = toHex(await hmac(kSigning, stringToSign));

  const headers: Record<string, string> = {
    'x-amz-date': amzDate,
    'x-amz-content-sha256': payloadHash,
    Authorization: `AWS4-HMAC-SHA256 Credential=${creds.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
  if (creds.sessionToken) headers['x-amz-security-token'] = creds.sessionToken;
  return headers;
}
