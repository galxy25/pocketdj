# Profile sync over S3 (Android) — `pocketdj-profile-sync`

iOS syncs profile documents (`CloudSyncService`) through CloudKit whole-document last-writer-wins.
Android has no CloudKit, so the same `CloudDocDatabase` contract (meta / fetch / save / delete /
deleteAll) is served by a small first-party Lambda over a private S3 bucket. Decision: D7 in
`docs/architecture/android-parity.md`. Implementation: `scripts/lambda/profile-sync/index.mjs`;
client: SVC-9 `S3CloudDocDatabase`.

## Endpoint discovery
Optional key `profileSyncBase` in the remote-endpoint doc (`config/endpoints.<env>.json`). Absent
means sync is disabled; it is never derived from another key. The existing PWA validator ignores
unknown endpoint keys, so the doc stays valid for every client. `deploy.sh` writes the key and
re-validates with `scripts/validate-endpoints.ts`.

## Identity and auth
- `profileId`: durable profile UUID (lower-cased by the server; `[a-z0-9-]{1,64}`).
- `secret`: 32 random bytes minted on the device, kept in EncryptedSharedPreferences. The server
  stores only `SHA-256(secret)` (hex) in `profiles/<profileId>/_auth.json`.
- `POST /enroll` needs `X-PocketDJ-Enroll: <capability token>` (Lambda env `ENROLL_SECRET`, compared
  in constant time, unset = every enroll refused). Same pattern and trust level as the rec engine:
  it is a capability token embedded in the build, not a per-user credential. Body
  `{profileId, secretHash}`. Same hash again = 200 `{created:false}` (idempotent); a different hash
  for an existing profile = 409. `MAX_PROFILES` caps distinct profiles (429); existing profiles are
  unaffected by the cap.
- Every other route (except `/health`) needs `X-PocketDJ-Profile` + `Authorization: Bearer <secret>`.
  Any failure (missing header, unknown profile, wrong secret) is a uniform 401.
- Linking a device = sharing `profileId` + `secret` (QR/code, SVC-9); no server involvement.

## Routes
| Method + path | Behavior |
|---|---|
| `GET /health` | `{ok:true}`, no auth |
| `POST /enroll` | see above |
| `GET /meta[?keys=a,b]` | `{key: modifiedAtMs}` for keys that exist (HEAD fan-out). No `keys` = every doc. Bad key = 400 |
| `GET /doc/{key}` | stored body verbatim, header `X-PocketDJ-Modified-At`; 404 if absent |
| `PUT /doc/{key}` | body must be JSON, 5 MB max (413); headers `X-PocketDJ-Modified-At` (ms, defaults to server now) and `X-PocketDJ-Device` (free text, 100 chars). 200 `{ok,key,modifiedAtMs}` |
| `DELETE /doc/{key}` | idempotent, always 200 |
| `DELETE /profile` | deletes the whole `profiles/<profileId>/` prefix including `_auth.json` (the id can be re-enrolled afterwards) |

Doc keys are `[a-z0-9-]{1,40}` (so `_auth` can never collide). Timestamps are the client's clock;
conflict policy (2 s skew, watermarks) stays in the client engine, exactly as on iOS.

## Storage
Private bucket `pocketdj-profiles-<account>` (public access blocked, SSE-S3). Objects
`profiles/<profileId>/<key>.json` with S3 user metadata `modified-at-ms` and `device`. The Lambda
role can only touch `profiles/*`.

## Deploy
`POCKETDJ_ENV=green AWS_PROFILE=llc scripts/lambda/profile-sync/deploy.sh` (re-runnable). It
preserves the enrollment secret and cap across runs; a freshly minted secret is printed once.
Tests: `node --test scripts/lambda/profile-sync/test/profile-sync.test.mjs` (in-memory store).
