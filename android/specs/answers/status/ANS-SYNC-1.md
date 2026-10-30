state: reviewed

# ANS-SYNC-1 Profile sync go-live

- [x] Enroll token via endpoints-doc `capabilities.profileSyncEnroll` (EndpointConfig + RemoteEndpoints.profileSyncEnroll(), per-request, rotatable); Enrollment.tokenFrom(doc, keystore fallback); never compiled in
- [x] Sync default OFF / no enroll or upload until opted in: already enforced by CloudSyncService `enabled` (existing tests); unchanged
- [x] Settings-credentials doc: search key/secret/endpoint removed from the data class and from live read/apply (Q10 device-local). iOS requires those keys at decode, so the last-pulled values are passed through verbatim (empty strings when none)
- [x] SyncEntry("imported-songs") + ImportedSongsStore.reloadFromDisk(); added to AccountDeletionService.cloudDocKeys; lockstep tests updated
- [x] Lambda DEPLOYED to green (AWS_PROFILE=llc, Levi-approved): pocketdj-profile-sync, bucket pocketdj-profiles-623170744161, base https://0xuk8mi7cb.execute-api.us-west-2.amazonaws.com; deploy.sh now writes capabilities.profileSyncEnroll; config/endpoints.green.json updated (base + token)
- [x] Validator (src/config/endpointSchema.ts, validate-endpoints.ts) accepts/validates profileSyncEnroll; vitest case added (22 pass)
- [x] Real-endpoint smoke (curl): enroll 200 (no token 401), PUT/GET doc, DELETE /profile -> deleted:2, then same creds 401 (the app's "profile not found")

## Files touched outside the owned list (additive)
data/catalog/ImportedSongsStore.kt (reloadFromDisk, SYNC_KEY), data/reset/AccountDeletionService.kt (key list), data/config/RemoteEndpoints.kt, data/credentials/CredentialsSync.kt, src/config/endpointSchema.ts, src/config/remoteEndpoints.test.ts, scripts/validate-endpoints.ts, EndpointsGreenPinTest (compiled-in excludes doc-only profileSyncBase), ImportedSongsStoreTest, CredentialsSyncTest (search guard test replaced)

## Questions for Levi
- The endpoints doc is committed with the enroll token but NOT yet published (CONFIG_ONLY=1 scripts/deploy.sh prod). Until published, installed apps have no profileSyncBase, so the toggle stays disabled. Publish when ready (token is world-readable there, same threat model as recEngineEnroll; MAX_PROFILES=50 is the guard).
- Android-originated creds doc with no prior pulled copy emits empty search strings; if an iOS device pulls it before Android ever pulled, iOS's search config could be blanked (iOS adopts differing endpoint). Android pulls first in normal flow.
- Two-emulator link/restore step and iOS-side adoption of capabilities.profileSyncEnroll not run.
- Smoke test profile ids (smoke-*) were wiped by DELETE /profile; one unrelated 'enroll' smoke profile (random uuid) remains in the green bucket.

## Summary
Profile sync now enrolls against the real green Lambda using a runtime token from the endpoints doc, stays opt-in/OFF, keeps search credentials device-local, and syncs imported songs.

## Tests
`:app:testDebugUnitTest :app:assembleDebug` green: 5580 tests, 0 failures (new: EnrollmentTokenTest 6, SettingsCredentialsDocumentTest 4, ImportedSongsStore +2, CredentialsSync +1 net, pin test strengthened). assembleRelease not run (no manifest/proguard/build changes).
