# PocketDJ → new standalone AWS account: migration plan (DRAFT)

Status: draft, 2026-10-06. Nothing in account 011183829623 (AFRICANINTELLECTCLUB, a nonprofit
that will receive a TechSoup credit) has been changed. Levi decided PocketDJ and Fin move OUT
to a NEW, separate AWS account so the nonprofit's account carries no private-benefit workloads.
Nonprofit-side inventory: `africanintellect/infra/aws-cost-split-2026-10-05.md`.

## What moves (class O in that inventory)

- S3: 9 `pocketdj-*` buckets; `pocketdj-rips` is 226 GB
- CloudFront: 5 distributions + function `pocketdj-subpath-rewrite`
- Route 53 zone `pocket-dj.com` (registrar: Hover)
- 4 Lambdas; API Gateways `pocketdj-search`, `-rec-engine`, `-am-playlist-sync`
- 6 SQS queues; OpenSearch Serverless collection `pocketdj-search`
- SES identity `pocket-dj.com`; secret `pocketdj/am-playlist-sync`
- IAM users `djpocketsearch` and `pocketdj-diag-writer`

## The hardcoded-endpoint / shim problem (the hard part)

Shipped clients embed account-bound endpoints that cannot be moved:

| Hardcoded | Where | Moves? |
|---|---|---|
| `d2p4cubg6se03u.cloudfront.net` (prod), `djictbz9w796r.cloudfront.net` (dev) | `apple/.../Config.swift`, `android/.../Endpoints.kt` | No. A new account's distributions get new `*.cloudfront.net` names. |
| two `execute-api` IDs (am-playlist-sync, rec-engine) | `Config.swift` | No. New API Gateways get new IDs. |
| `pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com` | `Config.swift`, `Endpoints.kt`, `src/store/useRipsStore.ts` | No. The bucket name embeds the account id; S3 names are global. |

Consequence: every installed build (App Store 1.0.0 / 1.0.1 / 1.0.2, TestFlight, Android) keeps
calling the OLD account until the user updates. The account id also appears in ~35 files
(scripts, tests, docs) that need parameterising.

Plan: parameterise all of it into one config, ship client builds that read endpoints from a
remotely fetched config (so the next move needs no release), and leave **minimal shims** in the
old account until adoption is acceptable. A shim is a CloudFront distribution or API stage that
redirects/proxies to the new account and holds no data. Shim lifetime is Levi's decision (see
open question).

## Phases

0. **Levi:** create a STANDALONE account (not under the nonprofit's Organization), billing,
   root MFA, admin IAM user + CLI profile, quota bumps (Spot vCPU, OpenSearch Serverless OCUs,
   Lambda concurrency), SES production access, and the replacement diag-writer key IN THE NEW
   account (the key rotation and the migration then happen once).
1. Parameterise account id, bucket names and endpoint bases; no deploy.
2. Stand up the stack in the new account: buckets (new names), SQS, Lambdas, API Gateways,
   OpenSearch collection, secret (value copied securely, never printed), CloudFront function +
   distributions, IAM, ACM certs re-issued in us-east-1 (certs cannot transfer).
3. Data: S3-to-S3 sync (source bucket policy, no local download); rips first, re-sync at
   cutover. Rebuild the search index from the index.json sources (es-search-index skill).
4. DNS: new Route 53 zone → new nameservers → Levi changes them at Hover; short cutover. SES:
   re-verify the domain, recreate DKIM; sandbox until production access is granted.
5. Ship client builds pointing at the new endpoints (iOS / tvOS / macOS / visionOS / Android).
6. Watch for a week, then delete from the old account **only with Levi's explicit OK**.

## LEVI-ONLY

Account signup, billing, MFA, quota and SES-production requests, the Hover nameserver change,
creating the new diag key, App Store / Play releases of the new client builds, and deciding how
long the old-account shims live.

## Open question for Levi

Is it acceptable to leave the hardcoded `cloudfront.net` / `execute-api` shims in the old
(nonprofit) account for a long tail, or must the old account be cleared sooner, accepting that
old installed builds break once the shims go?

## Interaction with the nonprofit account

- **Shims left behind:** CloudFront distributions `d2p4cubg6se03u` / `djictbz9w796r`, the two
  API Gateways, and the `pocketdj-rips-011183829623` bucket (or a redirect for it) stay in
  011183829623 until client adoption allows deletion. Duration: undecided (open question).
- **Shared IAM `Developer` user / CLI profile `levi`:** PocketDJ scripts use profile `levi`
  (25 files reference it) and `scripts/es-index.mjs` and `scripts/aoss-create-sz-nextgen.py`
  name `arn:aws:iam::<acct>:user/Developer` in the OpenSearch data-access policy. These must be
  re-pointed at the new account's admin user.
- **Route 53 / SES / CloudFront:** the zone, SES identity and ACM certs for `pocket-dj.com` are
  recreated in the new account; the old zone and identity are deleted only after the Hover
  nameserver switch has settled.
- **`pocketdj-diag-writer`:** not carried over; replaced by a new key in the new account.
- **Nonprofit-owned dependencies (repo evidence only):** a search of this repo found no
  references to `africanintellect*` resources, the contact-form API, or the
  `africanintellect-smtp-sender` IAM user, no SES send code, and no S3 buckets other than
  `pocketdj-*`. This is a code search, not an AWS-side check; resource policies or cross-account
  grants in 011183829623 would not show up here.
