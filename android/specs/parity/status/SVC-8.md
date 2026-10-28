state: implemented

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
