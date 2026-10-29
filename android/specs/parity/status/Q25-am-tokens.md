# Q25: real Apple Music tokens for the Android emulator

How to get a real Apple Music developer token and a Music-User-Token (MUT) for Levi's
account onto the iMac, then run the Android SVC-15 catalog + library/favorites probes against
the real Apple Music API on the emulator. Token values never go in git, logs or diag uploads.
They live only in a chmod-600 scratch folder (`$TOK` below).

## 1. Developer token (no app needed)

The green am-playlist-sync Lambda mints it (ES256, kid 9JRN4H68X4, team EC27UF79GL, about 150 days):

```
curl -s https://webhj3e832.execute-api.us-west-2.amazonaws.com/musickit-token > $TOK/devtoken.json   # {token, expiresAt, ttlSec}
```

The compiled-in blue host (`ynwdaa8vh2`) no longer resolves. Use the green host from
`config/endpoints.green.json`.

## 2. Music-User-Token (Debug macOS build, no clicks)

`apple/PocketDJ/Support/AMTokenDump.swift` is compiled in DEBUG only, and it does nothing
unless `PDJ_DUMP_AM_TOKENS=1` is set. When it runs, it mints the developer token, calls
`MusicUserTokenProvider().userToken(for:options: [.ignoreCache])`, and writes
`~/Library/Containers/com.levi.pocketdj/Data/Library/Application Support/am-token-dump.json`
with mode 0600. It prints only that path and the key names.

1. Build Debug for macOS (Apple Development signing, `-allowProvisioningUpdates` with the ASC key,
   after unlocking `pocketdj-ci.keychain-db`).
2. `open` fails with -10699 while the TestFlight PocketDJ is running. Running the binary straight
   from SSH can't reach TCC either (authorization stays `.notDetermined`). Start it as a one-shot
   LaunchAgent in the Aqua session instead:
   `launchctl bootstrap gui/501 amdump.plist`. Set `ProgramArguments` to `.../PocketDJ.app/Contents/MacOS/PocketDJ`,
   and set `EnvironmentVariables` to `PDJ_DUMP_AM_TOKENS=1`, `PDJ_DUMP_AM_TOKENS_EXIT=1`,
   `PDJ_DISABLE_CLOUD_SYNC=1` and `PDJ_AM_SYNC_BASE=https://webhj3e832.execute-api.us-west-2.amazonaws.com`.
   Also set `LimitLoadToSessionType=Aqua` and `RunAtLoad`.
3. Wait for the file, run `launchctl bootout gui/501/com.levi.pocketdj.amtokendump`, move the
   tokens into `$TOK`, and delete the dump file.

On this iMac, Media & Apple Music access was already granted, so no prompt appeared. If
`authorization` comes back `.denied`/`.notDetermined`, Levi has to click **OK** on the
"PocketDJ would like to access Apple Music…" dialog on the iMac's screen, or enable PocketDJ in
System Settings > Privacy & Security > Media & Apple Music.

**`.ignoreCache` is required.** Without it, MusicKit returned a cached MUT that the REST API
rejects (`403 40300 Invalid authentication`), even though MusicKit's own `MusicDataRequest` still
works in-app. A fresh MUT works with any developer token from the green Lambda.

The dump also records sanity checks that hold no secrets: `inAppStorefrontStatus` (via
MusicKit) and `inAppURLSessionStorefrontStatus` (plain REST with the minted pair). Both should
be 200.

Expiry: the developer token lasts about 150 days (JWT `exp`). Apple doesn't publish a MUT
lifetime (it's usually months). It can be revoked, and a 403 on `/v1/me/storefront` means you
should re-run step 2.

## 3. Feed the emulator (DEBUG launch extras)

`CollectionsGraph` deep-link handler, `BuildConfig.DEBUG` only:

| extra | effect |
|---|---|
| `pdj.amDevToken <jwt>` | invalidates the cached token, then persists a REAL developer token (expiry decoded from JWT `exp`) |
| `pdj.amMut <mut>` | persists a REAL Music-User-Token (same store as `pdj.fakeMut`) |
| `pdj.amProbe 1` | runs `AppleMusicLiveProbe` and logs each step to tag `PdjVerify` (no token values) |
| `pdj.amProbeTerm <q>` | catalog search term (default `daft punk`) |
| `pdj.amProbeSongId <catalogId>` | song for the write probes. Pick one ALREADY in the library so the add does nothing |
| `pdj.amProbeStar 1` | also run the irreversible ★ `/v1/me/favorites` (off by default) |

```
adb shell am start -n com.levi.pocketdj/.MainActivity \
  --es pdj.amDevToken "$(cat $TOK/devtoken.txt)" --es pdj.amMut "$(cat $TOK/mut.txt)" \
  --es pdj.amProbe 1 --es pdj.amProbeSongId <catalogId>
adb logcat -d -s PdjVerify | grep "AM probe"
```

Tokens persist in Settings, so later launches only need `--es pdj.amProbe 1`. The probe puts the
love rating back (unrates it) unless the song was already loved.

## Finding: production MUT minting (not fixed on this branch)

`MusicUserTokenService.musicUserToken()` (iOS/macOS) calls `userToken(for:options: [])`, which
returns the CACHED MUT. Every am-playlist-sync job in the green jobs bucket since cutover
(10-27 to 10-28, 4 of 4) failed with `AM GET /v1/me/library/playlists -> 403`. That matches
the stale cached token seen here. Suggested fix: on a 403 from the Lambda, re-mint with
`[.ignoreCache]` (or always use it).

No TestFlight "Developer" settings section is needed, because the locally signed Debug build
mints a working MUT once `.ignoreCache` is set.
