# PocketDJ AWS cutover: blue (011183829623) → green (623170744161)

Status 2026-10-12: green is provisioned, populated and smoke-tested on its raw endpoints. **Nothing
in blue has changed** (the blue side was only read: config snapshot, secret values piped to green,
S3 copy source). Blue still serves all traffic; `pocket-dj.com` still delegates to blue's zone.

Background and the hardcoded-endpoint problem: [aws-migration-plan.md](aws-migration-plan.md).

| | blue (live) | green (standby) |
|---|---|---|
| Account | 011183829623 (nonprofit, shared) | 623170744161 (African Intellect Enterprises LLC) |
| CLI profile | `levi` (user Developer) | `llc` (user levi) — never `llc-projects` |
| Select in scripts | `POCKETDJ_ENV=blue` (default) | `POCKETDJ_ENV=green` |

Single source of truth for every coordinate: `scripts/lib/aws-env.mjs` (JS) and the generated
`scripts/lib/aws-env.sh` (bash). Machine-readable client map: `config/endpoints.green.json`
(same schema as `config/endpoints.blue.json` on `feat/remote-endpoints`; validated with
`npx tsx scripts/validate-endpoints.ts`).

## Tooling (scripts/green/)

| Script | What |
|---|---|
| `snapshot-blue.sh` | READ-ONLY dump of blue's config into `blue-snapshot/` (secret values masked). |
| `provision.sh [phase…]` | Idempotent builder; phases `s3 iam sqs secrets aoss lambda apis events cf s3-policies r53 acm ses ec2 web-config worker-code`, or `all`. `GRANT=1` adds the temporary blue→green copy grant to every green bucket policy; running `s3-policies` without it removes the grant. |
| `data-sync.sh [bucket…]` | Server-side `aws s3 sync` blue→green as blue's Developer user, then compares object count + bytes. `SYNC_DELETE=1` mirrors deletions (cutover re-sync). |
| `verify-dns.sh` | Queries every blue record at blue's NS and all 4 green NS; table + exit 1 on mismatch. |
| `smoke.sh [cf search rec pockets amsync sqs ec2 ses]` | Raw-endpoint smoke tests (24 checks). |
| `lambda-snapshot/` | The exact zips deployed in blue (CodeSha256 identical in green). Note: repo `scripts/lambda/rec-engine/index.mjs` is NEWER than what blue runs; green mirrors blue. |
| `state/` | Green ids written by provision (no secrets). |

## Endpoint map blue → green

| Resource | blue | green |
|---|---|---|
| CloudFront dev (dev.app.pocket-dj.com) | E123GKAO9JVETP `djictbz9w796r.cloudfront.net` | E2O4IE7VGLBNQ5 `d1zb3ydtksjw1r.cloudfront.net` |
| CloudFront prod (app.pocket-dj.com) | E1SP8M1SIF7Q8D `d2p4cubg6se03u.cloudfront.net` | E2CHNQT5S5WLU3 `d1j6qufkowz1xq.cloudfront.net` |
| CloudFront legal (legal.pocket-dj.com) | E9XDXX3A506H6 `d7hqmfs8guzv3.cloudfront.net` | E2B0F6795P6Z6S `d1ucyuf4465q66.cloudfront.net` |
| CloudFront www (pocket-dj.com, www) | E9L9V188S55F7 `d20r2rqpcnebjm.cloudfront.net` | ELX7JB4JIT29F `d3cxthv1ih70b5.cloudfront.net` |
| CloudFront jukebox (jukebox.pocket-dj.com) | E1XIWBBPFOJ07E `d3jlgkneh3xj10.cloudfront.net` | EKSX6E9IZE4PW `d1igcuqw3ey3p0.cloudfront.net` |
| CF function | pocketdj-subpath-rewrite | pocketdj-subpath-rewrite (LIVE) |
| OAC legal / www | E2KC78DUA03I2D / E118VVQZEKIVR3 | E1NF65FHKQEUDP / E1RH3HKBPJNLBR |
| Search API (HTTP) | fnlg100ir5 | zoj32t7rh6 |
| Rec engine + /pockets API | n5ordrwfe9 | kwgk9osywa |
| AM playlist sync API | ynwdaa8vh2 | webhj3e832 |
| AOSS collection pocketdj-search (NextGen, min-OCU 0, group pocketdj-search-grp) | mii9dwge3uiee2tvivt5 | l4srqmhutoh0wlko9y55 |
| S3 buckets | `pocketdj-{am-sync-jobs,dev-web,legal-site,logs,mail,prod-web,rec,rips,www}-011183829623` | same with `-623170744161` |
| Rips public base | `https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com` | `https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com` |
| SQS | `https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-*` | `…/623170744161/pocketdj-*` (same 6 names, same attrs, DLQ redrive maxReceive 3) |
| Lambdas | pocketdj-{rec-engine,listening-pockets,am-playlist-sync,search-proxy,mail-forwarder} | same names, same code (CodeSha256 equal), env re-pointed |
| EventBridge | pocketdj-listening-pockets-nightly `cron(30 11 * * ? *)` | same (ENABLED; runs on green's copy — harmless, the cutover re-sync overwrites) |
| Secrets | pocketdj/am-playlist-sync | pocketdj/am-playlist-sync (value copied, sha256 `ec3b1db6e35bb483` both) |
| IAM users | djpocketsearch, pocketdj-diag-writer | same names, NEW keys in Secrets Manager `pocketdj/green/djpocketsearch`, `pocketdj/green/pocketdj-diag-writer` |
| Enroll secret (REC_ENROLL_SECRET) | rec-engine + listening-pockets env | SAME value (sha256 `00a78c736b2634c7` both) |
| Route 53 zone pocket-dj.com | Z03022171BNC2FYFN00JW | Z05179691I2CAGY39SYH0 |
| Nameservers | ns-1752.awsdns-27.co.uk, ns-1106.awsdns-10.org, ns-25.awsdns-03.com, ns-668.awsdns-19.net | **ns-1337.awsdns-39.org, ns-1590.awsdns-06.co.uk, ns-844.awsdns-41.net, ns-472.awsdns-59.com** |
| ACM (us-east-1) | 5 certs, ISSUED | 5 certs PENDING_VALIDATION (validate after the NS switch): app `cbc63ba9…`, dev.app `edb20f87…`, legal `fde08360…`, jukebox `278ff2cc…`, pocket-dj.com+www `0f56b317…` |
| SES pocket-dj.com (us-west-2) | verified, DKIM tokens p524…/7zv2…/5d2i…, production access | identity created, PENDING; green DKIM tokens `tmtiojvx7njcjdb7rw2khsj7atlsbewr`, `ps57bmtcschurz7frhl6gr2y3mczaqdg`, `kaxb4r3ih2wxslozu7nrmh7d643pzxpc`; SANDBOX |
| SES receipt | rule `forward-all` in active set `pocketdj-inbound` (shared with nonprofit rules) | set `pocketdj-inbound` with `forward-all` → green mail bucket + green forwarder, **INACTIVE** |
| EC2 launch templates | pocketdj-stem-worker, pocketdj-timbre-worker | lt-0ec5d5fcc7bfdb0a9, lt-029827be6f334baf4; SG `sg-089bbef8b604d74f7` (22 from 184.3.250.115/32); key pair `pocketdj-stem-key` = `~/.ssh/id_ed25519.pub` |

### Not mirrored / differs, and why

- **Stem golden AMI** `ami-0e042d0c5d176a86c` is private to blue. Copying it needs a blue-side
  `modify-image-attribute` share (a blue change), so green's stem template currently points at
  stock Ubuntu 22.04 (`ami-08b8e678f21f7e4a0`) as a placeholder; a worker booted from it finds no
  venv/node and terminates itself. Options (Levi's pick): (a) one-time share of the AMI + its
  snapshot `snap-07cb3c57412d3e51c` to 623170744161, `copy-image` in green, unshare; or (b) re-bake
  in green. Then `echo -n <ami> > scripts/green/state/ec2.stem.golden-ami && bash scripts/green/provision.sh ec2`.
- **Aliases + custom certs** are not on green distributions (CloudFront forbids one alias in two
  accounts); green is tested on `*.cloudfront.net` with the default cert.
- **Green-only DNS records**: the 6 ACM validation CNAMEs for green's certs (names don't exist in blue).
- **SES email identities** `info@`, `dmca@pocket-dj.com`, `levismschoen@gmail.com` (blue sandbox-era
  verifications) not created; green needs production access instead (or verify FORWARD_TO).
- **Search proxy Function URL**: blue has a stale `fnurl-public` permission but no Function URL; not mirrored.
- Log groups: blue sets no retention; green the same (created on first invoke).

## Data

Copied server-side with `scripts/green/data-sync.sh` (blue = read-only source). Counts/bytes at
copy time are in `scripts/green/state/sync-logs/<bucket>.log` (untracked). Initial copy
2026-10-13 00:00–00:40Z; the temporary cross-account grant was removed afterwards (verified:
blue's Developer now gets AccessDenied on green buckets).

| Bucket | blue objects / bytes | green objects / bytes | Note |
|---|---|---|---|
| am-sync-jobs | 2 / 7,256 | 2 / 7,256 | match |
| dev-web | 11,164 / 135,207,964 | 11,164 / 135,207,964 (+ green config/endpoints.json) | match |
| legal-site | 6 / 204,659 | 6 / 204,659 | match |
| logs | 171,110+ / ~268 MB | 171,167 / ~273 MB | blue keeps receiving logs; green adds its own access logs |
| mail | 2 / 14,411 | 3 / 15,056 | +1 = SES's AMAZON_SES_SETUP_NOTIFICATION |
| prod-web | 7,466 / 124,007,810 | 7,467 / 124,008,551 | +config/endpoints.json, rewritten search-config.json |
| rec | 2 / 3,975,611 | 2 / 3,975,611 | match |
| rips | 54,000 / 227,552,979,855 | 54,000 / 227,552,979,855 | match (4 worker-code files then rewritten in place, same sizes) |
| www | 3 / 168,494 | 3 / 168,494 | match |

Search index rebuilt in green from `public/{current,apple-music,digital}-index.json`: 124,762 docs. Re-sync command for
cutover (copies changes AND mirrors deletes, then re-applies green-specific objects):

```bash
GRANT=1 bash scripts/green/provision.sh s3-policies          # temporary grant for blue's Developer
SYNC_DELETE=1 bash scripts/green/data-sync.sh               # all buckets, rips last
bash scripts/green/provision.sh web-config worker-code      # search-config.json, config/endpoints.json, worker-code ids
bash scripts/green/provision.sh s3-policies                 # REMOVE the grant
POCKETDJ_ENV=green node scripts/es-index.mjs --endpoint https://l4srqmhutoh0wlko9y55.aoss.us-west-2.on.aws \
  --index pocketdj --profile llc --sources public/current-index.json,public/apple-music-index.json,public/digital-index.json
```

Green-specific objects (always re-run `web-config worker-code` after any sync):
- `prod-web|dev-web/search-config.json` → host = green AOSS.
- `prod-web|dev-web/config/endpoints.json` ← `config/endpoints.green.json` (remote endpoint config).
- `rips/worker-code/*` → account id swapped so green workers use green bucket/queues.
- `mail/inbound/AMAZON_SES_SETUP_NOTIFICATION` is written by SES itself in green (explains mail +1 object).

## Cutover runbook (in order)

Each step lists its rollback. Steps marked **BLUE CHANGE** modify blue and need Levi's go-ahead at
that moment.

### 0. Before (any time)
1. Green quotas — EC2 Spot + On-Demand standard vCPU (were 5, auto-raised to 32/16; blue: 64; timbre
   worker c7g.2xlarge needs 8). 64/64 requested 2026-10-13 (PENDING). SES production access in
   us-west-2 filed 2026-10-13 with blue's approved use case (PENDING; green is sandboxed until then,
   200/day, verified recipients only — the mail forwarder sends via SES).
   Status: `aws sesv2 get-account --profile llc --region us-west-2 --query Details.ReviewDetails`.
   The temporary blue→green copy grant is ON again (2026-10-13) for the final re-sync; remove it after
   with `bash scripts/green/provision.sh s3-policies`.
2. Golden stem AMI (see above).
3. `bash scripts/green/smoke.sh` — expect all PASS.

### 1. Nameserver switch (no behaviour change)
Green's zone answers identically to blue (verified with `verify-dns.sh`: 18/18 rrsets identical on
all 4 green nameservers; aliases to blue CloudFront work cross-account).
1. Levi at Hover: set nameservers to `ns-1337.awsdns-39.org`, `ns-1590.awsdns-06.co.uk`,
   `ns-844.awsdns-41.net`, `ns-472.awsdns-59.com`.
2. Watch `dig NS pocket-dj.com @a.gtld-servers.net` flip; .com delegation TTL is 2 days, so both
   zones serve for up to 48 h — they're identical, so that's fine. **Don't edit either zone's
   existing records until the switch has settled**, or make the same edit in both.
3. Green ACM certs move to ISSUED within minutes (`aws acm list-certificates --region us-east-1 --profile llc`).
- Rollback: set Hover back to blue's 4 nameservers.

### 2. Data freeze + final re-sync
Pause Mac writers (step 5's jobs), then run the re-sync block above. Verify the `VERIFY MATCH`
lines (logs bucket keeps receiving blue's access logs; a small diff there is expected).
- Rollback: none needed (blue untouched).

### 3. Per-hostname CloudFront move (repeat for jukebox → legal → dev.app → www/apex → app)
Use CloudFront's cross-account alias move (no blue action needed):
1. Attach the green cert to the green distribution (no alias yet): `get-distribution-config`, set
   `ViewerCertificate={ACMCertificateArn:<green cert>,SSLSupportMethod:sni-only,MinimumProtocolVersion:TLSv1.2_2021}`,
   `update-distribution` (profile llc).
2. In the GREEN zone add TXT `_<host>` (e.g. `_app.pocket-dj.com`) = the green distribution domain
   (e.g. `d1j6qufkowz1xq.cloudfront.net`).
3. `aws cloudfront associate-alias --target-distribution-id <green id> --alias <host> --profile llc`
   — moves the alias off blue's distribution atomically.
4. UPSERT the green zone's `<host>` A alias (Z2FDTNDATAQYW2) → green distribution domain (add AAAA
   too; distributions are IPv6-enabled). Apex `pocket-dj.com` + `www` both go to ELX7JB4JIT29F.
5. Verify `curl -sI https://<host>/` and the app. Remove the TXT.
- Rollback: TXT `_<host>` = blue distribution domain, then `associate-alias` to the blue id run
  **from blue (BLUE CHANGE)**, and point the record back at the blue domain. Blue distributions keep
  their certs, so this is immediate.
- Note the blue `*.cloudfront.net` names and execute-api ids stay embedded in shipped clients — blue
  keeps serving them as shims (migration plan, open question).

### 4. Mail (SES)
1. Add green's 3 DKIM CNAMEs to the green zone (`<token>._domainkey.pocket-dj.com` →
   `<token>.dkim.amazonses.com`); keep blue's three until blue is retired. Wait for VERIFIED.
2. SES production access granted (step 0), or verify `levismschoen@gmail.com` in green.
3. Activate the receipt rule set — **one active set per account+region**: if another domain in
   623170744161 already has an active set, add the `forward-all` rule to it instead
   (`provision.sh ses` creates it in `pocketdj-inbound`).
   `aws ses set-active-receipt-rule-set --rule-set-name pocketdj-inbound --profile llc --region us-west-2`
4. **BLUE CHANGE**: disable rule `forward-all` in blue's `pocketdj-inbound` set (it also carries the
   nonprofit's africanintellect rules — do not delete the set or deactivate it). MX stays
   `10 inbound-smtp.us-west-2.amazonaws.com`.
5. Test: mail info@pocket-dj.com → arrives via green (object in `pocketdj-mail-623170744161/inbound/`).
- Rollback: re-enable blue's rule, deactivate green's set.

### 5. Mac-side jobs → green
All take `POCKETDJ_ENV`; set it AND the profile in each `~/Library/LaunchAgents/com.pocketdj.*.plist`
(`<key>POCKETDJ_ENV</key><string>green</string>`, `<key>AWS_PROFILE</key><string>llc</string>`),
then `launchctl bootout`/`bootstrap` each:
`am-sync-nightly`, `am-sync-agent`, `digital-sync-nightly`, `rec-audio-nightly`,
`streaming-links-nightly`, `rip-backfill`, `ripserver` (rip-server.mjs), `jukeboxserver`,
`stem-autoscaler`, `timbre-autoscaler`. Templates in `scripts/launchd/` carry `POCKETDJ_ENV=blue` today.
- AOSS host: `am-sync-nightly.sh` / `digital-sync-nightly.sh` / `deploy-search-proxy.sh` read
  `public/search-config.json` first — publish the green host there (or set `POCKETDJ_ES_ENDPOINT`).
- Stem autoscaler in green: set `POCKETDJ_STEM_SUBNETS` (blue's measured subnets are only used for
  blue) and `POCKETDJ_STEM_PIN_SUBNET` for `stem-spot-setup.mjs`.
- `scripts/deploy.sh` (PWA) with `POCKETDJ_ENV=green` deploys to the green buckets/distributions.
- Rollback: flip the plists back to `blue`/`levi`.

### 6. Credentials on devices
- **djpocketsearch** (online search, read-only AOSS): the app takes it in Settings ▸ Online search
  and syncs it to the owner's devices through the iCloud "settings-credentials" doc (credsync,
  `apple/PocketDJ/Settings/SettingsCredentialsSync.swift`); the Mac copy is
  `~/Downloads/djpocketsearch-credentials.json`. Green key: Secrets Manager
  `pocketdj/green/djpocketsearch` (profile llc). Enter it once on one device when search moves.
- **pocketdj-diag-writer** (S3 PutObject `diag/*`): Keychain (iCloud-synced), entered in the Debug
  view (`DiagCredentialStore.swift`). Green key: `pocketdj/green/pocketdj-diag-writer`.
- Retrieve without echoing to a shared terminal:
  `aws secretsmanager get-secret-value --secret-id pocketdj/green/<user> --profile llc --query SecretString --output text | pbcopy`
- **REC_ENROLL_SECRET**: identical in green — no client change.
- Remember the credsync empty-secret clobber guard is still open (memory: tailscale-path-mount note).

### 7. Clients
Ship builds reading `config/endpoints.json` (feat/remote-endpoints); green's prod/dev web buckets
already carry `config/endpoints.json` = `config/endpoints.green.json`. Publish via
`CONFIG_ONLY=1 PDJ_ENDPOINTS_ENV=green scripts/deploy.sh prod` once that branch lands.

## Blue teardown checklist — ONLY with Levi's explicit OK

Do not start until clients have moved (shim lifetime is Levi's decision) and green has run a week.
Every item is a BLUE CHANGE; never touch non-PocketDJ resources (africanintellect-*, fin-*, contact
API, the `pocketdj-inbound` rule set itself — it carries the nonprofit's rules).

- [ ] Final `SYNC_DELETE=1` re-sync done and verified (above).
- [ ] CloudFront: disable, then delete E123GKAO9JVETP, E1SP8M1SIF7Q8D, E9XDXX3A506H6, E9L9V188S55F7, E1XIWBBPFOJ07E (keep the two `*.cloudfront.net` shims if old clients still need them); delete function `pocketdj-subpath-rewrite`, OACs `pocketdj-legal-oac`, `pocketdj-www-oac`.
- [ ] ACM us-east-1: the 5 pocket-dj.com certs (after their distributions are gone).
- [ ] API Gateway fnlg100ir5, n5ordrwfe9, ynwdaa8vh2 (shims for old builds — last to go).
- [ ] Lambdas pocketdj-{rec-engine,listening-pockets,am-playlist-sync,search-proxy,mail-forwarder} + their log groups; roles `pocketdj-*-role`, `pocketdj-mail-forwarder`, `pocketdj-stem-worker` + instance profile.
- [ ] EventBridge `pocketdj-listening-pockets-nightly`.
- [ ] SQS 6 queues; launch templates `pocketdj-stem-worker`, `pocketdj-timbre-worker`; SG `pocketdj-stem-sg`; key pair `pocketdj-stem-key`; AMI `ami-0e042d0c5d176a86c` + snapshot.
- [ ] AOSS collection `pocketdj-search`, group `pocketdj-search-grp`, policies `pocketdj-net`, `pocketdj-data`.
- [ ] Secret `pocketdj/am-playlist-sync`.
- [ ] SES: rule `forward-all` (only that rule), identities pocket-dj.com, info@/dmca@pocket-dj.com.
- [ ] IAM users djpocketsearch, pocketdj-diag-writer (delete keys first).
- [ ] S3: empty + delete the 9 `pocketdj-*-011183829623` buckets (rips last; old clients stream from it).
- [ ] Route 53 zone Z03022171BNC2FYFN00JW (only after Hover points at green and TTLs expired).
