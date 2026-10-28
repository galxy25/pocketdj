state: merged

# SVC-9 - S3CloudDocDatabase + enroll + link-a-device + onboarding stage-1 probe

- [x] RemoteEndpoints: optional EndpointKey.PROFILE_SYNC_BASE (absent => sync disabled, no network)
- [x] ProfileSecretStore (Keystore SecretStore only; redacted toString; snapshot/restore for rollback)
- [x] Enrollment (once per profile id; retry 5xx; refuse 401/403/429 sticky; 409 => relink)
- [x] S3CloudDocDatabase (all routes, gzip PUT, 401 => unauthorized/accountAvailable false)
- [x] LinkCode (Crockford base32, CRC32, URI form) + QR render (zxing core, already a dependency)
- [x] S3LinkDeviceProbe + CodeLinkProbe; onboarding stage 1 code entry + "Restore my stuff"
- [x] Settings "Link a device" section (LinkDeviceScreen.kt, order 51): show code/QR, enter code, restore, "Profile not authorized - relink"
- [x] ServicesGraph wiring (default cloudDocDatabase = s3Database; reset hook clears secret)
- [x] Tests: LinkCodeTest 9, EnrollmentTest 10, S3CloudDocDatabaseTest 20, LinkDeviceProbeTest 8 (47 new). Full suite 3428 pass / 0 fail.

## Deviations / files touched outside owned set (all minimal, additive)
- data/sync/ProfileStore.kt: added adoptIdentity(id).
- onboarding/OnboardingStages.kt: EnterCode phase + Restore button in stage 1 (uses servicesGraph.linkProbe when shell probe is the stub).
- onboarding/LinkDeviceProbe.kt: added CodeLinkProbe + S3LinkDeviceProbe (owned).
- GET relies on OkHttp transparent Accept-Encoding: gzip (explicit header would disable inflation).
- Camera QR scanning deferred (code entry only); QR is displayed. pocketdj://link deep link NOT registered (SURF-4 owns manifest filters).
- Sync is effectively inert until profileSyncBase is in the endpoint doc AND the enroll token is provisioned.

## Questions for Levi
- Enroll capability token: read from SecretStore key "profileSyncEnrollToken" (no BuildConfig edit to hot build file). How should it ship in release builds (BuildConfig from a gradle property, like the rec-engine one)? Until then enrollment returns NotConfigured and sync stays off.
- Exclude pocketdj-profile.json from Auto Backup (or back up with the secret) per profile-sync-s3.md; not done here (manifest/backup rules are hot files).
- 409 on enroll (secret lost) currently = "Profile not authorized - relink"; no auto-mint of a new profileId.

## Review
fixes applied

- MAJOR Onboarding keeps linked identity after leaving restore path -> fixed. New `RestoreFailed` phase (Try again / Back); `CodeLinkProbe.unlink()` restores the pre-link id + secret snapshot; "Start fresh" and Back call it. Tests: LinkDeviceProbeTest startFreshAfterLink / failedRestore_thenUnlink / successfulRestore / unlinkWithoutLink. (Process death mid-LinkFound loses the in-memory snapshot; unlink is then a no-op.)
- MAJOR Settings link pushes over A's data -> fixed. `CloudSyncService.holdPushesForIdentityChange()` (clears old watermarks, blocks all pushes) is called on link; released by a successful `restoreForOnboarding`, a Fresh result, or rollback. `restoreForOnboarding` now waits (up to 10 s) for an in-flight tick instead of returning null. Tests: CloudSyncServiceTest identityChangeHold..., identityChangeClearsOldWatermarks...; LinkDeviceProbeTest link_holdsPushes....
- MINOR main-thread work in onboarding -> fixed. link/restore/unlink run under `withContext(Dispatchers.IO)`.
- MINOR link not serialized vs tick -> fixed. 401s are honoured only if the identity the request was sent with is still current (stale 401 ignored); link/unlink serialized by a mutex. Test: stale401FromAReplacedIdentity_isIgnored.
- MINOR 401 flag in memory only -> fixed. Persisted per profile id in ProfileSecretStore (`profileUnauthorizedId`), cleared by adopt/clearUnauthorized/clear/restore. Test: unauthorized_survivesProcessRestart_untilRelink.
- MINOR ledger row -> fixed. SVC-9 now PARTIAL with what is deferred.
- NIT upper-case id -> fixed in `ProfileStore.adoptIdentity` (test adoptIdentity_storesUpperCaseId_andPersists).
- NIT deleteProfile() uncalled -> deferred: needs the account-deletion flow to call it before ResetHook clears the secret (owned by another package).

Suite: 3438 tests, 0 failures (+10 new); assembleDebug OK.
