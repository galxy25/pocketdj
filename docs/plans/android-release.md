# PocketDJ for Android: release plan for Play Store, sideloading and the website (reviewed)

*Written 2026-10-28 from four read-only scout reports (play, sideload, site, shots), then adversarially reviewed the same day. The review checked every repo citation against `main` @ `b6e8b25b`, checked the live endpoints, and checked Google's 2026 rules. Nothing has been edited, committed, deployed or signed up for yet.*

## 1. Summary

The Android app is in `android/`. The parity work was merged to `main` at `716983b3`, and `main` is now at `b6e8b25b`. The app is close to a build Google Play would accept:

- **Target SDK is current.** `targetSdk = 36` (`android/app/build.gradle.kts:15`) meets the Play rule for new apps and updates that took effect on 2026-08-31.
- **The Apple Music SDK's native library passes the 16 KB rule.** `libappleMusicSDK.so` is 64 KB-aligned.
- **The packaging tools are new enough.** AGP 8.9.1 already 16 KB-aligns uncompressed `.so` files inside the zip.

Six things stand between it and a public release:

1. **There is no way to sign a release build yet.**
   - `android/app/build.gradle.kts` has no `signingConfigs` block, and `versionCode = 1` / `versionName = "0.1.0"` are hardcoded (`:16-17`).
   - The only release build so far is `/Users/deepspacenine/forges/levi/pocketdj-android/android/app/build/outputs/apk/release/app-release-unsigned.apk`. It is 84.8 MB and unsigned, its dex adds up to 72.4 MB, and it contains both arm64-v8a and x86_64.
2. **One of our own native libraries fails Play's 16 KB rule.**
   - `libpdjdsp.so` LOAD alignment is 0x1000 (4 KB) in both ABIs.
   - These pass at 0x4000: `libc++_shared.so`, `liboboe.so`, `libandroidx.graphics.path.so` and `libdatastore_shared_counter.so`.
   - `libappleMusicSDK.so` passes at 0x10000.
   - All of this was measured with `llvm-readelf` on the sibling APK.
3. **Some permissions and policy points are a problem.**
   - **Background location.** `ACCESS_BACKGROUND_LOCATION` is declared at `AndroidManifest.xml:16` and requested at `screens/settings/sections/ListeningLocationSection.kt:101` (launcher) and `:182` (launch). Its stated purpose is the hint at `:50`: "notice trips between your places while music plays in the background". Google reviews this permission strictly and wants a declaration plus a video.
   - **Rip and capture paths (Play's Intellectual Property policy).** This is broader than the rip *trigger*:
     - Recognizer → rip and burn: `di/BrowseGraph.kt:527-547`.
     - The SVC-1 rip client.
     - Burn downloads from `ripsBase`. That is the green rips bucket, which holds Apple-Music-captured audio, and the remote endpoint document hands it out (`config/endpoints.green.json:7`).
     - This is "Decision A" in `docs/legal/legal-posture-conformance.md` §8 (`:2049`). The recommended option is A1, "remove it entirely". It is still undecided.
   - **Account deletion isn't wired up.** `deleteProfile()` is never called (Q54/Q66 in `android/specs/parity/QUESTIONS.md:67,80`).
   - **The `dataSync` foreground service** for burn downloads (`AndroidManifest.xml:175-178`) needs a Play declaration. Reviewers often point download apps at user-initiated data transfer jobs instead.
4. **The legal pages don't cover Android.**
   - `docs/legal/PRIVACY.md` mentions Android 0 times, and its effective date is still the template token `{{EFFECTIVE_DATE}}` (`:3`).
   - The live `https://legal.pocket-dj.com/privacy/` shows "[Publisher]" and "[Effective date pending]".
5. **Screenshots need showcase data.** Android has no fixture catalog and no showcase seeds. Without them, every screenshot would show either Levi's real library or empty screens.
6. **The website is Apple-only.**
   - `www/index.html` (694 lines) has 15 Apple screenshots in 7 groups, Apple-only wording, and a disabled "Coming soon · Android" button at `:355-357`.
   - `https://jukebox.pocket-dj.com/.well-known/assetlinks.json` returns 404 (S3 `NoSuchKey`). The manifest's App Links filter (`AndroidManifest.xml:73-82`, `autoVerify` at `:75`) needs this file to verify.

**Recommended approach**

- **Signing:** create one app-signing key that we hold ourselves, and give it to Play App Signing as "upload your own key". This is irreversible after the first Play upload. Sideloaded APKs and Play builds then carry the same signature, so users can move between them without losing data. It also means that once the Play app exists, Play's automatic registration claims the package and key for developer verification, which covers the sideloaded APK as well.
- **Two build flavors:** `play`, with no self-updater, and `direct`, with an update check against `latest.json`. Use one shared `versionCode` sequence (Unix timestamp, the same as `BUILD_NUMBER` in `apple/scripts/testflight.sh:51`).
- **Release builds ship arm64-v8a only.** The vendored `android/app/libs/mediaplayback-release-1.1.1.aar` ships only arm64-v8a and armeabi-v7a, with no x86_64.
- **Turn on R8 code shrinking.** I estimate it cuts the APK from 84.8 MB to about 25–35 MB. The figure is not measured, but the 72 MB of dex is.
- **Release order:**
  1. Signed sideload APK (low risk now, because phase 1 of developer verification does *not* cover direct sideloads; see A0).
  2. As soon as the account exists, create the Play app and upload to **internal testing**, which locks the package name, the Play App Signing choice and auto-registration.
  3. Closed testing if needed.
  4. Production with a staged rollout.
- **Website:** one Apple/Android switch for the whole page. It defaults to Apple, is remembered in `localStorage`, and loads Android images only when someone picks Android. It sits next to a new `#android` download section that reads `latest.json`.

### Needs Levi (decisions, accounts, payments, legal)

**Accounts and identity**
- [ ] **Account type and legal entity.** Recommended: an **organization** account under the **LLC** (the same entity as the green AWS account 623170744161). Not the nonprofit/TechSoup entity, which would repeat the private-benefit problem behind the 10-15 blue→green move. An organization account shows the developer's name and address publicly on the listing, so pick what address to use.
- [ ] **D-U-N-S number for the LLC** (free; can take up to 28 days; **critical path**). First check what entity Apple team `EC27UF79GL` is enrolled as. Only an Apple *organization* enrolment has a D-U-N-S, and it has to be the LLC's for it to be reused. The repo doesn't record which entity the Apple team is.
- [ ] **Pay the $25 Play Console fee**, then verify identity (government ID), contact email and phone. A Play Console account is also the registration path for developer verification of apps distributed on *and* off Play. The separate Android Developer Console is only for developers who distribute exclusively outside Play.
- [ ] **Agree to the Play Console terms.** Later, create a Play Developer API service account (JSON) if you want uploads to run headless.

**Signing**
- [ ] **Who holds the app-signing key** (irreversible):
  - (Recommended) we generate it and upload it to Play App Signing.
  - Or Google generates it, and each sideload APK is downloaded from Play's App bundle explorer. That option rules out the `direct` flavor, so there is no in-app updater, and every sideload release has to go through Play first.
- [ ] **Back up the keystore off-machine**, in the password manager plus an offline or encrypted copy, and exclude it from credsync (credsync has wiped secrets fleet-wide before). A lost app-signing key cannot be recovered. Google's FAQ is explicit that you also can't register packages without it.

**Product and policy**
- [ ] **Lock the app ID `com.levi.pocketdj`.** It can't change after the first upload.
- [ ] **Decision A: the rip server, Apple Music capture *and* rip-sourced burns.** Recommended (A1): the Play and direct builds ship with:
  - no rip server
  - no rip triggers
  - **no burn downloads of Apple-Music-sourced rips**: the release build ignores a remote `ripsBase` for AM-sourced rows, which is MUST-5's `sourceName` gate.

  MUST-5b, which deletes the capture scripts and skills, is unresolved. Ask counsel if needed.
- [ ] **Drop `ACCESS_BACKGROUND_LOCATION` from v1** and keep location foreground-only and opt-in. Recommended for both Play and sideload, because it also lowers the chance of a Play Protect warning. **Cost:** "trips between places while music plays in the background" stops working when the screen is off. That feeds pockets, and FR2's hour×weekday×mode wheel. The alternative is to add a `location` foreground-service type to `PlaybackService`, but that needs its own declaration. Levi picks which.
- [ ] **Keep `minSdk = 35`** (Android 15 and later only)? This limits how many phones can install the app.
- [ ] **Versioning:** versionName 1.0.0 and versionCode = Unix timestamp, shared across both channels.
- [ ] **Android Auto in v1?** Recommended: ship phone-only and add Auto after a real head-unit or DHU pass. SURF-8 was only checked through MediaBrowser, and SURF-9 is still planned. `res/xml/automotive_app_desc.xml` already exists, so the manifest has to be checked so it doesn't silently opt the app into Auto (see A2).
- [ ] **Tablet support:** promote it, and capture the 7" and 10" screenshot sets? Website group G1 (Mix) is an iPad image, so with no tablet shots its Android tab shows the phone Mix shot.
- [ ] **Pricing on Android:** free, paid, or in-app purchase.
  - The "One purchase" wording at `www/index.html:362` and `:575-578` has to change either way, because an Apple purchase doesn't carry over to Android.
  - If Android is paid or has in-app purchases, Play requires Play Billing for digital goods.
  - The direct APK has no payment or licensing path at all, so paid-on-Play plus free-direct undercuts the Play price.
- [ ] **Should the `direct` build upload diagnostics** (`DIAG_CHANNEL`, `build.gradle.kts:23`, currently `false`)? If yes, the privacy policy and Data safety form must say so.
- [ ] **Does profile sync ship in v1?** If yes, the profile-sync Lambda has to be deployed (Q42/Q54), sync has to be declared in Data safety, and Play's account-deletion URL rule applies. That rule applies when an app lets users create an account.
- [ ] **Do the rec engine and listening-pockets network calls ship in v1?** These are `recEngineBase` and `listeningPocketsBase` (`config/endpoints.green.json:9-10`). If yes, they go into Data safety as App activity / listening history collected.
- [ ] **ShazamKit AAR and token (Q84).** Optional: the recognizer hides itself in release builds.

**Legal**
- [ ] **Privacy policy:** publisher name, effective date, and sign-off on a new Android section.
- [ ] **Confirm the Apple MusicKit for Android SDK terms** allow distribution both on Play and as a direct APK, and find out what data the SDK itself sends to Apple. Play's Data safety form covers SDK collection.
- [ ] **Trademark lines** for Google Play and Android on the site footer (`www/index.html:616`).
- [ ] **Content rating answers (IARC).** Claude pre-fills; the likely result is Teen, because of explicit lyrics and jukebox guest requests.

**Review and devices**
- [ ] **Review screenshots, feature graphic (1024×500) and Play icon (512×512, 32-bit PNG, ≤ 1 MB).**
- [ ] **Smoke-test on a real Android 15+ arm64 phone.** Check:
  - Apple Music sign-in and playback (the release `libc++_shared.so`; see the risks table)
  - the microphone
  - the Play Protect warning
  - Samsung Auto Blocker
- [ ] **Confirm the screenshot emulator is never signed into the real Apple Music account or profile.**
- [ ] **Review the website after deploy** (standing rule: green only).

---

## 2. Phases

Rules for every phase:
- Each phase gets its own feature branch off `main`, announced up front.
- Phases are landed with the `create-pr` flow: push, ask Levi, merge locally, push.
- Verify at the committed tip, not just the working tree.
- Push before any deploy, so that `origin/main..main` is empty.
- Never run two release or ship scripts at the same time.
- Parallel agents get their own worktrees, and one agent at a time owns the Gradle build. A sibling worktree, `/Users/deepspacenine/forges/levi/pocketdj-android`, produced a release APK at 12:19 today; check with whoever owns it before building there.

Environment for every Android command:
```
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk
```

### Phase overview

| Phase | Branch | Owner | Depends on | Can land without Levi? |
|---|---|---|---|---|
| A0 Decisions and accounts | — | Levi | — | — (start D-U-N-S on day 1) |
| A1 Build config: flavors, versioning, R8, ABI, 16 KB | `feat/android-release-build` | Claude | — | Yes (signing reads from properties; unsigned until a key exists) |
| A2 Policy fixes: background location, rip/burn gate, account deletion, FGS | `feat/android-release-policy` | Claude | A0 decisions (A, location, sync) | Code yes; merge after decisions |
| A3 Signing keys and release script | `feat/android-release-signing` | Claude + Levi | A1, keystore from Levi | Script yes; real signing needs the key |
| B Sideload distribution and updater | `feat/android-sideload` | Claude | A1, A2 merged, A3 | Code yes; publishing needs the key **and A2 merged** |
| C Screenshot seeds and capture | `feat/android-store-screenshots` | Claude | none (debug-only); shots taken after A2 so no rip UI appears | Yes |
| D1 Website platform tabs | `feat/www-platform-tabs` | Claude | C (images) | Yes; Levi reviews after deploy |
| D2 Website Android download section and legal | `feat/www-android-download` | Claude + Levi | B (APK live); legal sign-off for the privacy page; assetlinks needs the A3 cert | Site yes; legal page needs sign-off |
| E Play Console | — (plus `feat/android-play-listing` for metadata) | Levi submits, Claude drafts | A0 account, A1–A3 (internal track can start as soon as these exist), C, D2 privacy page | No |
| F Post-launch | `feat/android-release-pipeline` | Claude | E | Yes |

---

### Phase A0: Decisions and accounts (Levi, start immediately)

1. **Start the D-U-N-S lookup or request for the LLC today.** It takes up to 28 days and sets the timeline for Play production on an organization account.
2. **Create the Play Console organization account.** Pay $25 and complete identity, email and phone verification.
   - With an organization account, the 12-tester, 14-day closed test does not apply.
   - A personal account created after 2023-11-13 must run that test for **each new app** before it can apply for production. Only closed-track testers count, not internal ones.
3. **Record the decisions** from the checklist above: Decision A, background location, minSdk, Auto, tablets, pricing, signing, DIAG_CHANNEL, sync and the rec network.
4. **Claude:** close Open questions 3 and 4 in `docs/ARCHITECTURE-ANDROID.md` (`:321-325`: distribution channel; assetlinks fingerprint) once Levi decides.

**Developer verification facts (official FAQ, checked 2026-10-28):**
- **Phase 1 (2026-09-30)** applies only to installs from **participating app stores** on certified devices in Brazil, Indonesia, Singapore and Thailand. **Direct sideloads and other stores are not enforced in phase 1.**
- **Global enforcement** for all apps on certified devices comes in 2027. Exact dates have not been announced.
- **ADB installs never need verification.**
- **The advanced flow** is the user's path for installing unverified apps: developer mode, an anti-coaching check, a restart, a one-day wait, then biometric or PIN confirmation. If it is later turned off, updates to unregistered apps fail.
- **Apps using Play App Signing are claimed automatically.** Use Play Console to register apps that ship only off Play. One package can have several signing keys registered.

**There is no need for a stopgap account.** Until the Play account exists, sideload to Levi's devices with `adb install`. If one is wanted anyway, a free limited-distribution account covers 20 devices with no ID and *can* be migrated to a full account later. It is an Android Developer Console account, though, not a Play account, so it is a poor fit when Play is the target.

---

### Phase A1: Make the Android build release-ready (Claude, `feat/android-release-build`)

**File:** `android/app/build.gradle.kts`

1. **Product flavors** `play` and `direct`, in one flavor dimension `channel`.
   - `direct` gets the updater code and its BuildConfig flag (`UPDATE_CHECK=true`).
   - `play` has no updater code and no `REQUEST_INSTALL_PACKAGES` permission. Play's Device and Network Abuse policy forbids self-updating outside Play.
2. **Versioning:**
   - `versionCode = (project.findProperty("versionCode") ?: "1").toString().toInt()`
   - `versionName = (project.findProperty("versionName") ?: "1.0.0-dev").toString()` (`findProperty` returns `Any?`).
   - These replace the hardcoded `versionCode = 1` and `versionName = "0.1.0"` (`:16-17`).
3. **Release ABI filter: arm64-v8a only.**
   - Today `ndk { abiFilters += listOf("arm64-v8a", "x86_64") }` sits in `defaultConfig` (`:33`).
   - **Move it out of `defaultConfig`.** Build-type `ndk.abiFilters` are *merged* with `defaultConfig`'s, so adding a release-only filter cannot remove x86_64.
   - Declare `debug { ndk { abiFilters += listOf("arm64-v8a","x86_64") } }` and `release { ndk { abiFilters += "arm64-v8a" } }`.
   - Add an opt-in `-PincludeX86=true` property that adds x86_64 back to release, for the emulator smoke test of a minified build.
   - Check the result with `unzip -l`.
   - Shipping x86_64 would give Chromebooks a copy of the app with no Apple Music.
4. **Fix 16 KB alignment for `libpdjdsp.so`** (currently 0x1000; NDK `27.2.12479018`, `:39`).
   - Add `-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` to `defaultConfig.externalNativeBuild.cmake.arguments` (`:35`, next to `-DANDROID_STL=c++_shared`).
   - Optionally, as belt and braces, add `target_link_options(pdjdsp PRIVATE "-Wl,-z,max-page-size=16384")` to `android/app/src/main/cpp/pdjdsp/CMakeLists.txt` after the `target_link_libraries` line.
   - Alternative: bump the NDK to r28 or later, which defaults to 16 KB.
5. **Turn on R8:** `isMinifyEnabled = true` and `isShrinkResources = true` for release (`:49`).
   - Write keep rules in `android/app/proguard-rules.pro`, which is a 2-line placeholder today. It needs rules for:
     - kotlinx.serialization (`@Serializable` classes and companions)
     - the Apple Music AARs. `mediaplayback-release-1.1.1.aar` ships a `proguard.txt` consumer file; `musickitauth-release-1.1.2.aar` ships **none**, so it needs explicit rules and JNI-referenced classes have to be kept.
     - Media3 (MediaLibraryService and session classes)
     - JNI entry points in `cpp/pdjdsp/jni.cpp` (keep the `native` methods and the classes they call back into)
     - zxing and OkHttp (normally covered by their own consumer rules; confirm)
   - Also consider dropping `material-icons-extended` (`android/gradle/libs.versions.toml:37`) in favour of the icons actually used. It is a large part of the 72 MB of dex.
6. **Signing config, per flavor.**
   - `signingConfigs { create("direct") {…}; create("upload") {…} }` reads `PDJ_ANDROID_*` keystore path, alias and password-file values from environment variables or `~/.gradle/gradle.properties`.
   - `directRelease` signs with the **app-signing** key and `playRelease` with the **upload** key.
   - Use them only when the properties are present, so CI and other agents can still build unsigned.

**Verification**
- Build and tests:
  - `./gradlew :app:testPlayReleaseUnitTest :app:testDirectReleaseUnitTest`. Check that the **test count** matches the ledger's latest count (`docs/ARCHITECTURE-ANDROID.md`, for example "Tests 4716 → 4722"), because a zero-tests run still exits 0.
  - `./gradlew :app:assemblePlayRelease :app:bundlePlayRelease :app:assembleDirectRelease`. Don't pipe to `tail`; check the exit code.
- APK checks:
  - `unzip -l app-*-release.apk | grep lib/`: arm64-v8a only.
  - 16 KB alignment, for **every** `.so`: `$ANDROID_HOME/ndk/*/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf -lW lib/arm64-v8a/<lib>.so | grep LOAD`. The alignment column must be 0x4000 or more.
  - Zip alignment: `zipalign -c -P 16 -v 4 app.apk`. For the AAB, use bundletool or Play's pre-launch report.
  - APK size: record the before and after numbers in the PR.
- Minified build on the emulator:
  - The `pocketdj` AVD is x86_64. Build `assembleDirectRelease -PincludeX86=true`, signed with the debug key or the local app-signing key, because an unsigned APK can't be installed.
  - Smoke-test it on emulator-5554: every tab opens, Mix plays, Studio, Collections.
  - Then run `android-test` instrumented tests against the minified build.
  - The Apple Music SDK has no x86_64 code, so AM paths can only be checked on a real arm64 device.

---

### Phase A2: Policy fixes (Claude, `feat/android-release-policy`; merge after the A0 decisions)

1. **Background location** (if dropped):
   - Remove `ACCESS_BACKGROUND_LOCATION` from `android/app/src/main/AndroidManifest.xml:16`.
   - Remove the launcher at `ListeningLocationSection.kt:101`, the launch at `:182` and the "Always" UI and hint (`:50`).
   - Keep coarse and fine location, foreground and opt-in (COL-20). Update `data/location/FusedVisitSource.kt` and `LocationSettings.kt` so they never assume a background grant.
   - Add a JVM test that asserts the merged manifest does not contain the permission.
2. **Rip and burn gate (Decision A):**
   - Release flavors **compile-time ignore** the rip-server endpoint *and* any remote `ripsBase` for Apple-Music-sourced rows. A "default unset" is not enough, because the remote endpoint document (`config/endpoints.green.json`, `docs/design/remote-endpoints.md`) supplies `ripsBase` at runtime.
   - Hide or disable every Apple-Music-sourced rip trigger:
     - the SVC-1 rip client UI
     - stream-through-rip
     - recognizer → "rip and burn" (`di/BrowseGraph.kt:527-547`; `startRipAndBurn` already returns `NO_SERVER` when the client is unconfigured)
     - Collection Rip/Burn
   - Follow the capture-gate wording in `docs/legal/PRIVACY.md`.
   - Test: a release-build config has no rip base URL, AM-sourced burns are refused, and the rip actions are absent.
3. **Account and data deletion:**
   - Wire `deleteProfile()` to a real delete (Q54/Q66): local data, Keystore tokens, and the remote S3 profile if sync ships.
   - Add a Settings ▸ Account "Delete account and data" row.
   - Play requires a **web** deletion URL when the app lets users create an account (profile sync or link-a-device). If sync doesn't ship, the deletion section can only say there is no account. Plan the page as `https://pocket-dj.com/delete-account` (or a section on `support.html`) with instructions plus a contact/request path. It ships in Phase D2.
4. **Foreground service types:**
   - Declared today: `mediaPlayback` (`PlaybackService`, manifest `:138`, permission `:8`) and `dataSync` (WorkManager `SystemForegroundService`, manifest `:175-178`, permission `:17`).
   - Keep a short justification paragraph for each, for the Console declarations in Phase E.
   - `dataSync` has a 6-hour daily limit on Android 15+, and Play reviewers may push downloads toward **user-initiated data transfer jobs**. Decide whether to switch burn downloads to UIDT before submission, or to justify `dataSync`.
5. **ACTIVITY_RECOGNITION:** keep it absent in v1. FR2 (the running/walking pocket wheel in the queued work) would add it later, along with a Data safety update.
6. **Android Auto opt-in:** if Auto is not in v1, make sure the release manifest does not declare `com.google.android.gms.car.application` → `res/xml/automotive_app_desc.xml`. Otherwise the app is submitted as an Auto app and reviewed against the car quality guidelines.
7. **Apple Music token in release builds:** check that the server-issued developer token (`data/applemusic/MusicKitDeveloperTokenClient.kt`) works in a minified, non-debug build, and that the Music-User-Token stays in the Keystore. The sideload scout left this unverified; it has to be checked on a real arm64 device.

**Verification:**
- `android-test` on JVM and instrumented.
- On the emulator, Settings shows no "Always" location prompt and no rip entry points.
- Run `aapt2 dump permissions app.apk` (and the manifest's `<meta-data>`) and diff it against an expected list, checked in as `android/specs/release/permissions.txt`.

---

### Phase A3: Signing keys and release script (Claude and Levi, `feat/android-release-signing`)

1. **Levi, with Claude driving the commands:** generate two keys in `~/.config/pocketdj/android/`. That directory sits next to the existing `ci-keychain-pass`, `ci-signing`, `asc.env` and `backup`.
   ```
   keytool -genkeypair -v -keystore ~/.config/pocketdj/android/pocketdj-app-signing.jks \
     -alias pocketdj -keyalg RSA -keysize 4096 -validity 11000
   keytool -genkeypair -v -keystore ~/.config/pocketdj/android/pocketdj-upload.jks \
     -alias upload -keyalg RSA -keysize 4096 -validity 11000
   ```
   - The validity of about 30 years meets Play's "valid past 2033-10-22" rule.
   - Store the passwords the way `~/.config/pocketdj/ci-keychain-pass` is stored (pocketdj-ci keychain).
   - Write `~/.config/pocketdj/android-release.env` with the keystore paths, aliases and password-file path.
   - **Levi backs up both keystores off-machine and excludes them from credsync.** Check whether the existing `~/.config/pocketdj/backup` is inside credsync's scope.
2. **Claude:** record the app-signing certificate's SHA-256 (`keytool -list -v` / `apksigner verify --print-certs`) as a pinned constant in the release script. Record it in the D2 `assetlinks.json` too.
3. **Claude:** write `android/scripts/release.sh`, modeled on `apple/scripts/testflight.sh`. There is no `android/scripts/` folder yet.
   - Preflight:
     - the environment is set
     - the keystore exists
     - the tree is clean
     - the branch is `main` and `origin/main..HEAD` is empty
     - a lockfile shows no other Android or Apple release is running.
   - Versions: `VERSION_CODE=${VERSION_CODE:-$(date +%s)}` (stays under Play's 2,100,000,000 limit until about mid-2036). `VERSION_NAME` comes from an argument or a git tag.
   - Modes:
     - `--direct`: `assembleDirectRelease` (the sideload APK, signed with the app-signing key)
     - `--play`: `bundlePlayRelease` (an AAB signed with the **upload** key).
   - Post-build checks:
     - `apksigner verify --print-certs`: the fingerprint equals the pinned value. For the AAB, check the upload cert with `jarsigner -verify -verbose -certs`.
     - `aapt2 dump badging`: package and versionCode match
     - arm64 only
     - 16 KB alignment passes
     - size under a cap of 60 MB.
   - Ends by printing `==> Done <versionName> (<versionCode>)`.
4. **Claude:** add an `android-publish` skill doc, the sibling of `apple-publish`, describing the release script, the key custody and the never-run-two-at-once rule.

**Verification:**
- A signed `directRelease` APK installs over a previous signed build with `adb install -r` on a real arm64 device without a signature error, and data survives the update. The emulator needs the `-PincludeX86` variant.
- `apksigner verify` passes with v2 and v3 signatures. v1 is not needed at minSdk 35.

---

### Phase B: Sideload APK distribution (Claude, `feat/android-sideload`)

**Hosting:** the existing www distribution. No new infrastructure is needed.
- Bucket `pocketdj-www-623170744161` and CloudFront `ELX7JB4JIT29F`, with profile `llc`.
- Load them with `POCKETDJ_ENV=green source scripts/lib/aws-env.sh`, which sets `PDJ_WWW_BUCKET` at `:56` and `PDJ_CF_WWW` at `:62`. Never use the blue values at `:20`/`:26`.
- The distribution's origin is S3 REST with origin access control (OAC `E1RH3HKBPJNLBR`), confirmed.

**Objects:**

| Path | Headers |
|---|---|
| `/android/PocketDJ-<ver>-<code>.apk` | `Content-Type: application/vnd.android.package-archive` (set explicitly), `Cache-Control: public, max-age=31536000, immutable`, `Content-Disposition: attachment; filename="PocketDJ-<ver>.apk"` |
| `/android/PocketDJ-<ver>-<code>.apk.sha256` | `sha256sum` format |
| `/android/PocketDJ.apk` | server-side `aws s3 cp` of the latest versioned object, with **explicit** `--metadata-directive REPLACE --content-type … --cache-control max-age=300` (a copy doesn't change headers otherwise) |
| `/android/latest.json` | `Content-Type: application/json`, `max-age=60` |

Because the origin is S3 REST with OAC, S3 website redirects can't serve the "latest" link. A copied object (or optionally a CloudFront Function 302) does.

The scouts proposed both `version.json` and `latest.json`. **Use one file, `/android/latest.json`**, for both the website and the in-app updater:
```json
{"versionCode":N,"versionName":"1.0.0","apk":"https://pocket-dj.com/android/PocketDJ-1.0.0-N.apk",
 "sha256":"…","bytes":N,"certSha256":"…","minSdk":35,"minSupportedVersionCode":N0,
 "released":"YYYY-MM-DD","notes":"…","play":null}
```

**Steps:**
1. **Extend `android/scripts/release.sh --direct` with `--publish`.** It refuses to run unless A2's gate test passes at HEAD, then uploads in this order:
   1. versioned APK and `.sha256`
   2. copy to `PocketDJ.apk`
   3. `latest.json` **last**
   4. `aws cloudfront create-invalidation --distribution-id "$PDJ_CF_WWW" --paths /android/PocketDJ.apk /android/latest.json`.
   - Keep the last 3–5 versioned APKs and prune older ones.
2. **Guard the website sync:**
   - Add `--exclude 'android/*'` to the sync command in `www/README.md`. The command has no `--delete` today, so the exclude is belt and braces; never add `--delete`.
   - Add `www/android/*.apk` to `.gitignore`, which has no APK rule today. APKs never live in git.
3. **Updater in the `direct` flavor only**, under `android/app/src/direct/java/com/levi/pocketdj/update/`:
   - An OkHttp `latest.json` client. Its URL can be overridden by the remote endpoint document (`config/endpoints.{green,blue}.json`, `docs/design/remote-endpoints.md`); there is no `config/endpoints.json`.
   - Runs on launch and once a day through WorkManager.
   - When a newer version exists, show an "Update available" banner or Settings row. The MVP opens the APK URL in the browser, which needs no new permission.
   - A version below `minSupportedVersionCode` gets a forced-update screen.
   - Add a "Check for updates" row next to the build SHA in Settings ▸ Debug (SVC-5).
   - v2, deferred: DownloadManager, a SHA-256 check, then `PackageInstaller`. That needs `REQUEST_INSTALL_PACKAGES`, in `direct` only.
   - Tests use `okhttp.mockwebserver`, already a test dependency (`build.gradle.kts:139`): newer, same, malformed, offline, forced.
4. **Developer verification registration (Levi):**
   - With "upload your own key", once the Play app exists Play's automatic registration claims `com.levi.pocketdj` with the app-signing key, which is the key the direct APK uses.
   - Confirm in Play Console that the package shows as registered and that the listed certificate SHA-256 equals the pinned app-signing fingerprint. If not, register it manually; Play Console supports apps distributed off Play.
   - **Not urgent for launch.** Phase 1 doesn't cover direct sideloads, but it must be done before global enforcement in 2027. Unregistered APKs will then install only over ADB or through the advanced flow, and updates fail if the user later turns the advanced flow off.

**Verification:**
- `curl -sI https://pocket-dj.com/android/PocketDJ.apk` shows the right content type, content length and disposition.
- `curl -s … | shasum -a 256` matches the published checksum.
- `curl https://pocket-dj.com/android/latest.json` returns valid JSON.
- On the emulator (`-PincludeX86` build), a direct build with a lower versionCode shows the update banner (point it at a staged `latest.json`).
- **Levi, on a device:** install through Chrome on a real Android 15+ phone. Note the Play Protect prompt, the Samsung Auto Blocker path, and Apple Music sign-in and playback. If Play Protect flags the APK, submit it through Google's Play Protect appeal form.

---

### Phase C: Screenshot seeds and capture automation (Claude, `feat/android-store-screenshots`)

**Goal:** Android counterparts for the website groups, plus the Play phone set and, if tablets are promoted, the 7" and 10" sets, all on invented showcase data. Take the shots from a build that includes A2, so no rip UI shows.

**What exists today:**
- **Debug-only Studio seeds:** `PDJ_SEED_STUDIO` and `PDJ_SEED_DEMUX`, read with `getBooleanExtra` (`studio/StudioSeed.kt`, wired at `di/StudioGraph.kt:613-616`). They are test-grade: one 1 s tone.
- **Games:** `pdj.seedGames` and `pdj.useFixture` (`data/games/GamesPrefs.kt:10-12`, used at `di/GamesGraph.kt:393`), plus `pdj.pocketsStub` and `pdj.pocketsRecsOff` (`di/GamesGraph.kt:384-391`). These already accept both boolean and `"true"` string forms.
- **Tab landing:** `com.levi.pocketdj.action.OPEN_TAB` with the extra `tab=<route>` (`assistant/MediaSearchHandler.kt:243-256`).
- **A debug source set** exists: `android/app/src/debug/` has `AndroidManifest.xml`, `java` and `res`. `assets/` would be new.

**What is missing:**
- a fixture catalog (`data/catalog/CatalogRepository.kt` always fetches the real indexes)
- an onboarding skip (`di/ShellGraph.kt:69-72` builds `OnboardingStore` from DataStore storage and `hadPersistedSettings`, with no environment or fixture input)
- showcase seeds for burns, Mix, Now Playing, collections, history and activity
- landing seams for a Producer sub-tab, an open pattern or arrangement, expanded Now Playing, and deck layout.

**Rule for every seed extra:** read it with `getStringExtra` first, then `getBooleanExtra`, the same pattern `GamesGraph` already uses. That keeps existing `--ez X true` call sites working and lets `--es X showcase` turn on the new mode. Gate everything on `FLAG_DEBUGGABLE`. Fixture data lives under `android/app/src/debug/assets/` so release builds don't carry it.

**Steps:**
1. **Fixture mode** (`PDJ_USE_FIXTURE=1`, `PDJ_FIXTURE_RESOURCE=screenshot-index`):
   - Copy `apple/PocketDJ/Resources/screenshot-index.json` (12 invented albums, 60 songs) into `src/debug/assets/`.
   - `CatalogRepository` serves only that source, with no network refresh.
   - Add a fixture input to `OnboardingStore` at `di/ShellGraph.kt:69-72` so onboarding is skipped.
   - **Fixture mode must turn off all of these, so seeded data can never reach Levi's account or the shared ML corpus:**
     - AM sync and AM playlist sync (`amPlaylistSyncBase`)
     - profile sync uploads
     - the rec engine (`recEngineBase`)
     - listening-pockets uploads (`listeningPocketsBase`)
     - diagnostics uploads (`diagLogsBase`)
2. **Burns and playback:**
   - `PDJ_SEED_BURNS=showcase`: pre-render full-length, envelope-shaped mp3s on the Mac with `ffmpeg`/`lame`. Use 22.05 kHz mono at about 64 kbps, with the intro/build/drop/break/outro envelope from `apple/PocketDJ/State/BurnStore.swift:215-330`.
   - Put them in `src/debug/assets/showcase-burns/`, plus `data/burns/BurnStore.kt` ledger rows keyed to the fixture song ids.
   - `PDJ_SEED_MIX_DECK_SESSION=showcase` with `PDJ_MIX_DECK_LAYOUT=sideBySide|stacked|single` → `mix/store/MixDeckSessionStore.kt` at 124 BPM. The raw values come from `screens/mix/DeckArea.kt:48-49`.
   - `PDJ_SEED_PLAYBACK_SESSION=showcase` with `PDJ_NP_EXPANDED=1` → `playback/durable/PlaybackSessionStore.kt`, with rows already played and rows up next.
   - Playback must be genuine: the driver presses the app's own Play button.
3. **Studio, Demux and collections:**
   - `PDJ_SEED_STUDIO=showcase` with:
     - `PDJ_STUDIO_TAB=<raw>` (`screens/producer/StudioSubTab.kt`)
     - `PDJ_STUDIO_OPEN_PATTERN=ptn_showcase`
     - the arrangement `arr_showcase`.

     Port the data from `apple/PocketDJ/Studio/StudioStore.swift:1466-1623`: "Rooftop", 5 lanes at 124 BPM.
   - `PDJ_SEED_DEMUX=showcase`: "Golden Hour" (`DemuxStore.swift:206`).
   - `PDJ_SEED_COLLECTIONS=showcase`, `PDJ_SEED_HISTORY=fixture` and `PDJ_SEED_ACTIVITY=1`: port "Friday Night Warmup" and the other crates from `apple/PocketDJ/State/CollectionsStore.swift` and `CollectionActivityStore.swift`.
4. **JVM tests:** pin the extra names, check the release-build no-op, and check that fixture mode turns every network uploader off. Follow the `android/app/src/test/java/com/levi/pocketdj/studio/StudioSeedTest.kt` pattern.
5. **Device profiles:**

   | Profile | Device and size | Use |
   |---|---|---|
   | `site-phone` | `pocketdj` AVD, 1080×2400 | website images at 600×1333 |
   | `play-phone` | same AVD, `wm size 1080x1920` + `wm density 420` (9:16) | Play phone set. 20:9 breaks Play's "long side ≤ 2× short side" rule. |
   | `play-tab7` | new AVD `pocketdj-tab7` (`-d "Nexus 7 2013"`), `wm size 1080x1920`, density 280 | 7" set (only if tablets are promoted) |
   | `play-tab10` | new AVD `pocketdj-tab10` (`-d pixel_tablet`), 2560×1440, density 320, landscape | 10" set, side-by-side Mix; also website G1 `tablet-mix` |

   - Confirm that `NavigationSuiteScaffold` (`shell/ShellNavigation.kt:301`) shows a navigation rail and side-by-side Mix on tablets.
6. **Capture driver:** `android/app/src/androidTest/java/com/levi/pocketdj/screenshots/StoreScreenshotTest.kt`, mirroring `apple/Tests/UI/AppStoreScreenshotTests.swift`.
   - One test per shot group.
   - Launch with `ActivityScenario.launch` plus the extras.
   - `compose.waitUntil` waits on **seeded content** ("Rooftop", "Friday Night Warmup", "Golden Hour", a fixture title), never on chrome.
   - Capture the whole screen, demo status bar included, with `uiAutomation.takeScreenshot()`, not `captureToImage`.
   - Save to `getExternalFilesDir("store-shots/<profile>")`.
7. **Host script:** `android/scripts/store-screenshots.sh`. For each profile it:
   - boots the AVD **with audio** (not `-no-audio`)
   - runs `pm clear com.levi.pocketdj`
   - applies `wm size`/`density`, `cmd uimode night yes` and gesture navigation
   - enters SystemUI demo mode (clock 0941, battery 100, wifi 4, no notifications)
   - runs `./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.levi.pocketdj.screenshots.StoreScreenshotTest`. Once flavors exist the task is `connectedDirectDebugAndroidTest`.
   - pulls the shots with `adb pull`
   - resets wm and exits demo mode.
   - Fallback per shot: `adb exec-out screencap -p`.
8. **Post-processing:**
   - **Play:** `ffmpeg -i in.png -pix_fmt rgb24 out.png`. Rules: PNG or JPEG, no alpha, ≤ 8 MB, sides 320–3840 px, long side ≤ 2× short side, 2–8 per form factor, and at least 4 at ≥ 1080 px to be eligible for promotion. Output to `android/fastlane/metadata/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}/`.
   - **Website:** `cwebp -q 80 -resize 600 0` for phones (600×1333) and `-resize 1200 0` for tablets, into `www/img/android/`. Target the existing 13–42 KB range. The Apple phone images are 600×1304, so the two sets differ in aspect; see D1.
   - **Website file names**, all under `www/img/android/`:
     - G1: `mix.webp` (tablet if promoted, otherwise the phone Mix shot)
     - G2: `producer-samples`, `producer-sequencer` (the counterpart of Apple's `iphone-studio.webp`), `producer-instruments`, `producer-demuxer`, `producer-tracks`
     - G3: `nowplaying`
     - G4: `browse` (the Songs list; album art is grey on purpose)
     - G5: `playlists`
     - G6: `games-inthepocket`, `games-gemcollector` (driver taps Start and shoots about 3 s in), `games-home`
     - G7: `tablet-mix` (if tablets), `phone-nowplaying`, plus `notification.webp` (media notification or widget, `res/xml/now_playing_widget_info.xml`) until Auto ships, then `auto.webp` from the DHU.
9. **Listing art:**
   - a 512×512 icon (32-bit PNG, ≤ 1 MB) rendered from `res/mipmap-anydpi-v26` and `drawable/ic_launcher_*`
   - a 1024×500 feature graphic.

   Neither uses Apple trademarks. Levi signs off.

**Verification:**
- Run all profiles at the committed tip. Inspect every PNG by eye:
  - no third-party artists or album art
  - no real library names
  - no "0:00 / 0:02" durations
  - no empty decks
  - waveforms shaped, not solid blocks
  - no rip or capture UI.
- Check the fixture-mode network-off test passes.
- **Levi reviews the image set.**

**Blocker:** Android Auto capture needs the DHU package and a `google_apis_playstore` image. The current image is `google_apis`. This is deferred with Auto.

---

### Phase D: Website (Claude; deploy to green, Levi reviews after deploy)

**Shared facts for D1 and D2:**
- The source is `www/` (`index.html`, `support.html`, `img/`, `icon.png`), static with no build step.
- `www/index.html` is 694 lines: CSS at `:17-330`, JS at `:619-692`.
- Preview locally with `python3 -m http.server 8765 --directory www`.
- Deploy with the `www/README.md` commands (with the `android/*` exclude from Phase B), then `create-invalidation --paths '/*'`.
- That sync has `--exclude '.*'`, so **nothing under `www/.well-known/` is ever deployed by it**. Dotfile paths need their own `aws s3 cp`.
- Push before deploying.

#### D1: Global Apple/Android screenshot tabs (`feat/www-platform-tabs`)

Can land as soon as Phase C images exist. The site's existing images were pulled from App Store Connect, so none of them has an Android counterpart.

1. **Before first paint**, in `<head>`, add an inline script that:
   - adds the `js` class
   - sets `html.dataset.platform` to `apple`, unless `localStorage['pdj.www.platform']==='android'` (wrapped in try/catch)
   - optionally honours a `?platform=android` override for links from the Play listing or social posts.
2. **Tab bar and panel for all 7 groups** (one platform state for the whole page; switching one bar switches all of them):

   | Group | Lines | Apple images | Change |
   |---|---|---|---|
   | G1 Mix | 379–400 (img 396–398) | `ipad-mix.webp` 1200×900 in `.tablet` | `.tablet` frame moves inside `.ps-apple`; Android is `.tablet` or `.phone` depending on the tablet decision |
   | G2 Producer carousel | 403–440 (track 405–438) | `producer-samples`, `iphone-studio`, `producer-instruments`, `producer-demuxer`, `producer-tracks` | tablist wraps `#producer-carousel`; each `.car-slide` holds a `.pshot` with both phones |
   | G3 Now Playing | 455–475 (img ~458) | `iphone-nowplaying` | `.pshot` |
   | G4 Browse | 477–495 (img ~480) | `iphone-browse` | `.pshot` |
   | G5 Organize | 497–511 (img ~500) | `iphone-playlists` | `.pshot` |
   | G6 Games carousel | 513–540 | `games-inthepocket`, `games-gemcollector`, `games-home` | same as G2 |
   | G7 "Every screen" gallery | 574–596 (grid 579–595) | `mac-mix`, `vision-nowplaying`, `tv-nowplaying` | two whole `.gallery` grids, `ps-apple` and `ps-android`; the Android grid has different devices and captions |

   - Each bar is `role="tablist"` with two `role="tab"` buttons (`data-platform-tab="apple|android"`), using `aria-selected`, `aria-controls` and a roving `tabindex`.
   - Panels are `role="tabpanel"`.
   - Android images use `data-src`, not `src`, plus their real `width="600" height="1333"`. Those attributes still give an aspect ratio before `src` is set.
   - Apple keeps `src`, so visitors without JS and crawlers still see it.
   - Carousels keep one Android slide per Apple slide in the same position, so the index-based carousel JS (`:621-689`) and the bullet lists (`data-carousel-for`) don't change.
3. **CSS**, in the inline style block. Both images sit in one grid cell, so switching never shifts the layout:
   - `.pshot{display:grid}` and `.pshot>*{grid-area:1/1}`. The cell takes the taller of 1304 and 1333; align the shorter one at the top so it doesn't jump.
   - The inactive set gets `visibility:hidden`. Platform-specific text uses `.pt-apple`/`.pt-android` with `display:none`.
   - `.ptabs` is a pill switch using `--panel`, `--rim` and `--teal-lit`, with a `:focus-visible` outline.
   - `.ptabs` is hidden until `.js` is set, but keeps its space so nothing jumps when it appears.
   - `.row.flip .shot` becomes a column so the tabs sit above the image.
   - G7's two grids can differ in height, so either give both the same row count or accept a one-time reflow there.
4. **JS**, a new IIFE after the carousel IIFE (before `</script>` at `:692`). `setPlatform(p)`:
   - updates the dataset, every tab's `aria-selected` and `tabindex`, and each panel's `aria-labelledby`
   - on the first switch to Android, copies `data-src` → `src` for every Android image
   - saves the choice (try/catch).
   - Event handling: a delegated click handler; ArrowLeft/ArrowRight/Home/End on a tablist (automatic activation, focus stays in that tablist); and a `getBoundingClientRect` + `scrollBy` correction so the clicked bar doesn't move.
   - The carousel track's own ArrowLeft/Right handler is on `.car-track`, so the tablist must sit outside the track to avoid double handling.
   - On load, if the saved choice is Android, call `setPlatform('android')`.
5. **Platform-aware wording** (`.pt-*` spans):
   - `:467-471`:
     - CarPlay → Android Auto, only once Auto ships; until then say "Bluetooth & car audio"
     - Lock Screen → media notification and lock screen
     - widgets → home-screen widget
     - Siri/Shortcuts → omit on Android
   - `:569`: "private iCloud" vs "link devices by code" (only if sync ships; otherwise "stay on your device").
   - `:362` and `:575-578`: purchase and device wording, per Levi's pricing decision.
   - `:7` and `:14`: meta and og descriptions add Android.

**Verification (Playwright):**
- At desktop and 390 px widths:
  - the page defaults to Apple, with no Android image requests in the network log
  - clicking Android swaps all 7 groups, and the layout height is unchanged except, at most, G7
  - a reload remembers the choice
  - the keyboard arrows work, and the carousel arrows still work
  - the console is clean.
- With `localStorage` blocked (private mode), it falls back to Apple.
- No horizontal scroll at phone width.
- Screenshot each group in both states.
- After deploy, repeat on `https://pocket-dj.com` and tell Levi so he can review.

#### D2: Android download section and legal (`feat/www-android-download`)

Needs Phase B's APK live, or ship the section with "Coming soon" until it is.

1. **Hero** (`www/index.html:355-358`): replace the disabled button with an active "Download for Android" `.btn` → `#android`. Add the **Google Play badge** (`/img/google-play-badge.svg`, Google's artwork unaltered, linking to `https://play.google.com/store/apps/details?id=com.levi.pocketdj`). Show the badge only when `latest.json.play` is set, i.e. once the listing is live.
2. **New `<section class="get-android" id="android">`** before the closing call-to-action (`:598`). It is filled from `/android/latest.json` through `[data-apk-*]` elements, with static fallback text:
   - download button
   - version and code, size, release date
   - SHA-256 of the APK, and the signing certificate's SHA-256 with a one-line `apksigner verify --print-certs` hint
   - "Requires Android 15 or later, 64-bit ARM phone"
   - a QR code for desktop visitors (inline SVG generated at build time, so no new script dependency)
   - install steps:
     1. Download, and accept Chrome's "file may be harmful" warning.
     2. Allow **Install unknown apps** for the browser or Files app.
     3. Tap Install.
     4. If Play Protect warns, tap More details ▸ Install anyway.
     5. Samsung: turn off Auto Blocker.
   - a note to update once global developer verification arrives in 2027: no extra steps once the app is registered
   - updates: "install the newer APK over the old one; your data is kept"
   - a FAQ on moving to or from Play. It works with no data loss only under the recommended signing setup. A Play-installed copy updates from Play from then on.
3. **Closing call-to-action** (`:598-603`): add the Play badge and APK link next to the App Store badge (`:600-602`).
4. **Footer** (`:616`): add "Google Play and the Google Play logo are trademarks of Google LLC. Android is a trademark of Google LLC."
5. **`www/support.html`:**
   - Make the Apple Music section (about `:97-103`, heading at `:100`) and the iCloud paragraph (about `:116`) platform-neutral.
   - Add an "Android: install, updates, delete your data" section that serves as the web deletion URL Play requires (or a separate `www/delete-account.html`).
6. **`assetlinks.json`:**
   - Add `scripts/jukebox-site/.well-known/assetlinks.json` (the `.well-known/` folder doesn't exist yet), next to `apple-app-site-association`, with `com.levi.pocketdj`.
   - **It lists the app-signing certificate's SHA-256**, which is the certificate on devices for both Play and sideload installs. The upload key never reaches a device, so it doesn't belong there. Optionally add the debug keystore's fingerprint so emulator debug builds verify too.
   - **Deploy target, confirmed:** `jukebox.pocket-dj.com` is CloudFront `EKSX6E9IZE4PW` (`PDJ_CF_JUKEBOX`, `aws-env.sh:49+15`). It serves the **S3 website endpoint** of `pocketdj-dev-web-623170744161` with origin path `/jukebox`. The deploy is:

     `aws s3 cp … s3://$PDJ_DEV_WEB_BUCKET/jukebox/.well-known/assetlinks.json --content-type application/json --cache-control max-age=300`

     then invalidate on `$PDJ_CF_JUKEBOX`, green.
   - `scripts/jukebox-site/README-universal-links.md` still defaults to blue and invalidates `PDJ_CF_DEV`; fix both while there.
   - Optionally add `scripts/green/smoke.sh:25`-style coverage for assetlinks.
   - For `pocket-dj.com/.well-known/`: a separate `s3 cp`, because the www sync excludes dotfiles. Only do it if `pocket-dj.com` App Links are ever added to the manifest, since today's filter is jukebox-only.
7. **Privacy policy** (`docs/legal/PRIVACY.md` → legal.pocket-dj.com via `PDJ_LEGAL_BUCKET` / `PDJ_CF_LEGAL`):
   - Fill in:
     - list Android
     - the publisher (the LLC), in place of "[Publisher]"
     - the effective date, in place of `{{EFFECTIVE_DATE}}`
     - Apple Music on Android (the Music-User-Token stays on the device, and what the MusicKit SDK sends to Apple)
     - Play Services location (foreground, opt-in, kept on the device unless synced)
     - microphone (on-device; stems upload only when the user asks)
     - Bluetooth (`neverForLocation`)
     - rec-engine and listening-pockets uploads, if they ship
     - S3 profile sync in place of CloudKit, if it ships
     - diagnostics (direct flavor, if on)
     - the deletion URL.
   - **This needs Levi's legal sign-off before deploy**, unlike the rest of the website. It is also needed before the Play app content section (Phase E).

**Verification:**
- Playwright:
  - the section fills in from `latest.json`, and the fallback shows when the fetch is blocked
  - the download link has the right headers (`curl -sI`)
  - the QR code decodes to the right URL.
- `curl -sI https://jukebox.pocket-dj.com/.well-known/assetlinks.json` returns 200, `application/json`, no redirect.
- **On a release-signed build** (`-PincludeX86`, signed with the app-signing key, or debug if the debug fingerprint is listed):
  - run `adb shell pm verify-app-links --re-verify com.levi.pocketdj`
  - `pm get-app-links com.levi.pocketdj` then shows `verified` for `jukebox.pocket-dj.com`.

---

### Phase E: Play Console (Levi submits; Claude drafts on `feat/android-play-listing`)

Start E1–E2 and the internal track **as soon as the account and the A1–A3 artifacts exist**, even before C and D are finished. That locks the package name and the Play App Signing choice, and triggers auto-registration for developer verification.

1. **Create the app** with ID `com.levi.pocketdj`, default language en-US, app type, and free or paid (Levi's pricing decision; free → paid is not allowed later).
2. **Play App Signing:** at the first upload, choose to **use your own key** ("Export and upload a key from Java keystore").
   - Run Google's PEPK tool, downloaded from the Console, on `pocketdj-app-signing.jks`.
   - Register the **upload key** certificate.
   - *Irreversible.* Never use Play's "key upgrade" later, because it breaks the match with sideloaded builds and with `assetlinks.json`.
3. **Store listing**, drafted in `android/fastlane/metadata/android/en-US/`:
   - Files: `title.txt` (≤ 30 characters), `short_description.txt` (≤ 80), `full_description.txt` (≤ 4000), adapted from the App Store copy.
   - Say clearly that streaming needs an Apple Music subscription and the Apple Music app.
   - No Apple trademarks in the icon, title or feature graphic.
   - Upload the screenshots and art from Phase C.
4. **App content:**
   - Privacy policy URL: `https://legal.pocket-dj.com/privacy/`, after the D2 update.
   - Ads: none.
   - Target audience: 18+ (or 13+), not designed for children.
   - News, government and financial features: none.
   - **Data safety**, drafted from the code. Only data **transmitted off the device** counts as collected. Data processed only on the device is not declared.

     | Data | Collected? | Shared? | Notes |
     |---|---|---|---|
     | Audio (microphone, user audio files) | Optional, only for user-requested stem uploads (StemClient) | No | Studio samples and In the Pocket dictation (on-device SpeechRecognizer) stay on the device and are not declared |
     | Approximate and precise location | Only if it leaves the device (sync or pockets upload); otherwise not collected | No | Foreground "listening places" (COL-20) |
     | Music library, history, playlists (App activity) | Yes, if the rec engine, listening pockets or profile sync ship | No | `recEngineBase`, `listeningPocketsBase`, S3 sync (SVC-7/9, dormant until Q42) |
     | Listening context (pockets) | Opt-in | No | COL-17 |
     | Device or other IDs | If sync or enrolment ships | No | Device name and enrol token in sync records |
     | Diagnostics | No (play flavor) | — | `DIAG_CHANNEL=false` (`build.gradle.kts:23`) |
     | Apple Music sign-in and the SDK | Declare what the MusicKit SDK collects | Levi/counsel decide whether this is "shared" or a user-initiated transfer | Disclose the third-party service |

     Data is encrypted in transit, and there is no selling, ads or analytics. Users can request deletion in the app and on the web (from A2 and D2).
   - **Permission declarations:** foreground services `mediaPlayback` and `dataSync` (or UIDT, per A2.4), each with a description and a short screen recording. Claude records these on the emulator with `adb shell screenrecord`. Add background location only if it was kept, and it should not be.
   - **Content rating (IARC):** Claude pre-fills, Levi answers. Music with explicit content plus user-generated jukebox requests likely gives Teen.
5. **Form factors:** phone, plus tablet if promoted. **Do not opt into Android Auto in v1** (see A2.6) unless a real head-unit or DHU pass is done. If Auto is opted in, Google reviews it against the car app quality guidelines and wants Auto screenshots.
6. **Testing tracks:**
   1. **Internal testing:** upload the AAB from `release.sh --play`. It's available within minutes to up to 100 testers (Levi plus friends). Check:
      - the install from Play replaces a sideloaded copy without a signature error
      - the App Links are verified
      - Apple Music works.
   2. **Closed testing:**
      - Organization account: optional, but recommended for a short beta.
      - **Personal account: required for each new app, with 12 or more testers opted in to the closed track for the last 14 days in a row** before you can apply for production. Recruit 15 or more testers from the jukebox and website audience before the account exists, because some drop out.
   3. **Production:**
      - Apply for production access if on a personal account; that approval takes about 7 days.
      - Submit for review. It usually takes hours to a few days, and up to 7 days or more for new accounts and sensitive permissions.
      - **Staged rollout at 20% → 50% → 100%.**
7. **After approval:** set `latest.json.play` to the listing URL so the website shows the Play badge, and redeploy.
8. **Optional:** a Play Developer API service account (Levi creates the JSON) so that `release.sh --play --upload` pushes to the internal track headlessly, like headless TestFlight.

**Verification:**
- The internal-track install works on a real device.
- The pre-launch report in Play Console is clean (crashes, accessibility, 16 KB).
- Play Console shows the package registered for developer verification, with the pinned certificate.
- The review is accepted.

---

### Phase F: After launch (Claude, `feat/android-release-pipeline`)

1. **One release pipeline:** `android/scripts/release.sh --all <versionName>` builds both flavors from one versionCode, then publishes in this order:
   1. Play internal track (AAB)
   2. sideload APK and `latest.json`
   3. a reminder to promote the Play release.
   - It prints `==> Done`. It never runs at the same time as an Apple ship (build.db rule).
2. **Updater v2** (direct only): an in-app download, SHA-256 check and `PackageInstaller` install, and `minSupportedVersionCode` enforcement.
3. **Monitoring:**
   - Play Console vitals: ANR and crash rates, below the bad-behaviour thresholds.
   - Pre-launch reports for each release.
   - CloudFront/S3 logs for APK download counts and `latest.json` polls, as a sideload install proxy.
   - Opt-in diagnostics from the direct flavor into the S3 diag bucket, if Levi enabled it.
4. **Policy maintenance:**
   - Track the yearly target-SDK bump (each August 31; API 37 is expected around August 2027).
   - Re-check the 16 KB requirement on each NDK or AAR update.
   - Before global enforcement in 2027, re-confirm the developer-verification registration and update the site's install steps.
   - Update Data safety whenever FR2 adds `ACTIVITY_RECOGNITION` or sync ships.
   - Submit each new sideload APK to the Play Protect review form if it gets flagged.
5. **Later feature work:** Android Auto (SURF-8 real head-unit pass, SURF-9 Auto Mix) followed by an Auto opt-in, the ShazamKit AAR (Q84), and R8 rule maintenance.
6. **Keep a release ledger:** each version's code, cert fingerprint, APK SHA and Play status appended to `docs/ARCHITECTURE-ANDROID.md`, plus a new memory entry for the Android publishing recipe.

---

## 3. Risks and mitigations

| Risk | Likelihood and impact | Mitigation |
|---|---|---|
| **IP / rip-path policy rejection.** Play's IP policy bans helping users capture copyrighted content. The capture and burn paths are `di/BrowseGraph.kt:527-547`, SVC-1, and burns streamed from the AM-captured rips bucket via the remote `ripsBase`. | High impact; likely rejected if the paths are reachable | A2 rip and burn gate, compile-time, so the remote endpoint document can't re-enable it. Settle Decision A (A1 recommended) and MUST-5b before the first upload. Keep the store listing focused on mixing your own library and streaming through Apple Music. |
| **Music licensing and the MusicKit terms on Android**, including distribution outside Play | Medium; could block distribution | Levi or counsel confirms the MusicKit for Android SDK terms. The developer token stays server-side, with no secret in the APK. The listing states that an Apple Music subscription is required. No Apple trademarks in the art. |
| **Sensitive-permission review** (background location, foreground services, microphone) | Medium; adds weeks if background location is kept | Drop background location from v1 (and accept the loss of screen-off trips). Prepare the foreground-service declaration videos ahead of time, or move downloads to UIDT. Keep microphone use clearly user-started. |
| **16 KB page-size rejection** | Certain to be rejected if not fixed (`libpdjdsp.so` is 0x1000 today) | A1 alignment fix, plus `llvm-readelf` / `zipalign -P 16` checks inside `release.sh`. |
| **Duplicate `libc++_shared.so`.** Both the app (`-DANDROID_STL=c++_shared`) and `mediaplayback-release-1.1.1.aar` ship one, and only one ends up in the APK. | Medium; Apple Music native code could crash at runtime with an STL it wasn't built against | Find out which copy wins (compare the APK's file to the AAR's and the NDK's). Test AM playback on a real device with the release build. If it breaks, link pdjdsp with `c++_static`, or pin the AAR's copy with `packaging.jniLibs.pickFirsts`. |
| **Developer verification blocks sideloads** (global in 2027; phase 1 covers participating stores only, not direct APKs) | High impact from 2027, low now | An organization account and Play App Signing with our own key mean auto-registration covers the direct APK. Confirm the certificate in the Console. ADB stays exempt for development. |
| **D-U-N-S delay** (up to 28 days) | Likely to slow the start | Check the entity behind Apple team `EC27UF79GL` for an existing LLC number. Meanwhile install over ADB and finish phases A to D. |
| **12-tester, 14-day closed test** (personal accounts only, per app) | Avoidable | Use an organization account. If personal, recruit 15 or more testers in advance and allow 14 days plus about 7 days for the production-access review. |
| **Lost signing key, or the wrong Play App Signing choice** | Catastrophic and irreversible | Upload your own key to Play App Signing. Back up off-machine, exclude from credsync, and pin the fingerprint in the release script. |
| **Play Protect warning on the sideloaded APK** | Likely at first | Register the developer and package, sign consistently, submit to Play Protect review, keep the permission set small, and document "Install anyway" on the site. |
| **R8 breaks Apple Music, serialization or JNI at runtime** | Medium (`musickitauth` has no consumer rules) | Keep rules, plus a minified emulator smoke pass and instrumented tests, plus a real-device AM check before publishing. |
| **Showcase seeds leak to the real account or the ML corpus, or real library art shows up in store images** | Medium | Fixture mode disables every uploader (AM sync, profile sync, rec engine, pockets, diagnostics) with a test for it. Seeds are debug-only, the emulator is cleared and signed out, and every PNG is checked by eye. |
| **Website deploy wipes APKs, or uses the wrong (blue) account; `.well-known` silently not deployed** | Low | `--exclude 'android/*'`, never `--delete`, green environment only, APKs never in git. Dotfile paths get a separate `s3 cp`, and the jukebox README is fixed to say green. |
| **Narrow reach because of minSdk 35** | Business risk | Levi decides. Lowering it means re-testing the API-36-only features listed in `docs/ARCHITECTURE-ANDROID.md` (the "API-36-only candidates" section, about line 294). |
| **Android Auto quality review failure, or an accidental Auto opt-in** | Medium if opted in | Phone-only v1. Check the manifest has no `automotive_app_desc` meta-data in release, and opt in after a real DHU or head-unit pass. |
| **Parallel Gradle builds collide** (the sibling `pocketdj-android` worktree) | Medium | One build owner, separate worktrees, and a lockfile in `release.sh`. |

---

## 4. Timeline estimate

These are working days of agent effort plus calendar time for Google's waits. The waits are what decide the end date.

| Week | Claude (in parallel) | Levi / Google |
|---|---|---|
| **0 (day 1)** | A1 build config; start C (fixture and seeds) | **D-U-N-S lookup or request**; create the Play account and pay $25; ID, email and phone verification (1–3 days, sometimes longer); decisions A0 |
| **1** | A2 policy fixes (after the decisions); A3 release script; C capture driver and AVDs | Generate keystores with Claude and back them up; legal review of the privacy policy draft |
| **2** | B updater and publishing (after A2 merges); D1 website tabs (deploy, Levi reviews after); first signed APK installed by ADB on Levi's devices, plus the real-device AM, R8 and STL check | Device smoke test; wait on D-U-N-S (up to 28 days) |
| **2–4** | D2 download section (public APK); privacy and support page updates; Play listing drafts | D-U-N-S arrives; organization account verified |
| **4** | — | Create the Play app and upload your own signing key; **internal testing** (same day; auto-registration for developer verification); Data safety, content rating and declarations |
| **4–5** (organization account) | Fixes from the pre-launch report | Optional short closed beta (about 1 week); submit to production. **Review takes 1–7 days**, longer for a new account. |
| **4–7** (personal account instead) | — | **Closed test with 12+ testers for 14 days**, then the production-access application (about 7 days), then review (1–7 days) |
| **5–8** | F pipeline; flip on the website Play badge | Staged rollout 20% → 100% over about 1 week |

**Estimated end dates**
- **Sideload APK publicly downloadable:** about 2 weeks. It needs A1–A3, B, D2 and the privacy sign-off. Developer verification does not block direct sideloads until the global rollout in 2027; registration happens automatically once the Play app exists.
- **Play production with an organization account:** about 4–6 weeks, set mainly by the D-U-N-S wait.
- **Play production with a personal account:** about 6–8 weeks.
- **Add 2–4 weeks if background location is kept, `dataSync` is challenged, or Auto is in v1**: declaration review, possible rejection and resubmission.

---

## Review notes

**Wrong facts, corrected after checking Google's official developer-verification overview and FAQ and the target-SDK page on 2026-10-28**
1. **Phase 1 scope.** The draft implied phase 1 (2026-09-30, Brazil, Indonesia, Singapore, Thailand) blocks sideloads. The official FAQ says phase 1 covers only **participating app stores**; direct sideloads and other stores are not enforced until the global rollout in 2027. This changed A0, B4, D2, the risks table and the timeline.
2. **Limited-distribution accounts *can* migrate to full accounts.** The draft said they can't be converted. They are also Android Developer Console accounts, not Play accounts. The stopgap is now ADB, and the limited account is optional.
3. **Play App Signing apps are auto-registered** for developer verification. The draft had Levi register the certificate manually in the Console and said "the docs don't say". Corrected: confirm the automatic registration, and register manually only as a fallback. The ADC also allows several keys per package.
4. **The 12-tester rule is per app,** for personal accounts created after 2023-11-13, and only closed-track testers count.
5. **API 36** is the 2026-08-31 requirement for new apps and updates, so the current `targetSdk = 36` passes. Added that API 37 is expected in 2027.

**Repo facts the draft misread or left out (all checked against files at `b6e8b25b` and live endpoints)**
6. **Background location** is declared at `AndroidManifest.xml:16` and requested at `ListeningLocationSection.kt:101` (launcher) and `:182` (launch). Its purpose (`:50`) is screen-off trip detection. Dropping it loses that feature, and Levi now gets an explicit trade-off with an FGS `location`-type alternative.
7. **The rip gate was too narrow.** `config/endpoints.green.json:7` hands out `ripsBase`, the AM-captured rips bucket, at runtime. A release "default unset" doesn't stop burns of AM-sourced rips, so the gate is now compile-time and covers rip-sourced burns (MUST-5's `sourceName` gate). The citation is now `BrowseGraph.kt:527-547`.
8. **`config/endpoints.json` doesn't exist.** The files are `config/endpoints.{blue,green}.json`.
9. **The R8 rules** missed that `musickitauth-release-1.1.2.aar` has **no** `proguard.txt` (mediaplayback has one) and missed the JNI keep rules for `pdjdsp`.
10. **ABI filters.** They live in `defaultConfig` (`:33`), and build-type filters merge with them, so a "release-only override" can't remove x86_64. The fix is now to move the filters into each build type and add a `-PincludeX86` escape hatch. The invented `directReleaseMinifiedX86` variant is replaced, and unsigned APKs can't be installed for the smoke test.
11. **Signing config.** One `release` config can't sign direct with the app-signing key and play with the upload key, so A1 now has per-flavor signing configs.
12. **New risk: `libc++_shared.so` is shipped by both** the app's `c++_shared` STL and the mediaplayback AAR, and only one copy ships.
13. **16 KB.** I measured every `.so` in the sibling APK: `libpdjdsp.so` is 0x1000, the others are 0x4000, and `libappleMusicSDK.so` is 0x10000. AGP 8.9.1 handles zip alignment.
14. **`assetlinks.json` should list the app-signing certificate.** The upload key never reaches a device, so the draft's "plus the upload key" was wrong. Added the optional debug fingerprint. The emulator verification now uses a release-signed build, which a debug build would fail.
15. **Jukebox deploy path, confirmed in CloudFront.** The distribution is `EKSX6E9IZE4PW` (`PDJ_CF_JUKEBOX`), serving the S3 *website* origin of `pocketdj-dev-web-623170744161` with origin path `/jukebox`. The S3 key is `jukebox/.well-known/assetlinks.json`, and it needs an explicit content type. `README-universal-links.md` is stale: it defaults to blue and to `PDJ_CF_DEV`.
16. **The www sync has `--exclude '.*'`,** so anything under `www/.well-known/` would silently never deploy. The www distribution's REST + OAC origin is confirmed (OAC `E1RH3HKBPJNLBR`).
17. **Privacy effective date.** It is the template token `{{EFFECTIVE_DATE}}` in `PRIVACY.md:3`. The live page renders "[Publisher]" and "[Effective date pending]".
18. **Website line and asset mapping.**
    - The Apple phone shots are 600×1304, not 1333; added overlay alignment.
    - G1 is an iPad (1200×900), so its Android tab depends on the tablet decision.
    - Producer slide 2 is `iphone-studio.webp`.
    - G7 is Mac, Vision Pro and TV, so the Android grid differs.
    - The JS ends at `:692`.
    - The carousel arrow-key handler sits on `.car-track`, so the tabs must sit outside it.
19. **Seed citations.** These were tightened:
    - `ShellGraph.kt:69-72` takes DataStore storage, not an environment.
    - `DeckArea.kt:48-49` includes `single`.
    - `GamesGraph` already reads both string and boolean forms.
20. **Data safety.**
    - It counts only off-device data, so on-device location and microphone use are not "collected".
    - Added the rec-engine and listening-pockets uploads (`endpoints.green.json:9-10`), which the draft missed, plus MusicKit SDK collection. Whether Apple counts as "shared" goes to Levi or counsel.
21. **Fixture mode** must also disable the rec engine, pockets and diagnostics uploaders, not only AM and profile sync.
22. **Added the `dataSync` FGS risk** (Android 15's 6-hour limit; reviewers may push toward UIDT) and the **accidental Android Auto opt-in** risk (`res/xml/automotive_app_desc.xml` exists).
23. **The web deletion URL** is required only if the app lets users create an account. It now depends on the sync decision.

**Ordering and missing steps**
24. **The Play app and internal track start as soon as the account and A1–A3 exist**, before C and D. That locks the package and signing choice and triggers auto-registration.
25. **B publishing now requires A2 merged.** The direct APK must not ship with rip paths.
26. **D2's privacy sign-off** is now also a prerequisite for Phase E.
27. **Added to Levi's list:**
    - Play Billing and pricing consequences: free → paid is not allowed later, and a direct APK has no payment path.
    - The organization account shows a public address.
    - Confirm which entity Apple team `EC27UF79GL` is, since a D-U-N-S can be reused only if it's the LLC's.
    - Decide whether the rec and pockets network ships.
28. **Small fixes:**
    - the `findProperty` `.toString()` bug
    - an explicit `--metadata-directive REPLACE` on the server-side "latest" copy
    - title ≤ 30 characters
    - icon ≤ 1 MB
    - `connectedDirectDebugAndroidTest` once flavors exist
    - the test-count baseline from the ledger.

Sources: [Android developer verification](https://developer.android.com/developer-verification), [Developer verification FAQ](https://developer.android.com/developer-verification/guides/faq), [Play target API requirements](https://developer.android.com/google/play/requirements/target-sdk), [Play closed-testing requirement for new personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465), [Gadget Hacks on the Sept 30 changes](https://android.gadgethacks.com/news/google-android-sideloading-restrictions-sept-30-explained/), [ontest.app 12 testers explainer](https://ontest.app/blog/google-play-12-testers-14-days-requirement-explained).
