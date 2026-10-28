state: merged

# SVC-8 — pocketdj-profile-sync Lambda (S3 document store)

- [x] scripts/lambda/profile-sync/index.mjs (enroll, meta, doc GET/PUT/DELETE, profile wipe; injectable store)
- [x] test/profile-sync.test.mjs — 15 node:test cases, all pass (`node --test scripts/lambda/profile-sync/test/profile-sync.test.mjs`)
- [x] deploy.sh (bucket, role, function, HTTP API; re-runnable; writes profileSyncBase + validates)
- [x] docs/design/profile-sync-s3.md
- [x] Endpoint doc with profileSyncBase validates with the PWA validator (checked with a placeholder URL)

## Deviations / notes
- NOT deployed (needs AWS profile llc, device-only). config/endpoints.green.json is unchanged: the real
  URL does not exist yet; deploy.sh adds `profileSyncBase` on first run. Re-run validation then.
- No Kotlin touched: JVM unit-test count unchanged by design (this package's tests are node:test).
- src/config/endpointSchema.ts not touched: the validator ignores unknown keys, so the optional key
  already validates. SVC-7/9 clients should read it as optional-absent => sync disabled.
- Client sends secretHash = hex SHA-256(secret) at enroll; bearer is the raw secret. profileId is lower-cased server-side.
- Enroll capability token is a separate Lambda env (ENROLL_SECRET), minted by deploy.sh; SVC-9 must embed it (like recEngineEnrollSecret).
- Added MAX_PROFILES cap (default 50 at deploy) beyond the roadmap.

## Questions for Levi
- Is a separate enroll token OK, or reuse the rec-engine REC_ENROLL_SECRET (fewer secrets in the build)? Defaulted to separate.
- Deploy to green when ready (`AWS_PROFILE=llc scripts/lambda/profile-sync/deploy.sh`), then commit the updated config/endpoints.green.json.

## Review
fixes applied. Node tests 15 -> 20 (`node --test scripts/lambda/profile-sync/test/profile-sync.test.mjs`); vitest src/config 20 pass; Android JVM 2759 pass / 0 fail (unchanged, no Kotlin touched).
- MAJOR payload cap -> fixed: PUT accepts `Content-Encoding: gzip` (cap on 4 MB compressed wire bytes, 128 MB inflate guard), stored gzip, GET passes gzip through on `Accept-Encoding: gzip`; documented in profile-sync-s3.md ("Size limit"); test over-5MB doc round-trips. Presign option not taken (gzip is ~10:1 on JSON; ~40 MB headroom).
- MINOR modified-at parsing -> fixed: finite non-negative decimal/exponent/fractional accepted+rounded; malformed -> 400; tests.
- MINOR deploy.sh getenvvar -> fixed: FN_EXISTS flag; unreadable/missing secret on existing function aborts; mint only for new function.
- MINOR lost secret / 409 -> fixed as documentation (client relink or new profileId, exclude pocketdj-profile.json from backup; no server rotate by design). Android backup rules are SVC-9's files; not edited here.
- MINOR validate-endpoints -> fixed: profileSyncBase in OPTIONAL_ENDPOINT_KEYS (no derivation, allowlist-validated) + vitest; deploy.sh validation failure now exits non-zero.
- MINOR enroll cap/race -> fixed: conditional put (IfNoneMatch '*') with 200/409 on loss; warnings logged at 80%/cap. Per-IP throttle left as documented follow-up (API Gateway setting).
- NIT device header on GET -> fixed (+assert). NIT bad percent-escape -> 400 (+test).
- NIT status/ledger -> partly: status now `reviewed`; remains PARTIAL in substance (device-only: deploy, commit config/endpoints.green.json profileSyncBase; ARCHITECTURE-ANDROID.md ledger row is the ledger owner's; no Kotlin tests by design).
