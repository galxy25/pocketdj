# PocketDJ Android — Apple Music sign-in + streaming contract (Phase 2 addendum)

**Audience:** an engineer wiring the native **MusicKit for Android SDK** into the
Android client, who has never opened the SDK jars or the iOS app. Every SDK claim
cites the decompiled class surface (`javap` of the AAR's `classes.jar`); every
app/server claim cites `file:line` relative to the repo root. Where a step only
works on a **physical device** (not the emulator) it is flagged **[DEVICE-ONLY]**;
steps that verify on the `pocketdj` **emulator** are flagged **[EMU-OK]**.

> **Reverses locked decision 6.1** (`docs/ARCHITECTURE-ANDROID.md:47-50`, "NO
> MusicKit — Apple Music streaming is impossible on Android"). That decision
> predates the discovery of Apple's **native Android MusicKit SDK** (Dec-2021
> build, still the current release). This spec is the deliberate doc-edit that
> supersedes it: Apple Music **full-track** streaming IS possible on Android, on a
> device with the Apple Music app installed and an active subscription. The
> sources-reality fallback ladder (rip server / metadata-only) is unchanged and
> stays the terminal path.

## Sources of truth

- **Auth SDK** — `musickitauth-release-1.1.2.aar`, package
  `com.apple.android.sdk.authentication` (bundled `AndroidManifest.xml`, `classes.jar`).
- **Playback SDK** — `mediaplayback-release-1.1.1.aar`, package
  `com.apple.android.music.playback.*` (bundled `AndroidManifest.xml`, `classes.jar`,
  `jni/`, `proguard.txt`).
- Both AARs live at
  `…/scratchpad/musickit-sdk/Android-MusicKit-SDK-1.1.2/` and must be **vendored
  into the repo** (§1).
- iOS backend-parity: `apple/PocketDJ/Playback/PlaybackCoordinator.swift`
  (`activeBackend`, provider ordering, single-owner switching).
- Android integration points: `android/app/src/main/java/com/levi/pocketdj/…` —
  `playback/PlaybackController.kt`, `playback/PlaybackService.kt`,
  `playback/PlaybackContract.kt`, `data/rips/PlayResolver.kt`,
  `data/rips/RipServerClient.kt`, `data/settings/AppSettingsStore.kt`,
  `screens/settings/SettingsScreen.kt`, `di/AppGraph.kt`,
  `data/config/Endpoints.kt`, `data/catalog/IndexModels.kt`.
- Dev-token minting: `scripts/rip-server.mjs` (dependency-free `node:http` +
  `node:crypto`; the new `GET /musickit-token` endpoint, §4).

---

## 0. Facts you must not get wrong

1. **The two engines are separate.** Apple Music full-track playback is driven by
   the SDK's own `MediaPlayerController` (its own native audio engine, `jni/`
   `.so`), **NOT** by Media3 `ExoPlayer`. They are two independent audio owners.
   The single-owner invariant (`docs/ARCHITECTURE-ANDROID.md`, one-audio-owner
   rule) is enforced **by us in `PlaybackController`**: starting one stops the
   other (mirror `PlaybackCoordinator.swift:117-118`).
2. **Full-track playback is arm-only ⇒ [DEVICE-ONLY].** The playback AAR ships
   native libs for **`arm64-v8a` and `armeabi-v7a` ONLY** (`mediaplayback…aar`
   `jni/arm64-v8a/libappleMusicSDK.so`, `jni/armeabi-v7a/libappleMusicSDK.so`;
   **no `x86`/`x86_64`**). A standard `x86_64` emulator cannot load the engine —
   full-track playback there fails at `createLocalController` / first `prepare`.
   This is a hard fact, not a policy.
3. **Android 12+ manifest gotcha is a BUILD BREAK.** You **must** re-declare
   `com.apple.android.sdk.authentication.SDKUriHandlerActivity` with
   `android:exported="false"` in the app manifest, or the manifest merge/build
   fails (the library declares it with an `<intent-filter>` but no explicit
   `android:exported`, illegal on targetSdk ≥ 31). App is `targetSdk 36`
   (`android/app/build.gradle.kts:14`). See §2.
4. **The auth activities extend AppCompat.** `SDKUriHandlerActivity` and
   `StartAuthenticationActivity` `extends androidx.appcompat.app.AppCompatActivity`
   (javap). You **must add `androidx.appcompat:appcompat`** as a dependency or the
   auth flow `ClassNotFoundException`s at runtime (§1). The app is otherwise
   Compose-only and has no appcompat today.
5. **Developer token is server-minted ES256; never embed the .p8 in the app.**
   The `.p8` private key (`AuthKey_9JRN4H68X4.p8`, kid `9JRN4H68X4`, team/iss
   `EC27UF79GL`) mints an ES256 JWT **on the rip server** (§4). The app fetches a
   short-lived dev token over HTTPS from the already-configured rip server; the
   key never ships in the APK.
6. **Two tokens, two lifetimes.** The **developer token** (ES256 JWT, app-wide,
   ≤ 6-month exp, fetched from the server, cacheable) is distinct from the **Music
   User Token** (per-user, returned by the sign-in deep-link into the Apple Music
   app, persisted on-device). `TokenProvider` hands the SDK **both**
   (`getDeveloperToken()` / `getUserToken()`).
7. **AM streaming is gated on `appleMusicId` + no local source.** The AM backend
   is attempted **only** for a song whose `IndexSong.appleMusicId` is set
   (`data/catalog/IndexModels.kt:119`) AND that has no manifest rip and no better
   local path — mirroring iOS ordering (`PlaybackCoordinator.swift:89-100`). The
   catalog song id is **not** the Apple Music id; the SDK queues by
   `appleMusicId` (Apple "store id"), never by our songId.
8. **Sign-in requires the Apple Music app + subscription ⇒ [DEVICE-ONLY].** The
   auth `Intent` deep-links into the installed Apple Music app to obtain consent
   and the Music User Token. The emulator has no Apple Music app, so **real
   sign-in cannot be exercised on the emulator**; the flow returns
   `TokenError.USER_CANCELLED` / no result. Every *other* layer is [EMU-OK].
9. **Preview fallback needs neither the Music User Token nor DRM ⇒ [EMU-OK].**
   30-second previews are plain progressive mp3/m4a URLs (`previews[].url`) played
   by **ExoPlayer** (the existing engine). They are the emulator-testable AM path
   and the graceful fallback when the user is signed out / unsubscribed / on
   x86_64. Preview URL resolution uses the **developer token only** (§6.3) — or
   the tokenless iTunes lookup (§6.3 alt).
10. **`ADDITIVE-OPTIONAL` persistence still rules.** The new persisted fields
    (`musicUserToken`, `appleMusicSignedIn`, cached dev token) are added to
    `AppSettingsStore` as independent Preferences keys, each defaulting when
    absent (`data/settings/AppSettingsStore.kt:100-136`) — never a schema that can
    wipe a saved doc.

---

## 1. Gradle wiring for the two local AARs

**Vendor the AARs into the repo** (they are not on Maven). Copy both into
`android/app/libs/`:

```
android/app/libs/musickitauth-release-1.1.2.aar
android/app/libs/mediaplayback-release-1.1.1.aar
```

`android/settings.gradle.kts` sets
`repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)`, so a module-level
`flatDir { … }` repo is **rejected**. Use file-dependency wiring instead (needs no
repository):

```kotlin
// android/app/build.gradle.kts  (dependencies { … })
implementation(files("libs/musickitauth-release-1.1.2.aar"))
implementation(files("libs/mediaplayback-release-1.1.1.aar"))

// REQUIRED transitive deps the AARs assume but don't declare:
implementation("androidx.appcompat:appcompat:1.7.0")   // auth activities extend AppCompatActivity
```

Notes / verified facts:

- **`androidx.appcompat` is mandatory** — `StartAuthenticationActivity` and
  `SDKUriHandlerActivity` both `extends androidx.appcompat.app.AppCompatActivity`
  (javap of `musickitauth…/classes.jar`). Add it to
  `gradle/libs.versions.toml` as a versioned lib for house-style, e.g.
  `androidx-appcompat = { group = "androidx.appcompat", name = "appcompat", version = "1.7.0" }`.
- **ABI filter (optional but honest).** The playback `.so` are arm-only (fact 0.2).
  Leaving the default ABI set is fine (the app still installs on x86_64; only the
  AM full-track path is unavailable there). If you add an `ndk { abiFilters }`,
  include at least `arm64-v8a` so real devices work; do **not** filter arm out.
- **ProGuard/R8.** Release builds are currently `isMinifyEnabled = false`
  (`android/app/build.gradle.kts:22`), so the consumer ProGuard rules in
  `mediaplayback…aar/proguard.txt` (keep `CatalogPlaybackQueueItemProvider`
  CREATOR/serialVersionUID, the `ReportingService`s, the JNI `native` methods,
  `org.bytedeco.javacpp.**`) are inert today. **When minify is turned on later,
  those rules ride in automatically via the AAR** (consumer rules) — no manual
  copy needed, but verify `CatalogPlaybackQueueItemProvider` (Parcelable +
  Externalizable) survives shrinking.
- **minSdk.** Both AARs declare `minSdkVersion 21` / `targetSdkVersion 28`
  (bundled manifests) — well under the app's `minSdk 35`
  (`android/app/build.gradle.kts:13`). No `uses-sdk` override needed.
- **compileSdk 36 vs SDK's targetSdk 28.** Fine — the app's `targetSdk 36`
  governs runtime behavior; the manifest patch in §2 is what reconciles the
  Android-12+ exported-activity rule.

**[EMU-OK]** the project **compiles and assembles** with the AARs wired (verify
`./gradlew :app:assembleDebug` and the existing 234-test unit suite still passes:
`cd android && ./gradlew test`).

---

## 2. AndroidManifest patch

Add to `android/app/src/main/AndroidManifest.xml` inside `<application>`
(alongside the existing `MainActivity` + `PlaybackService`,
`AndroidManifest.xml:16-34`):

```xml
<!-- REQUIRED on Android 12+ or the manifest merge fails: the library declares
     this activity with an <intent-filter> but no explicit android:exported.
     Handles the musicsdk://<applicationId>/authenticateresult… deep-link back
     from the Apple Music app after sign-in. -->
<activity
    android:name="com.apple.android.sdk.authentication.SDKUriHandlerActivity"
    android:exported="false" />
```

Facts (from `musickitauth…aar/AndroidManifest.xml`):

- The library's own declaration carries the deep-link filter:
  `scheme="musicsdk"`, `host="${applicationId}"`, `pathPattern="/authenticateresult.*"`,
  categories `DEFAULT` + `BROWSABLE`, `launchMode="singleTask"`. Our override
  merges by activity name; keep our override **attribute-only**
  (`exported="false"`) so the merger keeps the library's `<intent-filter>`.
- `${applicationId}` resolves to **`com.levi.pocketdj`**
  (`android/app/build.gradle.kts:11`). The redirect URI the SDK builds is
  therefore `musicsdk://com.levi.pocketdj/authenticateresult…`. Nothing to
  configure — it is derived from `applicationId`.
- `StartAuthenticationActivity` is declared by the library **without** an
  intent-filter and does not need re-declaration (no exported-flag break).
- The playback AAR contributes two `<service>`s (`ReportingService`,
  `ReportingServiceApi26`, both `exported="false"`) and `INTERNET` / `WAKE_LOCK` /
  `ACCESS_NETWORK_STATE` permissions via manifest-merge — **no action needed**
  (`INTERNET`/`WAKE_LOCK` already present, `AndroidManifest.xml:4,7`).

**[EMU-OK]** the merged manifest builds; **[DEVICE-ONLY]** the deep-link round-trip
only fires when a real Apple Music app redirects back.

---

## 3. `MusicKitAuth` wrapper — developer token in, Music User Token out

New file `data/applemusic/MusicKitAuth.kt`. Wraps the SDK's auth surface and
persists the Music User Token.

### 3.1 SDK surface (exact, from javap)

`musickitauth-release-1.1.2.aar`:

```java
// AuthenticationFactory
public static AuthenticationManager createAuthenticationManager(Context);

// AuthenticationManager (interface)
AuthIntentBuilder createIntentBuilder(String developerToken);
TokenResult       handleTokenResult(Intent);

// AuthIntentBuilder
AuthIntentBuilder(Context, String developerToken);   // or via createIntentBuilder
AuthIntentBuilder setHideStartScreen(boolean);
AuthIntentBuilder setStartScreenMessage(String);
AuthIntentBuilder setContextId(String);
AuthIntentBuilder setCustomParams(HashMap);
Intent            build();

// TokenResult
boolean     isError();
TokenError  getError();
String      getMusicUserToken();

// TokenError (enum): USER_CANCELLED, NO_SUBSCRIPTION, SUBSCRIPTION_EXPIRED,
//                    TOKEN_FETCH_ERROR, UNKNOWN;  int getErrorCode()
```

### 3.2 Flow (canonical, mirrors Apple's Android sample)

1. **Build the intent** with the developer token from §5:
   ```kotlin
   val authManager = AuthenticationFactory.createAuthenticationManager(context)
   val intent: Intent = authManager
       .createIntentBuilder(developerToken)      // MUST be a valid ES256 dev token
       .setHideStartScreen(false)
       .setStartScreenMessage("Connect Apple Music to stream your library in PocketDJ")
       .build()
   ```
2. **Launch it for result.** Use the AndroidX Activity Result API
   (`ActivityResultContracts.StartActivityForResult`) from `MainActivity` (the
   single activity) — the SDK opens `StartAuthenticationActivity`, which deep-links
   into the Apple Music app; the app redirects back through `SDKUriHandlerActivity`
   (§2), which finishes the result. **[DEVICE-ONLY]** — requires the Apple Music
   app + an active subscription.
3. **Decode the result** in the launcher callback:
   ```kotlin
   val result: TokenResult = authManager.handleTokenResult(data)   // data = ActivityResult.data
   if (result.isError) {
       when (result.error) {
           TokenError.NO_SUBSCRIPTION, TokenError.SUBSCRIPTION_EXPIRED -> …  // offer preview-only
           TokenError.USER_CANCELLED -> …                                    // silent
           else -> …                                                          // TOKEN_FETCH_ERROR / UNKNOWN → retry
       }
   } else {
       val musicUserToken = result.musicUserToken   // PERSIST this (§3.3)
   }
   ```

### 3.3 Persistence (additive-optional, `AppSettingsStore`)

Add independent Preferences keys (pattern: `data/settings/AppSettingsStore.kt:100-136`):

| Field | Key | Default | Meaning |
|---|---|---|---|
| `musicUserToken` | `musicUserToken` (String) | `""` | the per-user token; empty ⇒ signed out |
| `appleMusicSignedIn` | derived: `musicUserToken.isNotBlank()` | — | drives Settings status + backend gating |

Add `setMusicUserToken(token: String)` and `clearMusicUserToken()` (sign-out)
methods, each a single `dataStore.edit { … }` (atomic). Expose
`hasAppleMusic: Boolean get() = musicUserToken.isNotBlank()` on `AppSettings`
(mirror `hasRipServer`, `AppSettingsStore.kt:60`).

**Sign out** = `clearMusicUserToken()` + tell `AppleMusicBackend` to
`stop()`/`release()` its controller. The developer token is app-wide and is **not**
cleared on sign-out (it is not user-identifying).

**[EMU-OK]** the wrapper's construction, intent-building, error mapping, and
persistence are all unit/emulator testable with a stub dev token; **[DEVICE-ONLY]**
the token round-trip.

---

## 4. Rip server: `GET /musickit-token` (server-side ES256 minting)

New endpoint in `scripts/rip-server.mjs`. **Dependency-free** — the server already
imports only `node:*` (`scripts/rip-server.mjs:19-26`); ES256 is done with
`node:crypto` (no `jsonwebtoken`/`jose`). The repo has **no** existing ES256 signer
(`scripts/es-index.mjs` is SigV4/HMAC only, `es-index.mjs:66-99`), so this is new.

### 4.1 Config

Add to `CFG` (near `scripts/rip-server.mjs:48-75`):

```js
musicKitKeyPath: (process.env.MUSICKIT_P8 ||
  join(homedir(), '.appstoreconnect', 'private_keys', 'AuthKey_9JRN4H68X4.p8')).replace(/^~/, homedir()),
musicKitKeyId:  process.env.MUSICKIT_KID  || '9JRN4H68X4',
musicKitTeamId: process.env.MUSICKIT_TEAM || 'EC27UF79GL',
musicKitTtlSec: parseInt(process.env.MUSICKIT_TTL_SEC || String(150 * 24 * 3600), 10), // 150 d ≤ 6 mo cap
```

The key is **VERIFIED 200 against `api.music.apple.com`** with kid `9JRN4H68X4`,
team `EC27UF79GL`. Apple's hard cap on the dev-token `exp` is **6 months** from
`iat`; keep `musicKitTtlSec ≤ 15777000`. Default 150 days leaves headroom.

### 4.2 ES256 minter (add near the other helpers, before the router)

```js
import { createSign, createPrivateKey, sign as cryptoSign } from 'node:crypto';
const b64url = (buf) => Buffer.from(buf).toString('base64')
  .replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_');

let _mkCache = null; // { token, exp }  in-memory, rotates
function mintMusicKitToken() {
  const now = Math.floor(Date.now() / 1000);
  // Re-use a cached token until it has < 7 days left, then rotate.
  if (_mkCache && _mkCache.exp - now > 7 * 24 * 3600) return _mkCache;
  const exp = now + CFG.musicKitTtlSec;
  const header  = { alg: 'ES256', kid: CFG.musicKitKeyId, typ: 'JWT' };
  const payload = { iss: CFG.musicKitTeamId, iat: now, exp };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = createPrivateKey(readFileSync(CFG.musicKitKeyPath));
  // ES256 = ECDSA-P256-SHA256 with JOSE raw (r‖s) signature, NOT DER.
  const sig = cryptoSign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' });
  const token = `${signingInput}.${b64url(sig)}`;
  _mkCache = { token, exp };
  return _mkCache;
}
```

> `dsaEncoding: 'ieee-p1363'` is load-bearing: without it Node emits a DER
> signature and Apple rejects the JWT (401). ES256 requires the fixed-length
> `r‖s` (64-byte) form.

### 4.3 Route

Place it **after the global auth gate** (`scripts/rip-server.mjs:1977`, so tokened
servers require the bearer and tokenless servers answer — same posture as every
app feature), **not** in `ADMIN_PATHS` (`rip-server.mjs:1945-1949`). Model on the
`/health` handler (`rip-server.mjs:1964-1967`) and the `send()` helper
(`rip-server.mjs:1890-1899`):

```js
if (path === '/musickit-token' && req.method === 'GET') {
  try {
    const { token, exp } = mintMusicKitToken();
    return send(res, 200, { token, expiresAt: exp * 1000, ttlSec: CFG.musicKitTtlSec });
  } catch (e) {
    return send(res, 500, { error: 'musickit key unavailable' }); // .p8 missing / unreadable
  }
}
```

Response contract:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{ "token": "<ES256 JWT>", "expiresAt": <epoch-ms>, "ttlSec": <int> }` | mint/cached OK |
| 401 | `{ "error": "unauthorized" }` | tokened server, bad/missing bearer (`rip-server.mjs:1977`) |
| 500 | `{ "error": "musickit key unavailable" }` | `.p8` not present on this server host |

Auth headers are the **same as every rip endpoint** (`Authorization: Bearer`
omitted when empty; `X-PocketDJ-Device` always sent) — reuse `RipServerClient`'s
header builder (`data/rips/RipServerClient.kt:174-182`).

**[EMU-OK]** minting + fetching + JWT shape can be verified locally
(`curl localhost:8787/musickit-token`, decode the JWT header/payload, confirm
ES256/kid/iss/exp ≤ 6 mo). The 200-against-Apple check is already done.

---

## 5. Dev-token client (app side)

New file `data/applemusic/MusicKitDeveloperTokenClient.kt`. Fetches + caches the
developer token from the **already-configured rip server** (Settings ▸ Import
server, `AppSettingsStore.kt:38-39,190-195`). Model on `RipServerClient`
(`data/rips/RipServerClient.kt`) — reuse its `Config` (baseUrl/token/installId),
its normalized-base + header rules (`RipServerClient.kt:37-45,168-182`), and its
12-second short-timeout doctrine (`RipServerClient.kt:49-51`).

```kotlin
class MusicKitDeveloperTokenClient(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    private val configProvider: suspend () -> RipServerClient.Config,
) {
    @Serializable data class TokenResponse(val token: String, val expiresAt: Long? = null, val ttlSec: Long? = null)

    @Volatile private var cached: TokenResponse? = null

    /** Returns a valid dev token, refetching when absent or within 24 h of expiry. */
    suspend fun developerToken(): String { … }   // GET {base}/musickit-token
}
```

Rules:

- **Endpoint:** `GET {normalizedBase}/musickit-token` (build with
  `RipServerClient`'s `url(config, "musickit-token")`, `RipServerClient.kt:168-172`).
- **Auth:** same header builder — bearer omitted when the rip token is empty
  (`RipServerClient.kt:174-182`).
- **Cache in memory** (and optionally persist to a DataStore key
  `appleMusicDeveloperToken` for cold-start), refetch when
  `expiresAt - now < 24 h` — the SDK's `TokenProvider.getDeveloperToken()` is
  called synchronously per playback, so it must return a **pre-fetched** value
  (fetch ahead on sign-in and at app launch when signed in; never block the SDK
  callback on the network).
- **No rip server configured** ⇒ no dev token ⇒ AM sign-in and full-track are
  unavailable; Settings shows the "configure Import server first" affordance
  (§7). This is intentional: the token source IS the rip server.

**[EMU-OK]** entirely — fetch, cache, expiry logic all run on the emulator against
a reachable rip server (or a `MockWebServer`, the pattern already used in tests,
`android/app/build.gradle.kts` `okhttp-mockwebserver`).

---

## 6. Playback backends behind `PlaybackController`

Two new backends slot **into the existing resolution ladder**
(`specs/playback.md §3`, `PlaybackController.play`,
`playback/PlaybackController.kt:149-184`). Today the Android ladder is:
manifest-hit → rip-on-demand → metadata-only (`data/rips/PlayResolver.kt:48-70`).
AM inserts a rung, mirroring iOS provider ordering
(`PlaybackCoordinator.swift:89-100`: AM streaming **first** for AM-sourced songs
when ready, rip server **always** the terminal fallback).

### 6.0 New Android ladder (for a song with `appleMusicId` set)

```
resolve(songId):
  0. (later phase) local burn                          — not in this addendum
  1. manifest[songId] != null   → ExoPlayer stream (rips) + analog clip  [unchanged]
  2. appleMusicId != null AND signed-in AND on-device AND arm ABI
                                → AppleMusicBackend (full-track DRM)   [DEVICE-ONLY]
  3. appleMusicId != null AND (signed-out OR emulator OR no dev token)
                                → PreviewBackend (30 s preview via ExoPlayer) [EMU-OK]
  4. rip server configured      → POST /rip (rip-on-demand)            [unchanged]
  5. else                       → metadata-only                        [unchanged]
```

Ordering rationale (parity): a track that is **already a public rip** stays on the
fast ExoPlayer path (rung 1 before AM) — the rip is durable, seekable, and free of
DRM/subscription requirements. AM is preferred over rip-on-demand (rung 2/3 before
rung 4) for AM-sourced catalog songs, exactly as iOS prefers the AM provider over
the terminal rip provider (`PlaybackCoordinator.swift:95-98`). Keep the whole
ladder behind one resolver function so rungs reorder cleanly
(`specs/playback.md §5` "keep the resolution ladder behind one function").

> **Do NOT auto-fire `/rip` for AM playback on Android.** iOS fires a
> fire-and-forget `/rip` when AM playback starts (`PlaybackCoordinator.swift:147-150`)
> — and even the iOS code flags that as guideline-5.2.3-risky (`#TOUPDATE`
> comments, `PlaybackCoordinator.swift:132-146`). Android already codifies "no
> auto-rip; `/rip` only on explicit ▶" (`specs/playback.md §3`). **Keep it that
> way** — AM playback here does not POST `/rip`.

### 6.1 `AppleMusicBackend` (full-track, [DEVICE-ONLY])

New file `playback/AppleMusicBackend.kt`. Wraps the SDK's
`MediaPlayerController` — a **separate audio engine** from ExoPlayer.

SDK surface (exact, from javap of `mediaplayback…aar`):

```java
// MediaPlayerControllerFactory
static MediaPlayerController createLocalController(Context, TokenProvider);
static MediaPlayerController createLocalController(Context, Handler, TokenProvider);

// TokenProvider (interface) — YOU implement it:
String getDeveloperToken();   // §5 cached ES256 token (pre-fetched, non-blocking)
String getUserToken();        // §3.3 persisted Music User Token

// Queue: build catalog ids into a provider
CatalogPlaybackQueueItemProvider.Builder()
    .items(int mediaType, String... storeIds)          // mediaType = MediaItemType.SONG
    .containers(int containerType, String... storeIds)  // e.g. MediaContainerType.ALBUM
    .startItemIndex(int).shuffleMode(int)
    .build()  // → PlaybackQueueItemProvider

// MediaPlayerController (interface) — transport we drive:
void prepare(PlaybackQueueItemProvider);
void prepare(PlaybackQueueItemProvider, boolean playWhenReady);
void play(); void pause(); void stop(); void seekToPosition(long);
void skipToNextItem(); void skipToPreviousItem();
int  getPlaybackState();       // PlaybackState.STOPPED|PLAYING|PAUSED
long getCurrentPosition(); long getDuration();  // DURATION_UNKNOWN / POSITION_UNKNOWN sentinels
boolean isLiveStream(); boolean canSeek();
void addListener(MediaPlayerController.Listener);
void removeListener(MediaPlayerController.Listener);
void release();

// MediaPlayerController.Listener — state → PlaybackController.nowPlaying:
void onPlaybackStateChanged(controller, int prev, int now);
void onPlaybackStateUpdated(controller);
void onCurrentItemChanged(controller, PlayerQueueItem prev, PlayerQueueItem next);
void onItemEnded(controller, PlayerQueueItem, long);
void onBufferingStateChanged(controller, boolean);
void onPlaybackError(controller, MediaPlayerException);  // getType(): TYPE_DRM / TYPE_IO / …

// PlayerQueueItem.getItem() → PlayerMediaItem: getTitle(), getArtistName(),
//   getAlbumTitle(), getSubscriptionStoreId(), getArtworkUrl(int w,int h), getDuration()
```

Construction + play:

```kotlin
val tokenProvider = object : TokenProvider {
    override fun getDeveloperToken() = devTokenClient.cachedTokenOrThrow()  // pre-fetched
    override fun getUserToken()       = settings.current().musicUserToken   // may be "" → preview instead
}
val controller = MediaPlayerControllerFactory.createLocalController(appContext, tokenProvider)
controller.addListener(bridgeListener)

// Play one AM song by its Apple store id (the catalog's appleMusicId, NOT our songId):
val provider = CatalogPlaybackQueueItemProvider.Builder()
    .items(MediaItemType.SONG, appleMusicId)
    .build()
controller.prepare(provider, /* playWhenReady = */ true)
```

Integration rules:

1. **Single-owner switching (mirror `PlaybackCoordinator.swift:117-118`).** Before
   `AppleMusicBackend` plays, **stop ExoPlayer** (via the existing
   `PlaybackController.stop()` path / MediaController). Before ExoPlayer plays,
   **stop the AM controller** (`controller.stop()`). `PlaybackController` owns an
   `activeBackend: {EXO, APPLE_MUSIC}?` field (the Android analogue of
   `PlaybackCoordinator.activeBackend`, `PlaybackCoordinator.swift:61`). Never let
   both engines run.
2. **`nowPlaying` unification.** The `MediaPlayerController.Listener` callbacks
   map into the SAME `PlaybackController.NowPlayingInfo` StateFlow
   (`PlaybackController.kt:87-101`) so the mini-player / Now Playing surfaces are
   backend-agnostic. `songId` = our catalog songId (kept alongside the AM store id
   when we queued it); `isLive = false`; `durationMs` from
   `controller.getDuration()` (guard `DURATION_UNKNOWN`); `isPlaying` from
   `getPlaybackState() == PlaybackState.PLAYING`.
3. **Position ticks stay cold** (`specs/playback.md §5.5`): poll
   `controller.getCurrentPosition()` in the scrubber composable only; do not push
   it through a hot StateFlow.
4. **History parity.** The existing single recording site is
   `PlaybackService.onMediaItemTransition` (ExoPlayer only,
   `PlaybackService.kt:44-78`). AM playback does **not** flow through ExoPlayer, so
   `AppleMusicBackend` must emit the same `PlayStarted` into `PlayEventBus`
   (`playback/PlayEvents.kt`) on `onCurrentItemChanged` behind the same
   id-changed gate (mirror `PlaybackService.kt:28,56-77`). One play → one History
   row, whichever engine.
5. **Media notification / lock-screen (device-only polish, later slice).** The SDK
   ships a `ReportingService` but **no** Media3 `MediaSession` bridge, so the
   system media notification does not come for free on the AM path (it does for
   ExoPlayer via `PlaybackService`, `PlaybackService.kt:89-92`). Acceptable first
   cut: in-app transport only for AM full-track; a `MediaSession` that reflects the
   AM controller is a **follow-up** (note it, don't block on it). This is
   [DEVICE-ONLY] anyway.
6. **Errors.** `onPlaybackError` `MediaPlayerException.getType()`:
   `TYPE_DRM` (usually no/expired subscription or unsupported device) and any
   error on x86_64 (native lib absent) ⇒ **fall through to `PreviewBackend`**
   (rung 3) rather than surfacing a dead end. Surface a user message only if the
   preview also fails (mirror the rip provider's "terminal error is the actionable
   one", `PlaybackCoordinator.swift:154-159`).
7. **Lifecycle.** Create the controller lazily on first AM play; `release()` it on
   sign-out and on app teardown (it holds native resources). One controller
   instance, reused.

**[DEVICE-ONLY]** every runtime behavior here (native engine, DRM, real tokens).
On the emulator, rung 2 is skipped by the ABI/sign-in guard and playback lands on
`PreviewBackend`.

### 6.2 `PreviewBackend` (30 s previews via ExoPlayer, [EMU-OK])

Previews are plain progressive audio URLs — **no Music User Token, no DRM, no
native SDK**. Play them through the **existing ExoPlayer** path
(`PlaybackService`/`PlaybackController`), i.e. build a normal `MediaItem` with the
preview URL as `EXTRA_URL` (`playback/PlaybackContract.kt:14`) and no clip window.
Reuse `PlaybackController.mediaItem(...)`/`setQueueAndPlay(...)`
(`PlaybackController.kt:380-425`) unchanged — the preview is just another stream
URL to ExoPlayer.

- Mark preview now-playing so the UI can badge it ("Preview · 30s") and cap the
  scrubber — add an `EXTRA_IS_PREVIEW` boolean to `PlaybackContract`
  (`PlaybackContract.kt`) alongside `EXTRA_IS_LIVE`, surfaced on `NowPlayingInfo`.
- No auto-advance semantics beyond ExoPlayer's natural end (30 s files end
  themselves; no analog clip math applies).

### 6.3 Resolving a preview URL

The catalog `IndexSong` carries **`appleMusicId` but no preview URL**
(`data/catalog/IndexModels.kt:99-120`), so previews are resolved on demand:

- **Primary (dev token, [EMU-OK]):** `GET
  https://api.music.apple.com/v1/catalog/{storefront}/songs/{appleMusicId}` with
  header `Authorization: Bearer <developerToken>` (§5). Read
  `data[0].attributes.previews[0].url`. Needs **only the developer token** — no
  Music User Token, no DRM — so it works signed-out and on the emulator. Default
  `storefront = "us"`; when signed in, the Music User Token's storefront is more
  accurate but "us" is an acceptable P2 default.
- **Alt (tokenless):** `GET https://itunes.apple.com/lookup?id={appleMusicId}` →
  `results[0].previewUrl`. Needs **no token at all**; the rip server already
  proxies iTunes lookup for Discover (`scripts/rip-server.mjs:2070-2074`,
  `CFG.lookupBase`), so a `/album-tracks`-style proxy is available if direct
  iTunes calls are undesirable. Handy as the zero-config emulator path.

Cache resolved preview URLs in memory keyed by `appleMusicId` (they are stable
enough for a session).

---

## 7. Settings — "Sign in with Apple Music"

Add a new section to `screens/settings/SettingsScreen.kt` (between "Import server"
and "Jukebox broker", `SettingsScreen.kt:191-295`), styled with the existing
`SectionHeader`/`SettingsCaption`/`SectionDivider` helpers
(`SettingsScreen.kt:420-446`).

States and controls:

| Condition | UI |
|---|---|
| Rip server **not** configured (`!settings.hasRipServer`, `AppSettingsStore.kt:60`) | Disabled "Sign in with Apple Music" + caption "Add an Import server first — it mints the Apple Music developer token." |
| Server configured, **signed out** (`musicUserToken == ""`) | Enabled **"Sign in with Apple Music"** button → launches §3.2 auth. Caption notes it opens the Apple Music app and needs an active subscription. |
| Signing in | Spinner ("Connecting…"), like the rip "Testing…" affordance (`SettingsScreen.kt:259`). |
| **Signed in** (`hasAppleMusic`) | Status row "Apple Music · Connected" + **"Sign out"** (`OutlinedButton`) → `clearMusicUserToken()` + `AppleMusicBackend.release()`. |
| Error | Map `TokenError` to a caption: `NO_SUBSCRIPTION`/`SUBSCRIPTION_EXPIRED` → "No active Apple Music subscription — previews still play."; `USER_CANCELLED` → silent; else → "Sign-in failed, try again." |

Behavior:

- The button's `onClick` fetches the developer token (§5) first (so a
  server/token failure surfaces before launching Apple Music), then builds +
  launches the auth intent (§3.2) via the `MainActivity` result launcher. Because
  the launcher lives on the activity, expose a small callback/shared VM the
  Settings screen calls (the app already reaches singletons via
  `AppGraph.get(context)`, `SettingsScreen.kt:67`).
- On success, persist the Music User Token (§3.3) and pre-warm the dev token cache
  (§5) so the first AM play is instant.
- **[EMU-OK]:** the section renders, the disabled/enabled gating, the dev-token
  fetch, and the error captions are all emulator-verifiable (drive with a
  reachable/mock rip server). **[DEVICE-ONLY]:** tapping through to a real
  connected state (the Apple Music app round-trip).

---

## 8. Wiring (`AppGraph`)

Add lazily-constructed singletons to `di/AppGraph.kt` (pattern:
`AppGraph.kt:86-106`), reusing the shared `httpClient` (`AppGraph.kt:51-54`) and
the same `configProvider` the rip client uses (`AppGraph.kt:88-96`):

```kotlin
val musicKitDevTokenClient by lazy {
    MusicKitDeveloperTokenClient(http = httpClient, json = json,
        configProvider = { /* same Config as ripServerClient, AppGraph.kt:89-96 */ })
}
val musicKitAuth by lazy { MusicKitAuth(appContext, settings, musicKitDevTokenClient) }
val appleMusicBackend by lazy {
    AppleMusicBackend(appContext, settings, musicKitDevTokenClient, playEvents = PlayEventBus)
}
```

Then thread `appleMusicBackend` + `musicKitDevTokenClient` (for previews) into
`PlaybackController` (`AppGraph.kt:99-106`, `PlaybackController` constructor
`PlaybackController.kt:78-85`) so the ladder in §6.0 can reach both. Pre-warm the
dev token at launch when signed in (alongside the existing launch wiring in
`AppGraph`/activity, `AppGraph.kt:31-36` doc).

---

## 9. What ships now vs. later; verifiability matrix

| Piece | Ships now | Verify |
|---|---|---|
| §1 Gradle: two AARs + appcompat wired, app assembles | ✅ | **[EMU-OK]** `./gradlew :app:assembleDebug`; 234-test suite green (`./gradlew test`) |
| §2 Manifest `SDKUriHandlerActivity exported=false` | ✅ | **[EMU-OK]** merged-manifest build |
| §4 `GET /musickit-token` ES256 minter on rip server | ✅ | **[EMU-OK]** `curl …/musickit-token`, decode JWT (ES256/kid/iss/exp), 200-vs-Apple already proven |
| §5 dev-token client (fetch + cache + expiry) | ✅ | **[EMU-OK]** against reachable/mock rip server |
| §6.2/§6.3 `PreviewBackend` + preview URL resolution (ExoPlayer) | ✅ | **[EMU-OK]** play a 30 s preview for an `appleMusicId` song |
| §7 Settings sign-in section (states, gating, error copy) | ✅ | **[EMU-OK]** render + disabled/enabled + dev-token fetch; **[DEVICE-ONLY]** the connected end-state |
| §3 `MusicKitAuth` wrapper (intent build, result decode, persist) | ✅ | **[EMU-OK]** construction/decode/persist with stub; **[DEVICE-ONLY]** real token round-trip |
| §6.1 `AppleMusicBackend` full-track (DRM) | ✅ (code) | **[DEVICE-ONLY]** real sign-in + arm device; emulator falls through to preview |
| AM media notification / lock-screen `MediaSession` bridge | ⏭ later slice | device-only; SDK has no free bridge (§6.1.5) |
| Storefront from Music User Token (vs "us" default) | ⏭ later | preview accuracy polish (§6.3) |
| Local-burn rung 0 / offline AM | ⏭ later phase | out of scope (`specs/playback.md §5` burns cut) |

---

## 10. Risks / watch-items

1. **SDK age (Dec 2021, targetSdk 28).** The AARs predate Android 12–16. The known
   break is the §2 exported-activity rule; watch also for `WebView`/appcompat theme
   assumptions in `StartAuthenticationActivity`. If the auth UI misbehaves on
   API 35/36, that is where to look. No source, so fixes are manifest/theme-level
   only.
2. **Emulator dead-end for the headline feature.** The *point* of this work —
   full-track AM playback — is **[DEVICE-ONLY]** (fact 0.2). Emulator verification
   proves build + Settings + preview + token plumbing only. A physical
   arm64 device with the Apple Music app + active subscription is required to
   verify the real sign-in and DRM playback; budget a device check before calling
   §3/§6.1 done.
3. **Two-engine coordination bugs.** The most likely runtime defect is both engines
   playing at once (double audio) or a stale `activeBackend` — the exact class of
   bug iOS guards with `activeBackend` switching. Test the ExoPlayer↔AM handoff
   explicitly (rip song → AM song → rip song).
4. **Dev-token blocking the SDK callback.** `TokenProvider.getDeveloperToken()` is
   called synchronously by the SDK; if it ever returns null/expired mid-session the
   SDK fails playback. Always keep a fresh pre-fetched token; never fetch inside the
   callback.
5. **`.p8` availability on the server host.** `GET /musickit-token` 500s if the key
   file isn't at `~/.appstoreconnect/private_keys/AuthKey_9JRN4H68X4.p8` on the
   machine running the rip server. Fine on Levi's iMac; document the
   `MUSICKIT_P8` env override for other hosts.
6. **App Review / guideline 5.2.3.** iOS already carries `#TOUPDATE` warnings that
   "AM playback → POST /rip" reads as capturing Apple Music audio
   (`PlaybackCoordinator.swift:132-150`). Android deliberately does **not** auto-rip
   on AM playback (§6.0) — keep it that way; do not port the iOS auto-rip.
7. **`FAIL_ON_PROJECT_REPOS`.** Do not "fix" the AAR wiring by adding a `flatDir`
   repo in the module — it is rejected by `settings.gradle.kts`. `implementation(files(...))`
   is the sanctioned path (§1).
8. **Preview vs full-track UX honesty.** A signed-out or unsubscribed user gets a
   30 s preview where a subscriber gets the full track — badge it clearly
   (§6.2) so the difference isn't mistaken for a bug, and don't render a
   full-track scrubber over a preview.
</content>
