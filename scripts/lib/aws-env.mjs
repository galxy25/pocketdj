// Single source of truth for PocketDJ's AWS coordinates (account, region, CLI profile, bucket
// names, CloudFront ids, API bases, queues, search host) per deployment ("env").
//
//   POCKETDJ_ENV=blue  (default) — the original stack in 011183829623 (profile `levi`).
//   POCKETDJ_ENV=green           — the standalone copy in 623170744161 (profile `llc`).
//
// Defaults are BLUE so every script behaves exactly as before unless POCKETDJ_ENV=green is set.
// Per-script env overrides (AWS_PROFILE, RIP_BUCKET, CF_ID_DEV, POCKETDJ_*_QUEUE, …) still win
// over these values — this module only replaces the hardcoded fallbacks.
//
// Shell scripts read the same data from scripts/lib/aws-env.sh, which is GENERATED from this
// file (`node scripts/lib/aws-env.mjs --emit-sh > scripts/lib/aws-env.sh`) so it needs no node
// at runtime. tests/unit/aws-env.test.mjs fails if the two drift.
//
// CLI:
//   node scripts/lib/aws-env.mjs --json            # selected env as JSON
//   node scripts/lib/aws-env.mjs --get buckets.rips # one value
//   node scripts/lib/aws-env.mjs --emit-sh         # regenerate aws-env.sh

const REGION = 'us-west-2';

function buckets(acct) {
  const b = (n) => `pocketdj-${n}-${acct}`;
  return {
    amSyncJobs: b('am-sync-jobs'), devWeb: b('dev-web'), legalSite: b('legal-site'), logs: b('logs'),
    mail: b('mail'), prodWeb: b('prod-web'), rec: b('rec'), rips: b('rips'), www: b('www'),
  };
}

function queues(acct, region) {
  const q = (n) => `https://sqs.${region}.amazonaws.com/${acct}/${n}`;
  return {
    stemJobs: q('pocketdj-stem-jobs'), stemResults: q('pocketdj-stem-results'), stemDlq: q('pocketdj-stem-jobs-dlq'),
    timbreJobs: q('pocketdj-timbre-jobs'), timbreResults: q('pocketdj-timbre-results'), timbreDlq: q('pocketdj-timbre-jobs-dlq'),
  };
}

function build({ name, account, profile, adminUser, cloudfront, aossHost, apis }) {
  const region = REGION;
  const bk = buckets(account);
  const cdn = Object.fromEntries(Object.entries(cloudfront).map(([k, v]) => [k, v.domain ? `https://${v.domain}` : null]));
  return {
    name, account, region, profile,
    adminArn: `arn:aws:iam::${account}:user/${adminUser}`,
    buckets: bk,
    ripsPublicBase: `https://${bk.rips}.s3.${region}.amazonaws.com`,
    workerCodeBase: `s3://${bk.rips}/worker-code`,
    cloudfront, cdn,
    aossHost, aossCollection: 'pocketdj-search',
    api: apis,
    sqsBase: `https://sqs.${region}.amazonaws.com/${account}`,
    queues: queues(account, region),
    stemJobsArn: `arn:aws:sqs:${region}:${account}:pocketdj-stem-jobs`,
  };
}

export const ENVS = {
  blue: build({
    name: 'blue', account: '011183829623', profile: 'levi', adminUser: 'Developer',
    cloudfront: {
      dev: { id: 'E123GKAO9JVETP', domain: 'djictbz9w796r.cloudfront.net', alias: 'dev.app.pocket-dj.com' },
      prod: { id: 'E1SP8M1SIF7Q8D', domain: 'd2p4cubg6se03u.cloudfront.net', alias: 'app.pocket-dj.com' },
      legal: { id: 'E9XDXX3A506H6', domain: 'd7hqmfs8guzv3.cloudfront.net', alias: 'legal.pocket-dj.com' },
      www: { id: 'E9L9V188S55F7', domain: 'd20r2rqpcnebjm.cloudfront.net', alias: 'www.pocket-dj.com' },
      jukebox: { id: 'E1XIWBBPFOJ07E', domain: 'd3jlgkneh3xj10.cloudfront.net', alias: 'jukebox.pocket-dj.com' },
    },
    aossHost: 'mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws',
    apis: {
      search: 'https://fnlg100ir5.execute-api.us-west-2.amazonaws.com',
      recEngine: 'https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com',
      amPlaylistSync: 'https://ynwdaa8vh2.execute-api.us-west-2.amazonaws.com',
    },
  }),
  // GREEN values are written by scripts/green/provision.sh (see docs/aws-green-cutover.md).
  green: build({
    name: 'green', account: '623170744161', profile: 'llc', adminUser: 'levi',
    cloudfront: {
      dev: { id: 'E2O4IE7VGLBNQ5', domain: 'd1zb3ydtksjw1r.cloudfront.net', alias: 'dev.app.pocket-dj.com' },
      prod: { id: 'E2CHNQT5S5WLU3', domain: 'd1j6qufkowz1xq.cloudfront.net', alias: 'app.pocket-dj.com' },
      legal: { id: 'E2B0F6795P6Z6S', domain: 'd1ucyuf4465q66.cloudfront.net', alias: 'legal.pocket-dj.com' },
      www: { id: 'ELX7JB4JIT29F', domain: 'd3cxthv1ih70b5.cloudfront.net', alias: 'www.pocket-dj.com' },
      jukebox: { id: 'EKSX6E9IZE4PW', domain: 'd1igcuqw3ey3p0.cloudfront.net', alias: 'jukebox.pocket-dj.com' },
    },
    aossHost: 'l4srqmhutoh0wlko9y55.aoss.us-west-2.on.aws',
    apis: {
      search: 'https://zoj32t7rh6.execute-api.us-west-2.amazonaws.com',
      recEngine: 'https://kwgk9osywa.execute-api.us-west-2.amazonaws.com',
      amPlaylistSync: 'https://webhj3e832.execute-api.us-west-2.amazonaws.com',
    },
  }),
};

export function envName(env = process.env) {
  const n = (env.POCKETDJ_ENV || 'blue').trim().toLowerCase();
  if (!ENVS[n]) throw new Error(`POCKETDJ_ENV=${n}: expected one of ${Object.keys(ENVS).join(', ')}`);
  return n;
}

/** The selected env's coordinates (POCKETDJ_ENV, default blue). */
export function awsEnv(env = process.env) { return ENVS[envName(env)]; }

export const AWS_ENV = awsEnv();

// ---- shell emission ------------------------------------------------------------------------
// Flat PDJ_* names; shell scripts use them ONLY as fallbacks, e.g. "${AWS_PROFILE:-$PDJ_PROFILE}".
export function shellVars(e) {
  return {
    PDJ_ENV: e.name, PDJ_ACCOUNT: e.account, PDJ_REGION: e.region, PDJ_PROFILE: e.profile,
    PDJ_ADMIN_ARN: e.adminArn,
    PDJ_AM_SYNC_JOBS_BUCKET: e.buckets.amSyncJobs, PDJ_DEV_WEB_BUCKET: e.buckets.devWeb,
    PDJ_LEGAL_BUCKET: e.buckets.legalSite, PDJ_LOGS_BUCKET: e.buckets.logs, PDJ_MAIL_BUCKET: e.buckets.mail,
    PDJ_PROD_WEB_BUCKET: e.buckets.prodWeb, PDJ_REC_BUCKET: e.buckets.rec, PDJ_RIPS_BUCKET: e.buckets.rips,
    PDJ_WWW_BUCKET: e.buckets.www,
    PDJ_RIPS_PUBLIC_BASE: e.ripsPublicBase, PDJ_WORKER_CODE_BASE: e.workerCodeBase,
    PDJ_CF_DEV: e.cloudfront.dev.id, PDJ_CF_PROD: e.cloudfront.prod.id, PDJ_CF_LEGAL: e.cloudfront.legal.id,
    PDJ_CF_WWW: e.cloudfront.www.id, PDJ_CF_JUKEBOX: e.cloudfront.jukebox.id,
    PDJ_CDN_PROD: e.cdn.prod, PDJ_CDN_DEV: e.cdn.dev,
    PDJ_AOSS_HOST: e.aossHost,
    PDJ_API_SEARCH: e.api.search, PDJ_API_REC_ENGINE: e.api.recEngine, PDJ_API_AM_PLAYLIST_SYNC: e.api.amPlaylistSync,
    PDJ_SQS_BASE: e.sqsBase,
    PDJ_STEM_JOBS_QUEUE: e.queues.stemJobs, PDJ_STEM_RESULTS_QUEUE: e.queues.stemResults, PDJ_STEM_DLQ_QUEUE: e.queues.stemDlq,
    PDJ_TIMBRE_JOBS_QUEUE: e.queues.timbreJobs, PDJ_TIMBRE_RESULTS_QUEUE: e.queues.timbreResults,
    PDJ_TIMBRE_DLQ_QUEUE: e.queues.timbreDlq,
  };
}

export function emitSh() {
  const lines = [
    '# GENERATED by `node scripts/lib/aws-env.mjs --emit-sh > scripts/lib/aws-env.sh` — do not edit.',
    '# Source it:  . "$(dirname "$0")/lib/aws-env.sh"   (bash/zsh; no node needed at runtime)',
    '# Selects POCKETDJ_ENV (blue|green, default blue) and sets PDJ_* fallbacks. It never sets',
    '# AWS_PROFILE or any other variable a script already honours, so explicit overrides still win.',
    'case "${POCKETDJ_ENV:-blue}" in',
  ];
  for (const [n, e] of Object.entries(ENVS)) {
    lines.push(`  ${n})`);
    for (const [k, v] of Object.entries(shellVars(e))) lines.push(`    ${k}='${v}'`);
    lines.push('    ;;');
  }
  lines.push('  *) echo "aws-env.sh: unknown POCKETDJ_ENV=${POCKETDJ_ENV}" >&2; return 1 2>/dev/null || exit 1 ;;');
  lines.push('esac');
  lines.push(`export ${Object.keys(shellVars(ENVS.blue)).join(' ')}`);
  return lines.join('\n') + '\n';
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const a = process.argv.slice(2);
  if (a[0] === '--emit-sh') process.stdout.write(emitSh());
  else if (a[0] === '--get') {
    const v = a[1].split('.').reduce((o, k) => (o == null ? o : o[k]), AWS_ENV);
    if (v == null) { console.error(`aws-env: no value for ${a[1]}`); process.exit(1); }
    process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  } else process.stdout.write(JSON.stringify(AWS_ENV, null, 2) + '\n');
}
