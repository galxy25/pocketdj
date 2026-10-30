# Android answers program — roadmap

*Generated from `android/specs/answers/tools/spec.py` by `build_roadmap.py`; checked by `check_roadmap.py`. Do not hand-edit — edit spec.py and rebuild.*

Source: Levi's answers in `android/specs/parity/QUESTIONS.md` (ANSWERED, main `2e7fd5ee`, 2026-10-29). Every answer that needs code has a package below; answers that need no code, or belong to another program, are listed under *Not scheduled*. Sizing came from reading the code at `2e7fd5ee` (four read-only scouts: playback, mix/studio, collections/sync, browse/games/services).

**47 packages · 12 waves · ~18,160 est. lines.** Sizes: S < 300 · M 300–1000 · L > 1000 (L items are split so no package exceeds ~900).

## How it runs

- Same machinery as the parity program: one worktree + branch `answers/<ID>` per package off the integration branch **`feat/android-answers`** (cut from `main`), Sonnet implements → Opus adversarial review → Sonnet fixes → one integrator merges, runs the full JVM suite (count must move), runs every emulator step on the `pocketdj` AVD, pushes, appends a wave section to `android/specs/answers/PROGRESS.md`.
- Reuse `android/specs/parity/wave-workflow.js` with three constants changed: `RM` → `android/specs/answers/roadmap.json`, status dir → `android/specs/answers/status/<ID>.md`, integration branch `feat/android-parity` → `feat/android-answers` (branch prefix `parity/` → `answers/`). Everything else (resume protocol, WIP commits, review/fix schema) is unchanged.
- Packages in one wave have pairwise-disjoint files and at most one owner per hot wiring file (`di/*Graph.kt`, `PlaybackService.kt`, `SetlistSequencer.kt`, `BurnStore.kt`, `DebugScreen.kt`, manifest, gradle). Every `depends_on` lands in a strictly earlier wave.
- **Polish gate (wave 8).** Waves 1–7 touch none of the files `feat/android-ui-polish` is editing or was handed (Q7 nav → More, Q14 permissions + Burn Stop). Wave 8 starts only after that branch merges to main and `feat/android-answers` is rebased/merged onto it. Gated paths:

  - `android/app/src/main/java/com/levi/pocketdj/MainActivity.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/AppGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/navigation/PocketDjDestination.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackController.kt`
  - `android/app/src/main/java/com/levi/pocketdj/shell/ShellNavigation.kt`
  - `android/app/src/main/java/com/levi/pocketdj/ui/theme/`
  - `android/app/src/main/java/com/levi/pocketdj/onboarding/`
  - `android/app/src/main/java/com/levi/pocketdj/screens/browse/`
  - `android/app/src/main/java/com/levi/pocketdj/screens/nowplaying/`
  - `android/app/src/main/java/com/levi/pocketdj/screens/mix/`
  - `android/app/src/main/java/com/levi/pocketdj/screens/history/HistoryScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/games/GamesRoutes.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/ProducerScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/instruments/PianoKeyboard.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/SettingsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/SettingsSections.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/sections/ListeningLocationSection.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/collections/AddToPlaylistMenu.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/collections/AddToCollectionSheet.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/CollectionBurnBar.kt`
  - `android/app/src/main/java/com/levi/pocketdj/widget/WidgetBridge.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/catalog/AlbumArtworkStore.kt`
  - `android/app/src/main/AndroidManifest.xml`

- New-file names in `files` are proposals; an implementer may rename a NEW file (status note) but must stay off other packages' files.

## Conflicts to resolve (need Levi) — proposed resolutions

### C1. Profile sync: Q5 'no profile sync needed' vs Q42 'separate secret, good to deploy' (Q52/Q54/Q66 defaults)

- Profile sync is already BUILT on Android (data/sync/* ~1,290 lines, ~20 SyncEntry sites, LinkDeviceScreen, ProfileSection) and dormant: config/endpoints.green.json has no profileSyncBase, and nothing provisions ProfileSecretStore.ENROLL_TOKEN, so even a deployed Lambda would refuse enrollment.
- Account deletion IS wired already (ServicesGraph.kt:565-590 deleteCloudDocs/deleteCloudProfile + PendingCloudErasure retry) - Q54's 'deleteProfile() not called' is stale.
- Q75(b) 'cloud sync of Imported-songs' only exists if profile sync exists.
- Q10 caveat: CredentialsSync would copy the OpenSearch keys into the synced settings-credentials doc if sync goes live, contradicting 'keystore local'.
- Cost: leave dormant = 0; deploy = S code (~80) + Levi AWS deploy; full removal = L (~2,000 lines, touches onboarding/*, a polish-gated dir).

**Proposal (built by the plan):** Follow Q42 (the later, more specific answer): deploy the profile-sync Lambda to green with its own ENROLL_SECRET, but ship sync OPT-IN and OFF by default (Settings > Profile 'Sync across devices'); no account exists unless the user turns it on. Provision the enroll token at runtime through the same endpoints-doc 'capabilities' channel Q69 adds (so it is rotatable). Strip the search keys from the Android credentials doc (Q10). Read Q5 as 'not required for v1 / never forced on users'. Do NOT remove the code.

**If Levi picks the other side:** Skip ANS-SYNC-1 entirely; sync stays dormant (no removal - removal costs L and touches onboarding); drop Q75(b); the Play deletion page only covers rec-engine/pockets data.

Affected packages: ANS-SYNC-1, ANS-COL-3.

### C2. Location: Q89 'build location engine and request permission' vs release plan A2 'drop ACCESS_BACKGROUND_LOCATION from v1'

- The engine already exists (COL-20, wave 22): data/location/{DwellDetector,FusedVisitSource,ListeningPlaceEngine,ListeningPlacesStore,LocationSettings}.kt + Settings > places & trips (ListeningLocationSection, order 665); Q89(b) was asked before COL-20 landed.
- Background location is declared (AndroidManifest.xml:16) and requested ('Allow Always', ListeningLocationSection.kt:50,178-190). Its only purpose is 'notice trips between your places while music plays in the background'.
- Q14 (handed to the polish branch) says 'request all permissions needed' - the polish branch must not add a background-location prompt if C2 lands as proposed.

**Proposal (built by the plan):** Keep the engine and request foreground location (COARSE+FINE, opt-in from the Settings toggle) - that satisfies Q89. Drop ACCESS_BACKGROUND_LOCATION in every build. Keep 'trips while music plays in the background' working by adding the `location` foregroundServiceType to PlaybackService, started only while audio plays AND places & trips is on (Android 14+ allows a while-in-use location FGS started from the foreground). Play then needs only the FGS-location declaration, not the background-location declaration + video. Places stop updating when nothing is playing (acceptable: plays are what get stamped).

**If Levi picks the other side:** Keep ACCESS_BACKGROUND_LOCATION only in the `direct` (sideload) flavor once release plan A1 adds flavors; the Play flavor removes it with tools:node="remove".

Affected packages: ANS-LOC-1.

### C3. Q60 'implement anything that is stubbed' / Q75 'no partial anywhere' vs answers where Levi chose the default (Q44, Q56, Q59, Q91b, Q100 ...)

- Several remaining stubs are exactly what a 'default' answer deferred: Q100 (For You endPlaybackScope, Gem Collector cloudSimilar/recSuppressed), Q56 owner gate, Q59 sources adoption, Q91b 'Open Now Playing after Play'.

**Proposal (built by the plan):** Explicit default answers win for their own item; every OTHER stub / PARTIAL code gap gets a package (ANS-GAP-*), and a final verification sweep (ANS-VERIFY-1) re-runs every PARTIAL row's emulator steps so 'not emulator-verified' stops being a PARTIAL reason. Levi can promote any deferred default into the sweep by saying so.

Affected packages: ANS-GM-2, ANS-GAP-1, ANS-GAP-2, ANS-GAP-3, ANS-GAP-4, ANS-GAP-5, ANS-GAP-6, ANS-GAP-7, ANS-GAP-8, ANS-VERIFY-1.

## Premises that turned out stale (tell Levi; packages are sized to the real gap)

- **Q2** — Neither platform persists amPlaylistId today - not on Pockets AND not on Playlists (iOS CodingKeys omit it; Android has it @Transient / in-memory). Work = persist on both models on both platforms.
- **Q12** — Seams are already assigned (joinJukebox/playItem in ShellGraph.kt:185-220, importCollection in CollectionImportSeam.kt, mwf in GamesGraph.kt:380); only play/setlist via ShellActions + App Links (Q3) remain.
- **Q24** — PlayStatsStore.noteSkipped already exists and is fed; nothing READS it (For You rebuilds skips from history). Work = consumers.
- **Q29** — Stem lock shipped in MIX-18 (StemLock.kt, persisted + restored). Remaining = stop guessing `<songId>_<variant>` (persist resolveId).
- **Q40** — Android already matches iOS: iOS does NOT clear the selection after Add-to and logs one row per song too. Only gap: iOS caps one batch at maxEvents/4.
- **Q54** — Account deletion already calls s3Database.deleteProfile() with a durable retry marker.
- **Q60** — The real In the Pocket opt-in + LivePocketsBridge already exist (CollectionsGraph.startListeningPockets); only the debug stub fallback and stale comments remain.
- **Q63** — An 'Import MIDI' picker exists inside Takes; iOS shows it on the main Instruments view. Work = surface it there (+ Score).
- **Q89** — (b) The location engine exists (COL-20). (a) Settings row and (c) Browse-play outcomes are real gaps.
- **Q18** — MixViewModel already materializes on Mix-tab open; missing = the launch-time park (lock screen / Auto see the parked mix) + Auto Mix row materialize.
- **Q38** — The per-song failure cooldown is 120 s (not 60 s); 60 s is the server-down cooldown.

## Micro-decisions taken as defaults (override any)

- **Q11** — 'Burn store UI' read as iOS Storage parity (pushed Burned-by-artist / by-collection / stems lists + 'Delete all burnt music') plus a Settings > Playback cloud/device row. Say so if you meant more.
- **Q38** — Only the per-song cooldown shrinks to ~2 s for Auto-DJ (2 s, 2 s, 3 s then back to 120 s after 3 straight failures); the 60 s server-down pause stays so a dead server isn't hammered.
- **Q50** — Tapping a studio row plays that item alone (iOS playNow semantics); artist = profile 'PocketDJ name', fallback 'Pocket DJ' (iOS), not 'Studio'.
- **Q23** — Samples MOVE to the SAF folder like takes/iOS (needs the Q101 materializer for playback) rather than keeping a doubled mirror copy.
- **Q81** — Storage-pressure eviction stays local-only (never deletes the user-folder copy); only explicit deletes remove the folder copy.
- **Q85** — Ratings pull pages 20x250 ids per pass from a saved cursor (+ always the locally-hearted/pending songs); 'Failed: N' shows 20 rows then 'Show all'.
- **Q69** — The rotated secret is as public as the APK constant was; the gain is server-side rotation. Lambdas accept a comma-separated REC_ENROLL_SECRETS (old+new) so shipped iOS builds keep working.
- **Q20** — Picker only; 'Require access tokens' stays an intent flag (enforcing it is a jukebox server + guest page change - out of scope unless asked).
- **Q61** — No cloud sync of the profile custom-audio source (consistent with C1 until sync is on).

## Needs Levi

| Package | Wave | What |
|---|---|---|
| ANS-BRW-2 | 4 | AWS deploy of rec-engine + listening-pockets Lambdas to green (AWS_PROFILE=llc) and publishing the endpoints doc (CONFIG_ONLY=1 scripts/deploy.sh prod) |
| ANS-SURF-2 | 5 | Release signing fingerprints (release plan A3) + Play App Signing cert (Play Console), and OK to upload to the jukebox CloudFront/S3 site (profile levi) + invalidate |
| ANS-SYNC-1 | 7 | DECISION C1 first. Then: AWS_PROFILE=llc scripts/lambda/profile-sync/deploy.sh (green), commit config/endpoints.green.json, publish the endpoints doc; a second device/emulator pair for link-a-device |
| ANS-LOC-1 | 11 | DECISION C2 (proposal vs keep background in the direct flavor); Play FGS-location declaration at submission |
| ANS-VERIFY-1 | 12 | Phone session for the device checklist (Q9 decoder warm-up, Q13 AAC priming, Q36, Q41, Q84, Q86, Q6 quality, Q15 BT) |

All other packages are fully agent-drivable (emulator, JVM, iOS simulator / My Mac on this iMac).

## External dependencies

- **Q25** — feat/am-token-test-flow (handled separately): mint the developer token + Music-User-Token on the iOS/macOS app and inject them into the Android test flow. Every 'Real AM ...' device/emulator verification step below (ANS-COL-1, ANS-PB-2, ANS-PB-3, ANS-COL-5, ANS-BRW-1, ANS-GAP-1, ANS-GAP-2, ANS-GAP-3, ANS-BRW-5 token path, ANS-VERIFY-1) runs once that branch has merged; until then those steps use the pdj.amApiBase / pdj.fakeMut mocks.

## Waves

| Wave | Theme | Packages | Est. lines |
|---|---|---|---|
| 1 | Edition safety, game AM, playback settings + dead-air, Auto-DJ cooldown, SAF materializer, amPlaylistId | ANS-COL-1 · ANS-PB-1 · ANS-PB-2 · ANS-PB-3 · ANS-MIX-1 · ANS-STU-1 | 2190 |
| 2 | Imported supersede + setlist export, burn-folder mirror, native Mix stretch, streaming bake, jukebox picker, golden scorer | ANS-COL-3 · ANS-COL-4 · ANS-MIX-2 · ANS-STU-2 · ANS-SURF-1 · ANS-GM-1 | 2900 |
| 3 | Activity cap, paginated ratings pull, Studio session owner + park/resume, Discover play/adds, skip consumers, ITP stub removal | ANS-COL-2 · ANS-COL-5 · ANS-STU-3 · ANS-BRW-1 · ANS-PB-4 · ANS-GM-2 | 1660 |
| 4 | Real iOS fixtures, runtime enroll secret, SAF samples, clip paging, Mix restore + off-main | ANS-SVC-2 · ANS-BRW-2 · ANS-STU-4 · ANS-STU-5 · ANS-MIX-3 | 2680 |
| 5 | Deep links + assetlinks, jukebox AM match, AM playlist reconcile, backup merges, pockets Settings row, ShazamKit | ANS-SURF-2 · ANS-GAP-1 · ANS-GAP-2 · ANS-GAP-4 · ANS-BRW-4 · ANS-BRW-5 | 2120 |
| 6 | Profile source A, Discover/rec gaps, soft-cap prune, stem carve | ANS-STU-7 · ANS-GAP-3 · ANS-GAP-5 · ANS-GAP-6 | 1800 |
| 7 | Profile sync go-live (C1), Demux save, Recently-added producer | ANS-SYNC-1 · ANS-STU-8 · ANS-GAP-8 | 1250 |
| 8 **(gate)** | POLISH GATE: PlaybackController pass, HeldQueue resumption, clause op, studio rows, games deep links, Mix sessions gaps | ANS-PB-5 · ANS-PB-6 · ANS-BRW-3 · ANS-STU-6 · ANS-GM-3 · ANS-GAP-7 | 1960 |
| 9 | Playback off-main | ANS-PB-7 | 350 |
| 10 | Minimal background graph | ANS-SHELL-1 | 650 |
| 11 | Location per C2, Mix on Oboe | ANS-LOC-1 · ANS-MIX-4 | 500 |
| 12 | No-PARTIAL verification sweep + device checklist | ANS-VERIFY-1 | 100 |

## Answer → package index

| Q | Packages |
|---|---|
| Q2 | ANS-COL-1 |
| Q3 | ANS-SURF-2 |
| Q5 | ANS-SYNC-1 |
| Q6 | ANS-MIX-2, ANS-MIX-4 |
| Q10 | ANS-SYNC-1 |
| Q11 | ANS-PB-3 |
| Q12 | ANS-SURF-2 |
| Q15 | ANS-PB-6 |
| Q17 | ANS-PB-3, ANS-PB-5 |
| Q18 | ANS-MIX-3 |
| Q20 | ANS-SURF-1 |
| Q21 | ANS-PB-5 |
| Q23 | ANS-STU-4 |
| Q24 | ANS-PB-4 |
| Q29 | ANS-PB-1 |
| Q31 | ANS-GM-1 |
| Q32 | ANS-BRW-3 |
| Q36 | ANS-PB-2 |
| Q38 | ANS-MIX-1 |
| Q40 | ANS-COL-2 |
| Q41 | ANS-STU-3 |
| Q42 | ANS-SYNC-1 |
| Q43 | ANS-GM-3 |
| Q50 | ANS-STU-6 |
| Q52 | ANS-SYNC-1 |
| Q54 | ANS-SYNC-1 |
| Q60 | ANS-GM-2, ANS-GAP-1, ANS-GAP-3, ANS-GAP-5, ANS-GAP-6, ANS-GAP-8, ANS-GAP-7, ANS-VERIFY-1 |
| Q61 | ANS-STU-7, ANS-STU-8 |
| Q63 | ANS-STU-1 |
| Q66 | ANS-SYNC-1 |
| Q69 | ANS-BRW-2 |
| Q72 | ANS-SVC-2 |
| Q75 | ANS-COL-3, ANS-GAP-1, ANS-GAP-2, ANS-GAP-4, ANS-GAP-3, ANS-SYNC-1, ANS-GAP-7, ANS-VERIFY-1 |
| Q76 | ANS-BRW-1 |
| Q79 | ANS-BRW-1 |
| Q81 | ANS-COL-4 |
| Q84 | ANS-BRW-5 |
| Q85 | ANS-COL-5 |
| Q86 | ANS-STU-3 |
| Q89 | ANS-BRW-4, ANS-PB-5, ANS-LOC-1 |
| Q91 | ANS-BRW-4 |
| Q93 | ANS-LOC-1 |
| Q94 | ANS-PB-1, ANS-STU-6 |
| Q95 | ANS-PB-5 |
| Q96 | ANS-MIX-3, ANS-PB-7 |
| Q97 | ANS-STU-2, ANS-STU-5 |
| Q98 | ANS-SHELL-1 |
| Q101 | ANS-STU-1 |

## Packages

### Wave 1 — Edition safety, game AM, playback settings + dead-air, Auto-DJ cooldown, SAF materializer, amPlaylistId

#### ANS-COL-1 — Persist amPlaylistId on Pockets AND Playlists, Android + iOS

- **Answers:** Q2 · **Area:** collections · **Size:** S (~250 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** An Apple-Music-linked pocket or playlist keeps its AM playlist link across relaunch and sync on both platforms; shared/exported files never carry the link.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/CollectionsModels.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/CollectionsCodec.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/io/PocketZip.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/io/PlaylistZip.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/io/CollectionFile.kt`
  - `apple/PocketDJ/Models/CollectionsSchema.swift`
  - `apple/PocketDJ/Services/PocketZip.swift`
  - `apple/PocketDJ/Services/PlaylistZip.swift`
  - `android/app/src/test/java/com/levi/pocketdj/data/collections/CollectionsCodecParityTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/collections/io/PlaylistZipTest.kt`
  - `apple/Tests/Unit/AMPlaylistSyncTests.swift`
  - `apple/Tests/Unit/CollectionsLossyDecodeTests.swift`
- **Acceptance:**
  - Optional field written only when set: documents for unlinked collections are byte-identical before/after (no schema bump)
  - Android: @Transient removed; Pocket + Playlist serializers read/write amPlaylistId; iOS: CodingKeys + try? decode + memberwise inits for both
  - Export (PocketZip/PlaylistZip/.pdjcollection) strips the field on BOTH platforms; import keeps stripping it
  - An iOS-written collections doc with the field decodes on Android and vice versa (cross-fixture test)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** CollectionsCodecParityTest: pocketDoesNotPersistAmPlaylistId reversed -> persists; unlinked bytes unchanged; PlaylistZipTest: export strips amPlaylistId; iOS AMPlaylistSyncTests + CollectionsLossyDecodeTests (garbled value -> nil)
- **Emulator / device verification:**
  - Link a pocket to Apple Music (debug pdj.fakeMut + mock base), force-stop, relaunch: run-as cat files/pocketdj-collections.json shows amPlaylistId on the pocket
  - iOS: apple-test unit suite on the simulator (count moved)
  - Device-only: Real AM link on a subscribed account.
- **Ledger rows to update:** COL-1, COL-9

#### ANS-PB-1 — Editions on restore + clean-only skip: persist resolveId; skip explicit rows with no clean cut without shifting indexes

- **Answers:** Q29, Q94 · **Area:** playback · **Size:** M (~550 lines) · **Priority:** P0 · **Depends on:** —
- **Goal:** A restored session plays exactly the edition it was playing (no `<songId>_<variant>` guess), and a clean-only collection never plays an explicit row that has no clean edition (family-event safe).
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/playback/durable/SessionSnapshot.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/durable/SessionWriter.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/durable/ResumptionProvider.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/QueueItem.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/RowSourceResolver.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/SetlistSequencer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/NextRowPreloader.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/edition/PolicyEditionDecider.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/edition/EditionPolicy.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/CollectionsStore.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/durable/PlaybackSessionStoreTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/durable/HeldRestoreTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/edition/PolicyEditionDeciderTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/CleanOnlySkipTest.kt`
- **Acceptance:**
  - Snapshot rows carry optional resolveId (iOS Codable ignores it - file stays iOS-compatible); restore uses it; when absent (old/iOS files) SessionRestorer re-runs the EditionDecider instead of building the string
  - QueueItem.cleanOnlySkip stamped when cleanOnly && EditionPolicy.isSkipped(song); playCurrent returns UnplayableSource(CLEAN_ONLY_EXPLICIT) BEFORE any resolve/load and advances with UNPLAYABLE_HERE
  - Preloader, ResolveStallHop and Up Next indexes are unchanged (no row removal); an all-skipped lap ends cleanly (no spin)
  - Setlist realize freezes the clean-only flag (iOS CollectionsStore.swift:2200-2210 parity)
  - Stem lock (MIX-18) still round-trips through the snapshot
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** PlaybackSessionStoreTest: resolveId round-trip; iOS fixture without it decodes; HeldRestoreTest: persisted id wins; fallback re-decides; CleanOnlySkipTest: indexes unchanged, never loaded, never preloaded, all-skipped lap terminates; PolicyEditionDeciderTest: skip flag matrix
- **Emulator / device verification:**
  - Seed a clean-only pocket with one explicit song that has no clean edition between two playable rows; Play: logcat PocketDJ.playback shows `advance ... reason=CLEAN_ONLY_EXPLICIT` and the explicit row never logs `track start`
  - Play a playlist with a clean edition, am kill, relaunch: snapshot JSON shows resolveId and the same edition resumes
  - Device-only: None beyond normal playback.
- **Ledger rows to update:** PB-4, BRW-3

#### ANS-PB-2 — Game rows prefer full-track Apple Music, fall back to 30 s previews

- **Answers:** Q36 · **Area:** playback · **Size:** S (~120 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Gem Collector / In the Pocket rounds play the full AM track when the device can, otherwise the preview rung as today.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/AppleMusicRowResolver.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/SequencerGameRunPlayer.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/AppleMusicRowTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/ResolveLadderTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/GameRunPlayerContractTest.kt`
- **Acceptance:**
  - runTag guard removed from AppleMusicRowResolver; canPlayFullTrackCached/ripStartsNow logic unchanged
  - Game row with AM capability resolves to the AM rung; without it falls to GamePreviewRowResolver (Rung.FALLBACK); game rows still never POST /rip
  - Preview warm-up skipped for ids that will play full-track; game timing budgets (CollectorsPuzzle 2.5 s cloud budget) tolerate AM start latency (documented)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** AppleMusicRowTest: game row gets AM when capable else null; ResolveLadderTest: preview fallback order; GameRunPlayerContractTest
- **Emulator / device verification:**
  - Start a Gem Collector round on the emulator (no AM full-track): rounds still play previews (log rung=preview)
  - Device-only: Full-track AM inside a game round (needs a subscribed device).
- **Ledger rows to update:** PB-8, GM-3

#### ANS-PB-3 — Settings > Playback mode row, iOS-parity burn store screens, dead-air readout, AM takeover hardening

- **Answers:** Q11, Q17 · **Area:** playback · **Size:** M (~700 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Users pick cloud/device playback in Settings, manage burned music like iOS Storage, and Debug shows the dead-air KPI; AM-only rows in a run take over reliably.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/sections/PlaybackSection.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/PlaybackGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/StorageScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/storage/BurnedArtistsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/storage/BurnedCollectionsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/storage/BurnedStemsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/DebugScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/health/DeadAirReport.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/am/AppleMusicEndMonitor.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/settings/PlaybackSectionTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/settings/StorageListsTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/health/DeadAirReportTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/am/AppleMusicEndMonitorTest.kt`
- **Acceptance:**
  - PlaybackGraph contributes settingsSections (PlaybackSection, order ~460) + navEntries for the three Storage list screens - SettingsScreen.kt/SettingsSections.kt untouched
  - Mode row round-trips PlaybackSettings.playbackMode and the per-collection toggle reflects it
  - Storage: pushed Burned-by-artist / by-collection / stems-by-artist lists replace the AlertDialog lists; 'Delete all burnt music' with confirm (iOS StorageView parity)
  - DeadAirSource.current assigned in PlaybackGraph.wire(); Debug shows Today, last 7 days and the 4 worst transition pairs, refreshed every 1 s (iOS DebugView parity)
  - AppleMusicEndMonitor gains iOS reconcilePoll self-heal + onNearEnd prefetch for AM rows inside a run
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** PlaybackSectionTest; StorageListsTest (grouping, delete-all); DeadAirReportTest (formatting, worst pairs); AppleMusicEndMonitorTest (reconcile poll)
- **Emulator / device verification:**
  - Settings > Playback: flip Device/Cloud, relaunch, value persists
  - Settings > Storage > Burned by artist: burn 3 (Debug 'Burn first 3'), list shows them; Delete all -> files/burns empty
  - Play seed queue across 3 transitions; Settings > Debug dead-air readout shows Today with 3 transitions
  - Device-only: AM full-track takeover inside a run (DRM).
- **Ledger rows to update:** PB-1, PB-3, SVC-4, PB-8

#### ANS-MIX-1 — Auto-DJ stream failure cooldown 1-3 s with backoff

- **Answers:** Q38 · **Area:** mix · **Size:** S (~120 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** A stream that failed is retried by Auto-DJ within ~2 s instead of 120 s, without hammering a permanently broken song.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/mix/stream/MixStreamLoader.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/engine/StreamDecks.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/engine/AutoReadiness.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/stream/MixStreamLoaderTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/engine/StreamDecksTest.kt`
- **Acceptance:**
  - canStream(songId, forAuto=true) uses 2 s, 2 s, 3 s, then the 120 s default after 3 consecutive failures; manual loads keep 120 s
  - Server-down cooldown (60 s) unchanged (micro-decision)
  - Injected clock; no wall-clock sleeps in tests
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** MixStreamLoaderTest: auto cooldown schedule + reset on success; StreamDecksTest: Auto-DJ path uses forAuto
- **Emulator / device verification:**
  - Debug 'AutoDJ:' probe with a mock rip server returning 500 once: the same song re-opens within ~3 s (logcat PocketDJ.mix)
  - Device-only: Real network flaps.
- **Ledger rows to update:** MIX-10

#### ANS-STU-1 — StudioMaterializer for SAF-stored media + MIDI import button on Instruments/Score

- **Answers:** Q101, Q63 · **Area:** studio · **Size:** M (~450 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Takes/sequences stored in a user (SAF) folder work everywhere a java.io.File was required; MIDI import is reachable from the main Instruments view like iOS.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/studio/store/StudioMaterializer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/TakeRenderer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/StudioAnalyzer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/StudioGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/tracks/TracksHomeScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/instruments/TakesScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/instruments/MidiImportButton.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/instruments/InstrumentsScreen.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/store/StudioMaterializerTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/TakeFilerTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/demux/DemuxSessionTest.kt`
- **Acceptance:**
  - StudioMaterializer.lease(ref) returns the file directly or copies the content:// into cacheDir/studio-saf/ keyed by uri+size+mtime with an LRU cap; lease release is idempotent
  - 'Use as sample', Demuxer 'Performance media' (DemuxEnv.studioFile) and key detection (StudioAnalyzer.ensureKey) use it; TracksHomeScreen's private copyUriToCache replaced
  - MidiImportButton shared by Takes and the main Instruments section (iOS StudioInstrumentsView parity); optional on Score/LiveStaff
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** StudioMaterializerTest: file passthrough, copy, cache hit, LRU eviction, revoked uri -> null; TakeFilerTest: SAF take usable as sample; DemuxSessionTest: SAF media appears
- **Emulator / device verification:**
  - Pick an Instrumentals SAF folder in DocumentsUI, record a take, 'Use as sample' -> sample plays
  - adb push a .mid to Downloads; Instruments > Import MIDI -> take appears
  - Device-only: SD-card trees.
- **Ledger rows to update:** STU-9, STU-14, STU-16

### Wave 2 — Imported supersede + setlist export, burn-folder mirror, native Mix stretch, streaming bake, jukebox picker, golden scorer

#### ANS-COL-3 — COL-15 complete: amrec_ supersede for imported songs, setlists on PlaylistsScreen, detail-screen export

- **Answers:** Q75 · **Area:** collections · **Size:** M (~700 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** An imported row that later resolves to a catalog song is remapped everywhere (no duplicates); setlists are listed; every collection detail can export.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/catalog/CatalogRepository.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/catalog/ImportedSongsStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/BrowseGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/CollectionsGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/PlaylistsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/PlaylistDetailScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/PocketDetailScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/SetlistDetailScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/collections/CollectionExportImport.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/catalog/ImportedSongsStoreTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/catalog/ImportedSupersedeWiringTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/collections/CollectionExportImportTest.kt`
- **Acceptance:**
  - CatalogRepository merge computes ImportedSongsStore.supersedePairs; onImportedSupersede removes the imported row then remaps collections + favorites (iOS AppModel.applySupersede parity)
  - PlaylistsScreen lists Setlists (iOS PlaylistsView:1193); playlist/pocket/setlist detail overflow menus have Export (.pdjcollection) and Export CSV (setlistCsv wired)
  - Imported-songs cloud SyncEntry is NOT added here - it lands in ANS-SYNC-1 (conflict C1)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ImportedSongsStoreTest: supersede pairs; ImportedSupersedeWiringTest: remap order + favorites; CollectionExportImportTest: setlist CSV + detail export
- **Emulator / device verification:**
  - Import a .pdjcollection with an amrec_ row, then a catalog refresh that contains its appleMusicId: pocket now references the catalog id, no duplicate row
  - Collections shows a Setlists section; Setlist detail > Export CSV saves via DocumentsUI
  - Device-only: None.
- **Ledger rows to update:** COL-15, COL-10

#### ANS-COL-4 — Burn folder: mirror stems + beat grids; deleting a burn deletes the folder copy

- **Answers:** Q81 · **Area:** collections · **Size:** M (~350 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** The user-browsable burn folder holds the complete burn (audio, sidecar, stems, analysis) and stays in step with deletes.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/BurnFolder.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/ContentResolverBurnTree.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/BurnStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/BurnModels.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/burns/BurnFolderSafTest.kt`
- **Acceptance:**
  - BurnTree.delete(name) + BurnFolder.deleteMirrored(treeUri, names) (no-op when unreachable); BurnItem records its treeUri at finalize
  - mirrorFiles runs after every stem/beat-grid write (burnCollectionStems, beat-grid fetch, burnStems, single-part, streamed-stem adopt); .json copied as application/json
  - removeBurns/removeAuxFiles/removeAllBurns/removeStems delete folder copies; storage-pressure eviction stays local-only (micro-decision)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** BurnFolderSafTest (fake tree): stems+grids mirrored, delete on remove, revoked folder untouched, eviction leaves folder copy
- **Emulator / device verification:**
  - Choose Downloads/PocketDJ as burn folder; burn a stemmed song: folder shows 4 stem files + analysis json; delete the burn in Storage: folder copies gone
  - Device-only: Real SD card.
- **Ledger rows to update:** SVC-14, SVC-11

#### ANS-MIX-2 — Mix tempo/pitch on the C++ Signalsmith real-time stretcher (Q6a)

- **Answers:** Q6 · **Area:** mix · **Size:** M (~650 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Mix and Now Playing DSP decks stretch with Signalsmith via JNI (no Sonic rebuilds, quality beyond +-25 %), latency-compensated so sync/handover stay aligned.
- **Files:**
  - `android/app/src/main/cpp/pdjdsp/stretch_rt.h`
  - `android/app/src/main/cpp/pdjdsp/stretch_rt.cpp`
  - `android/app/src/main/cpp/pdjdsp/CMakeLists.txt`
  - `android/app/src/main/cpp/pdjdsp/jni.cpp`
  - `android/app/src/main/java/com/levi/pocketdj/studio/audio/NativeDsp.kt`
  - `android/app/src/main/java/com/levi/pocketdj/audio/dsp/TimeStretcher.kt`
  - `android/app/src/main/java/com/levi/pocketdj/audio/dsp/NativeTimePitch.kt`
  - `android/app/src/main/java/com/levi/pocketdj/audio/dsp/TimePitch.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/graph/DeckChain.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/graph/Handover.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/engine/MixEngine.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/test/java/com/levi/pocketdj/audio/dsp/TimePitchTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/engine/CrossfaderSyncTest.kt`
  - `android/app/src/androidTest/java/com/levi/pocketdj/audio/dsp/NativeTimePitchInstrumentedTest.kt`
  - `android/app/src/androidTest/java/com/levi/pocketdj/mix/graph/MixGraphSmokeInstrumentedTest.kt`
- **Acceptance:**
  - TimeStretcher interface in audio/dsp (single-audio-layer rule); NativeTimePitch default, Sonic fallback when the native lib is absent (JVM tests)
  - Per-block ratio change, no allocation/lock on the render thread; stretcher always on so latency never jumps
  - DeckChain input clock, Handover alignment, sync/phase-align and Auto-DJ glide subtract latencyFrames()
  - libpdjdsp still 16 KB-aligned (release plan) and builds for arm64-v8a + x86_64
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** TimePitchTest fallback; CrossfaderSyncTest with latency compensation; NativeTimePitchInstrumentedTest: length + pitch within tolerance at 0.7x/1.3x; MixGraphSmoke
- **Emulator / device verification:**
  - connectedDebugAndroidTest NativeTimePitchInstrumentedTest + MixGraphSmoke pass on the pocketdj AVD
  - Mix two burned songs, tempo +30 %: sync button keeps beat pulse aligned (log phase error < 5 ms)
  - Device-only: Audible quality, CPU on a mid phone.
- **Ledger rows to update:** MIX-3, MIX-5

#### ANS-STU-2 — Tracks paging part A: streaming master bake + bounce (chunked resampler, streaming AAC)

- **Answers:** Q97 · **Area:** studio · **Size:** M (~500 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Record-to-master and bounce never hold the whole capture/mix in memory.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/MasterRecorder.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/ArrangerBouncer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/audio/StudioRender.kt`
  - `android/app/src/main/java/com/levi/pocketdj/audio/core/AacEncoder.kt`
  - `android/app/src/main/java/com/levi/pocketdj/audio/core/StreamingResampler.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/MasterRecorderTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/ArrangerBouncerTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/audio/core/StreamingResamplerTest.kt`
- **Acceptance:**
  - MasterWav read in chunks; StreamingResampler carries state across chunks (bit-identical to one-shot within 1e-6)
  - writeM4a streams; renderOffline/mixdown render block-wise to the encoder; peak-normalize (Q70 default) done with a 2-pass peak scan, not a full buffer
  - Peak heap during a 10-minute bake bounded (test asserts no FloatArray > a few seconds)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** StreamingResamplerTest; MasterRecorderTest: chunked == one-shot; ArrangerBouncerTest: streamed bounce matches
- **Emulator / device verification:**
  - Record a 5-minute master on the emulator; bake completes; dumpsys meminfo peak stays < previous build's
  - Device-only: Low-RAM phone limits.
- **Ledger rows to update:** STU-11, STU-13

#### ANS-SURF-1 — Jukebox sessions picker (host an existing session)

- **Answers:** Q20 · **Area:** surfaces · **Size:** S (~300 lines) · **Priority:** P2 · **Depends on:** —
- **Goal:** The host can list broker sessions and adopt one (tvOS TVRootView.select parity).
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/jukebox/JukeboxSessionsPicker.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/jukebox/JukeboxScreen.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/jukebox/JukeboxSessionsPickerLogicTest.kt`
- **Acceptance:**
  - Sheet from CreateView + LiveView: listSessions() rows (name, guest URL, age), refresh/error/empty states
  - Tap: end() the active session if different, then adopt(id); adopt guards respected
  - No ShellNavigation change
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** JukeboxSessionsPickerLogicTest: decision matrix (same/different/none active)
- **Emulator / device verification:**
  - Run scripts/jukebox-server.mjs locally (debug cleartext 10.0.2.2), create 2 sessions, picker lists both, adopt the second: Live view shows it
  - Device-only: None.
- **Ledger rows to update:** SURF-10

#### ANS-GM-1 — In the Pocket golden cross-platform test captured on this iMac

- **Answers:** Q31 · **Area:** games · **Size:** M (~400 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** The Kotlin scorer is proven equal to the Swift scorer on a shared fixture.
- **Files:**
  - `apple/Tests/Fixtures/inthepocket-golden-input.json`
  - `apple/Tests/Unit/InThePocketGoldenTests.swift`
  - `android/app/src/test/resources/fixtures/inthepocket-golden-input.json`
  - `android/app/src/test/resources/fixtures/inthepocket-golden-expected.json`
  - `android/app/src/test/java/com/levi/pocketdj/data/games/inthepocket/InThePocketGoldenTest.kt`
- **Acceptance:**
  - Env-gated Swift test (PDJ_WRITE_GOLDEN=1) runs InThePocketScorer.build per case (seeds 1..N, cloud/history/cold modes) on My Mac via apple-test (ad-hoc signing) and writes expected JSON
  - Kotlin test asserts picks/scores/targets/chips equal (doubles 1e-9)
  - Any mismatch is fixed in the Kotlin port in this package (or filed as a finding if Swift is wrong)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** InThePocketGoldenTest; InThePocketGoldenTests (Swift, writer mode + assert mode)
- **Emulator / device verification:**
  - n/a (JVM + macOS xcodebuild test); record the xcodebuild command + count in status
  - Device-only: None.
- **Ledger rows to update:** GM-5

### Wave 3 — Activity cap, paginated ratings pull, Studio session owner + park/resume, Discover play/adds, skip consumers, ITP stub removal

#### ANS-COL-2 — Collection activity: cap one batch at maxEvents/4 (iOS parity; selection/rows already match)

- **Answers:** Q40 · **Area:** collections · **Size:** S (~40 lines) · **Priority:** P2 · **Depends on:** —
- **Goal:** A huge Add-to batch cannot flush the whole activity history.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/activity/CollectionActivityStore.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/activity/CollectionActivityStoreTest.kt`
- **Acceptance:**
  - recordAll keeps the newest maxEvents/4 of one batch
  - Selection stays armed after Add-to and one row per song (both already match iOS - documented in status for Levi)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** CollectionActivityStoreTest: 10k batch keeps newest 5k
- **Emulator / device verification:**
  - Add 153 songs: History > Collection shows 153 rows (iOS parity)
  - Device-only: None.
- **Ledger rows to update:** COL-5

#### ANS-COL-5 — Favorites ratings pull paginated + Failed list paginated

- **Answers:** Q85 · **Area:** collections · **Size:** S (~280 lines) · **Priority:** P1 · **Depends on:** ANS-COL-3
- **Goal:** Foreground sync no longer fires ~440 GETs per pass on a 110k catalog.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/favorites/FavoritesSyncService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/favorites/FavoritesSyncSettings.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/CollectionsGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/AppleMusicSettingsScreen.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/favorites/FavoritesSyncServiceTest.kt`
- **Acceptance:**
  - Each pass pulls a page (20 batches x 250) from a persisted FAVORITES_PULL_CURSOR, wrapping; locally-hearted/pending ids always included; page stops on RateLimited
  - Only the page is reconciled (absence != unfavorite rule kept); lastSyncedAtMs per page; 'x of y' progress exposed
  - Settings > Apple Music Failed list shows 20 rows + 'Show all (N)'
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** FavoritesSyncServiceTest (MockWebServer): cursor advance/wrap, favorites always in, rate limit stops
- **Emulator / device verification:**
  - pdj.amApiBase mock + pdj.fakeMut, opt-in ON: one pass = 20 GET batches (mock request count)
  - Device-only: Real AM account.
- **Ledger rows to update:** COL-11

#### ANS-STU-3 — Studio session owner (Loops keep playing in background) + park/resume on transient focus loss everywhere

- **Answers:** Q41, Q86 · **Area:** studio · **Size:** M (~800 lines) · **Priority:** P1 · **Depends on:** ANS-STU-1
- **Goal:** Loop audition continues with a media notification when backgrounded; Loop, Multitrack, Instrument replay and Demux park and resume on transient focus loss like iOS.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/StudioSessionPlayer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/LoopAudition.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/MultitrackPlayer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/InstrumentEngine.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/demux/StemPlayer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/AudioFocusPolicy.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/StudioGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/session/SessionSwitchboard.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/StudioSessionPlayerTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/LoopAuditionTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/AudioFocusPolicyTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/MultitrackPlayerTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/InstrumentEngineTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/demux/StemPlayerSyncTest.kt`
- **Acceptance:**
  - StudioSessionPlayer (engine 'studio') claims SessionSwitchboard on loop start, resigns on stop; StudioGraph binds a MediaController so PlaybackService goes foreground; yieldMixToExo covers 'studio'
  - Background observer no longer stops the loop audition (other voices still stop)
  - Each engine registers with InterruptionCoordinator (isAudible/park/resume): Loop (id, frames), Multitrack (positionMs, arrangement), Instrument (replayPositionMs, events), Demux (pause/resume); permanent loss stops + clears; user play/stop clears park
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** StudioSessionPlayerTest; AudioFocusPolicyTest: transient loss parks, gain resumes, permanent stops (per engine); LoopAuditionTest/MultitrackPlayerTest/InstrumentEngineTest/StemPlayerSyncTest park-resume
- **Emulator / device verification:**
  - Loops: start audition, press Home: audio continues, dumpsys media_session shows the studio card; Stop from notification stops
  - Play a multitrack arrangement; a second app requests AUDIOFOCUS_GAIN_TRANSIENT (adb shell cmd media_session / test app): arrangement parks then resumes at the same position
  - Device-only: Phone calls, headphone unplug, BT re-prime, OEM background kills.
- **Ledger rows to update:** STU-4, STU-16

#### ANS-BRW-1 — Discover: Play on ripped rows; serverless album adds without a Music-User-Token

- **Answers:** Q76, Q79 · **Area:** browse · **Size:** S (~220 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Discover matches iOS: ripped rows play; the album + works without Apple Music sign-in.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/discover/DiscoverResultsList.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/discover/DiscoverAlbumResultsList.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/discover/DiscoverModels.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/discover/DiscoverRowStateTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/discover/DiscoverAddControllerTest.kt`
- **Acceptance:**
  - ripped = hit.ripped || manifest contains songId; row shows play (pause when it is the playing song) via PlaybackController.play (no edit to it); long-press Play Next/Last via ShellActions
  - Album + enabled whenever any track source exists; help text addHelp('album', canAddToLibrary); no-MUT add records with LibraryWrite.SKIPPED_NO_CONNECTION (iOS RipsStore parity)
  - Immediate-submit IME hook stays out (BrowseScreen.kt is polish-gated) - noted
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** DiscoverRowStateTest: ripped via manifest; DiscoverAddControllerTest: no-MUT album add
- **Emulator / device verification:**
  - Discover search with mock rip server: ripped row plays (mini player appears)
  - Signed out of AM: album + adds tracks, History shows them, status 'Apple Music write skipped'
  - Device-only: Real AM library write.
- **Ledger rows to update:** BRW-15, BRW-16

#### ANS-PB-4 — Skip-count sink consumers: For You reads PlayStatsStore play/skip counts

- **Answers:** Q24 · **Area:** playback · **Size:** S (~120 lines) · **Priority:** P2 · **Depends on:** —
- **Goal:** Cumulative per-song skips (already recorded) shape For You like iOS PlayCountService.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/foryou/ForYouTilesScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/foryou/ForYouSongListScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/stats/PlayCountService.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/foryou/ForYouSkipInputsTest.kt`
- **Acceptance:**
  - Both For You screens feed ZoneEngine.Feedback.skipPenalties(playCountsSnapshot, skipCountsSnapshot) read off Main (iOS ForYouView:301 / ForYouDetailViews:612)
  - Thin PlayCountService facade; history-derived skip rebuild removed
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ForYouSkipInputsTest: skipped songs rank lower
- **Emulator / device verification:**
  - Skip a song 3x from a queue; For You list ranks it below an unskipped peer
  - Device-only: None.
- **Ledger rows to update:** PB-5, SVC-11, BRW-12

#### ANS-GM-2 — Remove the In the Pocket debug stub path; stale stub comments swept

- **Answers:** Q60 · **Area:** games · **Size:** S (~200 lines) · **Priority:** P1 · **Depends on:** ANS-PB-3
- **Goal:** Debug and release use the real Settings-backed opt-in + LivePocketsBridge; no screen flashes 'isn't available' while the bridge loads.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/di/GamesGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/games/InThePocketScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/games/PocketsOptInView.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/location/ListeningContext.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/pockets/PocketsBridge.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/games/inthepocket/InThePocketStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/DebugScreen.kt`
  - `android/app/src/test/java/com/levi/pocketdj/di/GamesGraphBridgeTest.kt`
- **Acceptance:**
  - stubEnabled/debugBridge/stubOptIn deleted; pdj.pocketsStub aliases pdj.pocketsEnable (real settings writes)
  - Screen observes servicesBridgeFlow and shows a loading state until set
  - Stale comments fixed (ListeningContext 'no location engine', PocketsBridge/InThePocketStore 'until services wave', DebugScreen GM-7/GM-3/Zone notes)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** GamesGraphBridgeTest: no stub in debug; loading -> live
- **Emulator / device verification:**
  - Fresh install debug build: In the Pocket opt-in writes LISTENING_POCKETS_ANSWERED; relaunch keeps it
  - Device-only: None.
- **Ledger rows to update:** GM-8, GM-7

### Wave 4 — Real iOS fixtures, runtime enroll secret, SAF samples, clip paging, Mix restore + off-main

#### ANS-SVC-2 — Real iOS-exported backup + .pdjcollection fixtures (captured on this iMac) + Android parity tests

- **Answers:** Q72 · **Area:** services · **Size:** M (~350 lines) · **Priority:** P2 · **Depends on:** ANS-COL-1
- **Goal:** Android import is proven against bytes the real iOS exporters wrote.
- **Files:**
  - `apple/Tests/Unit/FixtureExportTests.swift`
  - `apple/scripts/export-android-fixtures.sh`
  - `android/app/src/test/resources/backup/ios-real/README.md`
  - `android/app/src/test/java/com/levi/pocketdj/data/collections/io/IosRealFixtureTest.kt`
- **Acceptance:**
  - Opt-in Swift unit test (skips unless PDJ_FIXTURE_OUT) builds a representative store (nested pockets, multi-chapter playlists, folders, setlists, cleanOnly/recsEnabled/sync direction, favorites, edits) and runs BackupZip/PocketZip/PlaylistZip.export
  - Script runs xcodebuild test -only-testing:PocketDJTests/FixtureExportTests on the iOS Simulator (TEST_RUNNER_PDJ_FIXTURE_OUT, CODE_SIGNING_ALLOWED=NO) and writes android/app/src/test/resources/backup/ios-real/*
  - Kotlin test imports each fixture and asserts the expected model; amPlaylistId absent in exports (ANS-COL-1)
  - No real user library data in fixtures
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** IosRealFixtureTest; FixtureExportTests (Swift)
- **Emulator / device verification:**
  - n/a (simulator + JVM); record command + resulting file hashes in status
  - Device-only: None.
- **Ledger rows to update:** COL-14

#### ANS-BRW-2 — Rec-engine enrollment secret fetched at runtime (rotatable) + Add-to sheet uses RecSuggestionFilter

- **Answers:** Q69 · **Area:** browse · **Size:** M (~600 lines) · **Priority:** P1 · **Depends on:** ANS-COL-5
- **Goal:** The enroll secret can be rotated server-side without an app update; the Add-to sheet's suggestions use the tested filter.
- **Needs Levi:** AWS deploy of rec-engine + listening-pockets Lambdas to green (AWS_PROFILE=llc) and publishing the endpoints doc (CONFIG_ONLY=1 scripts/deploy.sh prod)
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/config/RemoteEndpoints.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/config/Endpoints.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/recs/RecEngineClient.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/recs/RecommendationService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/CollectionsGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/BrowseGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/collections/AddToActions.kt`
  - `config/endpoints.green.json`
  - `config/endpoints.blue.json`
  - `scripts/validate-endpoints.ts`
  - `scripts/lambda/rec-engine/index.mjs`
  - `scripts/lambda/rec-engine/deploy.sh`
  - `scripts/lambda/rec-engine/test-rec-engine.mjs`
  - `scripts/lambda/listening-pockets/index.mjs`
  - `scripts/lambda/listening-pockets/deploy.sh`
  - `scripts/lambda/listening-pockets/test-listening-pockets.mjs`
  - `android/app/src/test/java/com/levi/pocketdj/data/config/RemoteEndpointsTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/collections/AddToActionsTest.kt`
- **Acceptance:**
  - Endpoints doc gains optional `capabilities.recEngineEnroll`; parsed, persisted with the last-good doc, compiled constant is the fallback; every call site takes a () -> String provider
  - Both Lambdas accept comma-separated REC_ENROLL_SECRETS (old+new, constant-time, fail closed); deploy.sh files updated; Lambda tests cover rotation
  - validate-endpoints accepts the new key; iOS ignores unknown keys (documented; iOS adoption optional)
  - AddToActions.suggestedTargets calls RecSuggestionFilter.resolveTargets (AddToPlaylistMenu/AddToCollectionSheet untouched - polish-gated)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** RemoteEndpointsTest: capability parse, persistence, fallback; Lambda tests: old+new secrets accepted, other rejected; AddToActionsTest: filter applied
- **Emulator / device verification:**
  - Serve a local endpoints.json with a new secret via debug base; rec calls carry it (mock server log)
  - Song long-press > Add to: Suggested rows match RecSuggestionFilter output
  - Device-only: None.
- **Ledger rows to update:** BRW-13

#### ANS-STU-4 — Mic/import/carve samples move to the SAF user folder (iOS-like), playback via the materializer

- **Answers:** Q23 · **Area:** studio · **Size:** M (~300 lines) · **Priority:** P2 · **Depends on:** ANS-STU-1, ANS-STU-3
- **Goal:** New samples land in the user's chosen folder like takes do.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/studio/store/StudioStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/SampleFactory.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/MicRecorder.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/TakeRenderer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/demux/DemuxExports.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/SampleRenderCache.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/SampleFactoryTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/MicRecorderLifecycleTest.kt`
- **Acceptance:**
  - StudioStore.addSampleRelocating (patterned on addTakeRelocating) used by every creator; mic samples finalize in app storage first (crash-safe) then move
  - SampleRenderCache/Loops/Sequencer resolve SAF samples through StudioMaterializer; usageBytes and delete handle SAF refs
  - Revoked folder falls back to app root with a visible notice
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** SampleFactoryTest: SAF destination; MicRecorderLifecycleTest: finalize then relocate; reconcile test for SAF samples
- **Emulator / device verification:**
  - With a SAF Samples folder set: record a mic sample -> file in the folder; it plays in Loops and Sequencer
  - Device-only: SD card.
- **Ledger rows to update:** STU-3

#### ANS-STU-5 — Tracks paging part B: clip windows as PCM16 page files with read-ahead

- **Answers:** Q97 · **Area:** studio · **Size:** L (~900 lines) · **Priority:** P1 · **Depends on:** ANS-STU-2, ANS-STU-3
- **Goal:** Arranger playback memory is bounded by the read-ahead window, not the arrangement length.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/ClipPageStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/ClipReader.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/MultitrackRenderContext.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/MultitrackPlayer.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/ClipPageStoreTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/MultitrackPlayerPagingTest.kt`
- **Acceptance:**
  - Each stretched clip window cached as PCM16 file; Clip reads through ClipReader (mmap) with a feeder touching pages a few seconds ahead; short clips keep the in-memory path
  - No allocation on the render callback; seeks re-prime the feeder; cache invalidated on clip edit
  - OutOfMemory 'too long' toast path no longer reachable for <= 60 min arrangements in test
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ClipPageStoreTest: write/read/invalidate; MultitrackPlayerPagingTest: paged == in-memory render (bit-exact on PCM16 grid)
- **Emulator / device verification:**
  - Build a 30-minute arrangement from 6 long clips; play + seek; dumpsys meminfo Java heap stays flat
  - Device-only: Low-RAM device glitch check.
- **Ledger rows to update:** STU-11, STU-12

#### ANS-MIX-3 — Mix returns after process death (launch park + Auto Mix row) and Mix disk work off Main

- **Answers:** Q18, Q96 · **Area:** mix · **Size:** M (~530 lines) · **Priority:** P1 · **Depends on:** ANS-MIX-2
- **Goal:** After process death the parked mix is visible on the lock screen / Auto / Mix tab; loadNow, restore and the sessions flush no longer touch disk on Main.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/PocketDjApplication.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/engine/MixEngine.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/engine/AutoDj.kt`
  - `android/app/src/main/java/com/levi/pocketdj/auto/AutoMixTab.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/store/MixSessionStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/store/MixDeckSessionStore.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/engine/MixEnginePersistenceTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/engine/AutoDjTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/store/MixSessionStoreFlushTest.kt`
- **Acceptance:**
  - MixGraph.launchRestore(): snapshot read off Main, MixEngine.parkRestore(snap) on Main; called from PocketDjApplication's first-foreground hook (not MainActivity/AppGraph)
  - AutoMixTab calls materializePendingRestoreIfNeeded('autoRow') (CarPlay parity)
  - Auto-DJ prepared-load cache: next 1-2 items prepared off Main; loadNow uses it, sync prepare only on miss; restore prepares both decks off Main then commits atomically
  - Sessions stores snapshot under lock, encode on the writer thread; ON_STOP flush hands off (no 2.5 s runBlocking wait)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** MixEnginePersistenceTest: launch park from file; AutoDjTest: cached prepare used; MixSessionStoreFlushTest: encode off lock
- **Emulator / device verification:**
  - Load two decks, am kill, relaunch to History (not Mix): dumpsys media_session shows the parked Mix; open Mix: decks cued
  - StrictMode (debug) disk-read-on-main: no violations from mix/* during Auto-DJ transitions
  - Device-only: Jank profile.
- **Ledger rows to update:** MIX-5, MIX-9

### Wave 5 — Deep links + assetlinks, jukebox AM match, AM playlist reconcile, backup merges, pockets Settings row, ShazamKit

#### ANS-SURF-2 — Deep links finished: play/setlist through ShellActions + assetlinks.json so https jukebox links open the app

- **Answers:** Q12, Q3 · **Area:** surfaces · **Size:** S (~200 lines) · **Priority:** P1 · **Depends on:** —
- **Goal:** Every pocketdj:// and https://jukebox.pocket-dj.com link lands on its real seam; App Links verify.
- **Needs Levi:** Release signing fingerprints (release plan A3) + Play App Signing cert (Play Console), and OK to upload to the jukebox CloudFront/S3 site (profile levi) + invalidate
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/shell/ShellActions.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/ShellGraph.kt`
  - `scripts/jukebox-site/.well-known/assetlinks.json`
  - `scripts/jukebox-site/README-universal-links.md`
  - `scripts/publish-jukebox-wellknown.sh`
  - `android/app/src/test/java/com/levi/pocketdj/shell/DeepLinkDispatcherTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/shell/ShellActionsTest.kt`
- **Acceptance:**
  - ShellActions.playSetlist(id, shuffle) used by playItem for play/setlist
  - assetlinks.json lists debug + direct-signing + Play App Signing SHA-256 fingerprints; served 200 application/json no redirect
  - publish script uploads both .well-known files and invalidates CloudFront
  - Ledger SURF-4 row: seams all assigned
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** DeepLinkDispatcherTest: every link kind reaches its seam; ShellActionsTest: playSetlist
- **Emulator / device verification:**
  - adb shell am start -d pocketdj://jukebox/<id>, pocketdj://play/pocket/<id>, pocketdj://play/setlist/<id>, open a .pdjcollection: each lands correctly
  - After publish (debug fingerprint): adb shell pm verify-app-links --re-verify com.levi.pocketdj; pm get-app-links shows jukebox.pocket-dj.com verified
  - Device-only: Release-cert verification on a phone.
- **Ledger rows to update:** SURF-4

#### ANS-GAP-1 — Jukebox Apple Music catalog match stage (SURF-10 placementSink/externalMatch) + jukebox onStart bootstrap

- **Answers:** Q60, Q75 · **Area:** surfaces · **Size:** M (~350 lines) · **Priority:** P2 · **Depends on:** —
- **Goal:** Guest requests that are not in the library are matched against the AM catalog (iOS parity); the jukebox resumes on app start.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/jukebox/JukeboxRepository.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/jukebox/JukeboxGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/jukebox/JukeboxAppleMusicMatch.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/jukebox/JukeboxAppleMusicMatchTest.kt`
- **Acceptance:**
  - externalMatch implemented over AppleMusicApi catalog search (dev token); placementSink places matched rows (AM row / rip) like iOS
  - SURF-2 jukebox onStart bootstrap wired
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** JukeboxAppleMusicMatchTest (MockWebServer)
- **Emulator / device verification:**
  - Local broker + pdj.amApiBase mock: a guest request for a non-library song shows as matched
  - Device-only: Real AM catalog.
- **Ledger rows to update:** SURF-10, SURF-2

#### ANS-GAP-2 — COL-9 complete: AM playlist sync reconcile (removals/reorders) + private-server branch

- **Answers:** Q75 · **Area:** collections · **Size:** M (~500 lines) · **Priority:** P2 · **Depends on:** ANS-COL-1
- **Goal:** Apple Music playlist sync matches iOS for removals and reorders.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/applemusic/PlaylistAppleMusicSync.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/applemusic/AMPlaylistSyncClient.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/applemusic/PlaylistAppleMusicSyncReconcileTest.kt`
- **Acceptance:**
  - Reconcile ports iOS PlaylistAppleMusicSync removals + reorders (with the 'empty != deletion' guard)
  - Private-server branch ported
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** PlaylistAppleMusicSyncReconcileTest
- **Emulator / device verification:**
  - MockWebServer Lambda: remove + reorder in a linked playlist -> PATCH payload matches iOS fixture
  - Device-only: Real AM account.
- **Ledger rows to update:** COL-9

#### ANS-GAP-4 — COL-14 complete: onPortableItems materialization + backup merges sources/edits/favorites

- **Answers:** Q75 · **Area:** collections · **Size:** M (~450 lines) · **Priority:** P2 · **Depends on:** ANS-COL-1, ANS-PB-1
- **Goal:** Imported backups/.pdjcollection files restore everything iOS exports.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/io/PortableItems.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/backup/BackupZip.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/backup/BackupModels.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/backup/CollectionShare.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/backup/BackupMergeTest.kt`
- **Acceptance:**
  - onPortableItems seam wired (materialize studio/profile items)
  - BackupSources.merge + edits + favorites applied on restore (SET-2)
  - Profile song ids excluded from items.json once ANS-STU-7 lands (guarded by isProfileSongId)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** BackupMergeTest
- **Emulator / device verification:**
  - Restore an iOS real backup fixture (ANS-SVC-2 later re-run) on the emulator: favorites + edits present
  - Device-only: None.
- **Ledger rows to update:** COL-14

#### ANS-BRW-4 — Settings 'Find my listening pockets' row (sets ANSWERED)

- **Answers:** Q89, Q91 · **Area:** browse · **Size:** S (~120 lines) · **Priority:** P1 · **Depends on:** ANS-GM-2
- **Goal:** Pockets can be turned on/off from Settings > Recommendations like iOS.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/sections/RecommendationsSection.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/settings/RecommendationsSectionTest.kt`
- **Acceptance:**
  - Third SwitchRow shown when recommendations are on; writes LISTENING_POCKETS_ENABLED and LISTENING_POCKETS_ANSWERED=true (Q91a); consent text when off; shows pockets sync errors (iOS SettingsView:829-843)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** RecommendationsSectionTest
- **Emulator / device verification:**
  - Toggle on: POST /pockets/events to the pdj.pocketsBase mock; History no longer offers the opt-in
  - Device-only: None.
- **Ledger rows to update:** COL-17, COL-18

#### ANS-BRW-5 — ShazamKit for Android 2.1.1: vendor the AAR, reuse the MusicKit developer token, live recognition backend

- **Answers:** Q84 · **Area:** browse · **Size:** M (~500 lines) · **Priority:** P2 · **Depends on:** —
- **Goal:** The recognizer button works for real in release builds.
- **Files:**
  - `android/app/libs/shazamkit-android-release.aar`
  - `android/app/build.gradle.kts`
  - `android/gradle/libs.versions.toml`
  - `android/app/src/main/java/com/levi/pocketdj/screens/shazam/ShazamKitBackend.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/BrowseGraph.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/shazam/ShazamKitBackendTest.kt`
- **Acceptance:**
  - ShazamKit for Android 2.1.1 AAR copied from ~/.config/pocketdj/vendor/shazamkit-android-release.aar into android/app/libs (same pattern as the vendored mediaplayback AAR); R8 keep rules verified in assembleRelease
  - Developer token = the existing rip-server GET /musickit-token via MusicKitDeveloperTokenClient (key 9JRN4H68X4 already has Media Services: MusicKit + ShazamKit) - no new key, no server change
  - ShazamKitBackend: createShazamCatalog + streaming session fed by AudioRecord 48 kHz mono PCM16 with timeout; MatchResult -> RecognitionResult; assigned in BrowseGraph for release; DebugListeningBackend stays debug-selectable
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ShazamKitBackendTest (fake session): match/no-match/timeout/cancel
- **Emulator / device verification:**
  - Release-config build installs; button visible; emulator mic likely silent -> no-match path only
  - Device-only: Live recognition (mic + native libs).
- **Ledger rows to update:** BRW-17

### Wave 6 — Profile source A, Discover/rec gaps, soft-cap prune, stem carve

#### ANS-STU-7 — Profile custom-audio source part A: ProfileSourceStore/ProfileAudioStore + catalog merge + playback/Mix lookups

- **Answers:** Q61 · **Area:** studio · **Size:** L (~750 lines) · **Priority:** P1 · **Depends on:** ANS-MIX-3, ANS-STU-4
- **Goal:** Android has the iOS 'Pocket DJ' profile source that demuxes (and later other studio media) are saved into.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/profile/ProfileSourceStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/profile/ProfileAudioStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/profile/ProfileRowResolver.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/CollectionsGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/StudioGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/profile/ProfileSourceStoreTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/profile/ProfileRowResolverTest.kt`
- **Acceptance:**
  - ingest(kind=.demux, ...) copies original + stems into 'Pocket DJ Demuxes', mints pdj_ ids, artist = profile name (iOS ProfileSourceStore parity)
  - Synthetic index joins syntheticDocuments; pdj_ rows resolve for playback and Mix (BurnStoreTrackResolver/isOnDisk lookup); reset + Storage include it
  - Browse source filter label works without editing screens/browse/* (verify synthetic sourceName pickup; else defer label to post-gate)
  - No cloud sync (micro-decision)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ProfileSourceStoreTest; ProfileRowResolverTest
- **Emulator / device verification:**
  - Debug ingest a fixture demux: song appears in Browse under 'Pocket DJ', plays, loads on a Mix deck
  - Device-only: Real stems.
- **Ledger rows to update:** STU-14, STU-15

#### ANS-GAP-3 — BRW-16/BRW-13 gaps: pre-release album refresh, 'Add to Apple Music again' retry UI, enqueueAudioAnalysis producer

- **Answers:** Q60, Q75 · **Area:** browse · **Size:** M (~450 lines) · **Priority:** P2 · **Depends on:** ANS-BRW-1, ANS-BRW-2
- **Goal:** Discover adds and the rec engine have no remaining PARTIAL code gaps.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/discover/DiscoverAddController.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/discover/DiscoverAddsStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/recs/RecommendationService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/discover/DiscoverRetryRow.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/discover/DiscoverRetryTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/recs/AudioAnalysisEnqueueTest.kt`
- **Acceptance:**
  - Pre-release album rows re-checked on release day (iOS prerelease refresh)
  - Retry UI for failed AM writes
  - enqueueAudioAnalysis produced for newly added songs (iOS parity)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** DiscoverRetryTest; AudioAnalysisEnqueueTest
- **Emulator / device verification:**
  - Fail an AM write (mock 500): retry row appears; retry succeeds against the mock
  - Device-only: Real AM write.
- **Ledger rows to update:** BRW-16, BRW-13

#### ANS-GAP-5 — Storage soft-cap prune (SURF-2) + BurnStore yieldBackgroundDownload wired from adoptStreamedFile (TODO SVC-3)

- **Answers:** Q60 · **Area:** services · **Size:** S (~250 lines) · **Priority:** P2 · **Depends on:** ANS-COL-4
- **Goal:** Storage manager prunes to the soft cap like iOS; streamed Mix files yield background downloads.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/storage/StorageManager.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/BurnStore.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/storage/StorageSoftCapTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/burns/BurnStoreYieldTest.kt`
- **Acceptance:**
  - Soft-cap prune (LRP, protected sets respected, one-scan plan, chunked async - the iOS 10-23 crash-loop lesson)
  - adoptStreamedFile calls yieldBackgroundDownload (MixStreamLoader)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** StorageSoftCapTest; BurnStoreYieldTest
- **Emulator / device verification:**
  - Set cap below usage, cold start: prune runs once off Main, logs freed bytes, no ANR
  - Device-only: None.
- **Ledger rows to update:** SURF-2, SVC-3

#### ANS-GAP-6 — STU-3 stem carve: Samples 'from track' can carve a stem

- **Answers:** Q60 · **Area:** studio · **Size:** M (~350 lines) · **Priority:** P2 · **Depends on:** ANS-STU-4
- **Goal:** Samples tab carves from a song's stems like iOS.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/samples/FromTrackSheet.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/engine/StemCarve.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/engine/StemCarveTest.kt`
- **Acceptance:**
  - Pick vocals/drums/bass/other from a stemmed burn and carve a sample range (iOS parity)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** StemCarveTest
- **Emulator / device verification:**
  - With a seeded stemmed burn fixture: carve 4 s of drums -> new sample plays
  - Device-only: None.
- **Ledger rows to update:** STU-3

### Wave 7 — Profile sync go-live (C1), Demux save, Recently-added producer

#### ANS-SYNC-1 — Profile sync go-live (conflict C1 proposal): runtime enroll token, opt-in default OFF, search keys stay device-local, imported-songs SyncEntry

- **Answers:** Q5, Q42, Q52, Q54, Q66, Q10, Q75 · **Area:** services · **Size:** M (~350 lines) · **Priority:** P1 · **Depends on:** ANS-BRW-2, ANS-COL-3, ANS-STU-7
- **Goal:** Profile sync works end to end on green when the user opts in, and never otherwise.
- **Needs Levi:** DECISION C1 first. Then: AWS_PROFILE=llc scripts/lambda/profile-sync/deploy.sh (green), commit config/endpoints.green.json, publish the endpoints doc; a second device/emulator pair for link-a-device
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/sync/Enrollment.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/sync/ProfileSecretStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/sync/SyncSettings.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/ServicesGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/credentials/SettingsCredentialsDocument.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/CollectionsGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/sections/ProfileSection.kt`
  - `scripts/lambda/profile-sync/deploy.sh`
  - `config/endpoints.green.json`
  - `android/app/src/test/java/com/levi/pocketdj/data/sync/EnrollmentTokenTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/credentials/SettingsCredentialsDocumentTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/reset/AccountDeletionTest.kt`
- **Acceptance:**
  - Enroll token delivered through the endpoints-doc capabilities channel (ANS-BRW-2), never hard-coded; Enrollment reads it
  - 'Sync across devices' default OFF; no enroll/upload until the user turns it on
  - search key/secret/endpoint removed from the Android settings-credentials doc (Q10 keystore-local)
  - SyncEntry('imported-songs') with reloadFromDisk + account-deletion key list (SVC-13 lockstep test count updated) - Q75(b)
  - Account deletion verified against the real DELETE /profile; cross-device 'profile not found' after delete (Q66)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** EnrollmentTokenTest; SettingsCredentialsDocumentTest: no search fields; AccountDeletionTest: key count
- **Emulator / device verification:**
  - Two emulator instances against green: enable sync on A, link B by code, a pocket made on A appears on B; Delete account on A -> B shows 'profile not found'
  - Device-only: Real cross-device restore.
- **Ledger rows to update:** SVC-7, SVC-8, SVC-9, SVC-10, SVC-13

#### ANS-STU-8 — Profile custom-audio source part B: Demuxer 'Save to Pocket DJ library' + Add-to

- **Answers:** Q61 · **Area:** studio · **Size:** M (~550 lines) · **Priority:** P1 · **Depends on:** ANS-STU-7
- **Goal:** iOS StudioDemuxView.saveDemux parity.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/demux/DemuxTimeline.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/producer/demux/DemuxScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/demux/DemuxStore.kt`
  - `android/app/src/test/java/com/levi/pocketdj/studio/demux/DemuxSaveTest.kt`
- **Acceptance:**
  - Share-arrow button left of follow; saves original + stems (burned set, else demux cache) via ProfileSourceStore.ingest; then opens the existing Add-to sheet (no edit to AddToCollectionSheet)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** DemuxSaveTest
- **Emulator / device verification:**
  - Demux a seeded song, Save: song appears under Pocket DJ source; Add-to sheet adds it to a pocket; plays from the pocket
  - Device-only: Real stem audio.
- **Ledger rows to update:** STU-14

#### ANS-GAP-8 — COL-12/BRW-7 gaps: Android catalogAdd producer + timeline artwork thumbnails (owner gate stays per Q56)

- **Answers:** Q60 · **Area:** collections · **Size:** M (~350 lines) · **Priority:** P2 · **Depends on:** ANS-GAP-3
- **Goal:** Recently added counts Android-side adds; timeline rows show artwork.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/RecentlyAdded.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/activity/ActivityModels.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/discover/DiscoverAddsStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/history/ActivityRows.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/collections/RecentlyAddedProducerTest.kt`
- **Acceptance:**
  - Discover/recognizer/import adds emit catalogAdd
  - Timeline rows load artwork via ArtworkCache (not AlbumArtworkStore, polish-owned)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** RecentlyAddedProducerTest
- **Emulator / device verification:**
  - Add an album from Discover: Collections > Recently added shows it as Yours
  - Device-only: None.
- **Ledger rows to update:** COL-12, BRW-7

### Wave 8 — POLISH GATE: PlaybackController pass, HeldQueue resumption, clause op, studio rows, games deep links, Mix sessions gaps

> **Gate:** feat/android-ui-polish merged to main; rebase integration branch.

#### ANS-PB-5 — PlaybackController pass: song-length rip wait cap, one POST /rip per row, Mix resign-on-idle + yield-on-resume, Browse-play outcomes

- **Answers:** Q17, Q21, Q95, Q89 · **Area:** playback · **Size:** M (~650 lines) · **Priority:** P0 · **Depends on:** ANS-PB-1, ANS-PB-3, ANS-MIX-3 · **Polish-gated**
- **Goal:** All answered PlaybackController changes in ONE package/commit series after the polish merge.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackController.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/session/ResolvingSongDataSource.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/PlayerPort.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/SetlistSequencer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/service/MixSessionPlayer.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/PlaybackGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/outcome/DirectPlaySampler.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/CloudRowResolverTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/SequencerHealthTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/session/SessionSwitchboardTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/outcome/DirectPlaySamplerTest.kt`
- **Acceptance:**
  - Q17: begin(songId, capMs) / awaitDurable(job, capMs); cap = item length (catalog fallback, then 10 min) + 60 s slack; RIP_WAIT_CAP_MS constant removed
  - Q21: instrument begin(via=load|watch|retry, gen) first and record the trace in status; then begin joins an in-flight resolution unless PlayRequest.reResolve; sequencer skips a duplicate port.load for the same uid+generation. Exactly one `rip-post begin` per row
  - Q95: Mix park runnable resigns the Mix owner (re-claims on next onAudioStarted); Mix/Auto-DJ stop resigns; resume() calls SessionSwitchboard.yieldMixToExo() before play()
  - Q89c: DirectPlaySampler feeds SkipTracker for single Browse plays (1 Hz samplePosition, noteNaturalEnd on ENDED, checkpoint on replace/stop) -> listenedFraction/outcome no longer 'unknown'
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** CloudRowResolverTest: cap from length; twoLoadsSameRow_onePost; retryInPlace_rePosts; SequencerHealthTest: play during start does not reload; SessionSwitchboardTest: idle Mix resign hands remote play to Exo; DirectPlaySamplerTest
- **Emulator / device verification:**
  - Mock rip server counting POSTs: play a 12-row run with 4 un-ripped rows: exactly 4 POSTs
  - Idle a Mix 20 s, pause a single, `cmd media_session dispatch play`: single resumes (switchboard owner=exo)
  - Browse single play skipped at 30 %: pockets upload carries outcome skipped + fraction
  - Device-only: Auto/widget/BT routing after a Mix.
- **Ledger rows to update:** PB-3, PB-2, MIX-11, COL-17, PB-5

#### ANS-PB-6 — PB-4 HeldQueue: resume the last queue from notification/Bluetooth after process death (no PARTIAL)

- **Answers:** Q15 · **Area:** playback · **Size:** M (~450 lines) · **Priority:** P0 · **Depends on:** ANS-PB-1 · **Polish-gated**
- **Goal:** PLAY after the process died restarts the service and resumes the held run at its offset.
- **Files:**
  - `android/app/src/main/AndroidManifest.xml`
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/durable/HeldQueue.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/durable/ResumptionProvider.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/session/SequencerForwardingPlayer.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/durable/HeldQueueTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/durable/ResumptionSnapshotTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/session/SequencerForwardingPlayerTest.kt`
- **Acceptance:**
  - androidx.media3.session.MediaButtonReceiver declared (MEDIA_BUTTON)
  - onPlaybackResumption returns MediaItemsWithStartPosition built off Main from HeldQueue (songId/title/artist/art/clip, index, positionMs); duplicate Main decode removed
  - SequencerForwardingPlayer routes that set to SessionRestorer.restore + resumeFromHold (never clears the run)
  - onGetLibraryRoot answers isRecent with a cheap root + one recent child from the snapshot (no AppGraph build)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** HeldQueueTest; ResumptionSnapshotTest; SequencerForwardingPlayerTest: resumption -> resumeFromHold
- **Emulator / device verification:**
  - Play seed queue, kill the pid (am kill / kill, not force-stop), adb shell input keyevent KEYCODE_MEDIA_PLAY: service restarts and the same row resumes at the held offset (dumpsys media_session)
  - Device-only: BT/AVRCP, System UI resume card after reboot.
- **Ledger rows to update:** PB-2, PB-4

#### ANS-BRW-3 — Filter clause: changing the operator keeps the value (iOS parity)

- **Answers:** Q32 · **Area:** browse · **Size:** S (~30 lines) · **Priority:** P2 · **Depends on:** — · **Polish-gated**
- **Goal:** BRW-2 matches iOS FilterSheet.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/browse/ClauseEditor.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/browse/ClauseEditorTest.kt`
- **Acceptance:**
  - changeOp(c, op) = c.copy(op = op); only a field change clears values (History hide-skips already applied - ledger fixed)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** ClauseEditorTest
- **Emulator / device verification:**
  - Filter BPM > 120, change to <: value 120 kept
  - Device-only: None.
- **Ledger rows to update:** BRW-2

#### ANS-STU-6 — Studio rows tappable + artist = PocketDJ name; clean-only explicit rows dimmed; silent no-catalog return shows an error

- **Answers:** Q50, Q94 · **Area:** studio · **Size:** S (~180 lines) · **Priority:** P2 · **Depends on:** ANS-COL-3, ANS-PB-1 · **Polish-gated**
- **Goal:** Studio items play from their row and read as the user's own; skipped explicit rows are visibly dimmed.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/StudioItemRow.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/PocketDetailScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/playlists/PlaylistDetailScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/collections/CollectionCatalog.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/AppGraph.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/collections/RealizeStudioEntriesTest.kt`
- **Acceptance:**
  - Row tap plays that item (playNow) and opens Now Playing
  - studioArtist = profile name, fallback 'Pocket DJ' (one line in AppGraph collections lazy)
  - Rows that ANS-PB-1 marks cleanOnlySkip are dimmed (iOS PocketsView:96)
  - PlaylistDetailScreen 'catalog not wired yet' silent return -> error snackbar
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** RealizeStudioEntriesTest: artist from profile
- **Emulator / device verification:**
  - Pocket with a studio take: tap row -> plays, subtitle shows the profile name
  - Device-only: None.
- **Ledger rows to update:** STU-7

#### ANS-GM-3 — Games deep links: pocketdj://games/puzzle and /inthepocket

- **Answers:** Q43 · **Area:** games · **Size:** S (~200 lines) · **Priority:** P2 · **Depends on:** ANS-GM-2, ANS-SURF-2 · **Polish-gated**
- **Goal:** Gem Collector and In the Pocket open from a link (and from the Q7 More tab layout).
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/shell/DeepLinkParser.kt`
  - `android/app/src/main/java/com/levi/pocketdj/shell/DeepLinkDispatcher.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/GamesGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/games/GamesRoutes.kt`
  - `android/app/src/test/java/com/levi/pocketdj/shell/DeepLinkParserTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/screens/games/GamesDeepLinkTest.kt`
- **Acceptance:**
  - DeepLink.Game(kind); GamesGraph deep-link handler posts the Games route (wherever Q7 put it) + pendingGame; GamesRoute consumes with LaunchedEffect
  - No new ShellRoute subtype (avoids exhaustive whens)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** DeepLinkParserTest; GamesDeepLinkTest
- **Emulator / device verification:**
  - adb shell am start -d pocketdj://games/puzzle opens Gem Collector cold and warm
  - Device-only: None.
- **Ledger rows to update:** GM-4

#### ANS-GAP-7 — MIX-15 complete: sessions CSV export, load-card song metadata sheet, tablet wrapped layout

- **Answers:** Q60, Q75 · **Area:** mix · **Size:** M (~450 lines) · **Priority:** P2 · **Depends on:** ANS-MIX-3 · **Polish-gated**
- **Goal:** Mix sessions screen has no PARTIAL omissions.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/screens/mix/MixSessionsScreen.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/mix/MixReplayTimeline.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/store/MixSessionCsv.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/store/MixSessionCsvTest.kt`
- **Acceptance:**
  - CSV export (iOS columns)
  - Tap a load card -> song metadata sheet
  - Wrapped tablet layout at >= 600dp
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** MixSessionCsvTest
- **Emulator / device verification:**
  - Sessions > Export CSV saves; wm size 1280x800 + density 240: wrapped layout
  - Device-only: None.
- **Ledger rows to update:** MIX-15

### Wave 9 — Playback off-main

#### ANS-PB-7 — Playback disk work off Main: local-file resolvers, ledger-only rowOnDevice, async Auto root/search

- **Answers:** Q96 · **Area:** playback · **Size:** M (~350 lines) · **Priority:** P1 · **Depends on:** ANS-PB-6, ANS-GAP-5
- **Goal:** No java.io/SAF access on Main at row start, in the stall hop, or in Android Auto binder callbacks.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/RowSourceResolver.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/sequencer/BurnedRowResolver.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/PlaybackGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/burns/BurnStore.kt`
  - `android/app/src/main/java/com/levi/pocketdj/auto/AppAutoServices.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/BurnedRowResolverTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/playback/sequencer/ResolveLadderTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/auto/AutoAsyncRootTest.kt`
- **Acceptance:**
  - LocalFile/Burned resolvers resolve on an injected IO dispatcher
  - seq.rowOnDevice = ledger-only BurnStore.isReadyInLedger (no disk) set in PlaybackGraph before studioGraph.wire chains
  - onGetLibraryRoot static; auto graph built async with futures; onGetSearchResult miss computed on Default with SettableFuture
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** BurnedRowResolverTest: dispatcher; ResolveLadderTest; AutoAsyncRootTest
- **Emulator / device verification:**
  - Debug StrictMode detectDiskReads on main: play a 20-row burned run + stall hop: zero violations from playback/*
  - Auto browse smoke (pdj.autoDump) still walks the tree
  - Device-only: On-device profile with SAF trees.
- **Ledger rows to update:** PB-1, SURF-8

### Wave 10 — Minimal background graph

#### ANS-SHELL-1 — Minimal background graph: workers/receivers start only the core; interactive loops gated

- **Answers:** Q98 · **Area:** surfaces · **Size:** M (~650 lines) · **Priority:** P1 · **Depends on:** ANS-PB-7, ANS-MIX-3, ANS-SURF-2, ANS-BRW-5 · **Polish-gated**
- **Goal:** A WorkManager or receiver cold start builds settings/secrets/http/services/rips/collections only; the 1 Hz tick, 4 Hz npdsp heartbeat, widget poll and recs flush start only for UI/playback.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/di/AppGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/PocketDjApplication.kt`
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/PlaybackGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/BrowseGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/di/ShellGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/widget/WidgetBridge.kt`
  - `android/app/src/test/java/com/levi/pocketdj/di/BackgroundStartTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/di/BrowseGraphRecsWiringTest.kt`
- **Acceptance:**
  - Interactive init blocks moved to idempotent AppGraph.startInteractive() (first foreground) and startPlayback() (PlaybackService.onCreate / Auto); workers never start them
  - Session tick only while a run exists; npdsp heartbeat flow-driven while engaged/Mix running; widget owner poll replaced by SessionSwitchboard.onChange
  - Pure startup-plan seam tested (no Robolectric)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** BackgroundStartTest: worker start plan excludes loops; foreground includes; BrowseGraphRecsWiringTest
- **Emulator / device verification:**
  - App not running: adb shell cmd jobscheduler run -f com.levi.pocketdj <id>: logcat shows no session tick / npdsp heartbeat / widget poll lines
  - Normal launch: all loops start; widget updates
  - Device-only: Doze timing.
- **Ledger rows to update:** SURF-2, SURF-7

### Wave 11 — Location per C2, Mix on Oboe

#### ANS-LOC-1 — Location per conflict C2: foreground opt-in permission, no ACCESS_BACKGROUND_LOCATION, location FGS type while music plays

- **Answers:** Q89, Q93 · **Area:** collections · **Size:** S (~250 lines) · **Priority:** P1 · **Depends on:** ANS-SHELL-1 · **Polish-gated**
- **Goal:** Places & trips keep stamping background plays without the background-location permission.
- **Needs Levi:** DECISION C2 (proposal vs keep background in the direct flavor); Play FGS-location declaration at submission
- **Files:**
  - `android/app/src/main/AndroidManifest.xml`
  - `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackService.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/location/FusedVisitSource.kt`
  - `android/app/src/main/java/com/levi/pocketdj/data/location/LocationSettings.kt`
  - `android/app/src/main/java/com/levi/pocketdj/screens/settings/sections/ListeningLocationSection.kt`
  - `android/app/src/test/java/com/levi/pocketdj/data/location/LocationFgsPolicyTest.kt`
  - `android/app/src/test/java/com/levi/pocketdj/ManifestPermissionsTest.kt`
- **Acceptance:**
  - ACCESS_BACKGROUND_LOCATION removed; 'Allow Always' rows + hint removed; COARSE+FINE requested from the toggle (Q89 'request permission')
  - PlaybackService adds FOREGROUND_SERVICE_TYPE_LOCATION only while audio plays AND places is on AND while-in-use granted; drops it otherwise
  - FusedVisitSource/LocationSettings never assume a background grant; coarse-only -> hints only (Q93 default)
  - Merged-manifest test asserts no background permission
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** LocationFgsPolicyTest; ManifestPermissionsTest
- **Emulator / device verification:**
  - Grant while-in-use, play seed queue, Home: dumpsys activity services shows PlaybackService types mediaPlayback|location; stop playback: location type dropped
  - Run the COL-20 emulator geo-fix sequence (gps provider) - the step COL-20 left unrun
  - Device-only: Real dwell/trip detection with screen off.
- **Ledger rows to update:** COL-20

#### ANS-MIX-4 — Mix sink on Oboe (Q6b) via StudioOutputs.chooseBackend

- **Answers:** Q6 · **Area:** mix · **Size:** S (~250 lines) · **Priority:** P2 · **Depends on:** ANS-MIX-2, ANS-SHELL-1
- **Goal:** Real devices render the Mix through Oboe; emulator stays on AudioTrack.
- **Files:**
  - `android/app/src/main/java/com/levi/pocketdj/di/MixGraph.kt`
  - `android/app/src/main/java/com/levi/pocketdj/mix/service/MixRecovery.kt`
  - `android/app/src/main/java/com/levi/pocketdj/studio/audio/StudioOutputs.kt`
  - `android/app/src/test/java/com/levi/pocketdj/mix/engine/MixSinkParkTest.kt`
- **Acceptance:**
  - Both Mix sink factories use StudioOutputs.chooseBackend; MixRecovery re-prime assumptions re-checked for OboeSink (route change, park/restart)
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** MixSinkParkTest: Oboe-like fake sink park/resume
- **Emulator / device verification:**
  - Emulator still uses AudioTrackSink (log backend=audiotrack); Mix plays
  - Device-only: Oboe latency + route changes on a phone.
- **Ledger rows to update:** MIX-5, MIX-11

### Wave 12 — No-PARTIAL verification sweep + device checklist

#### ANS-VERIFY-1 — 'No PARTIAL anywhere' sweep: run every remaining PARTIAL row's emulator steps, refresh the ledger, write the device checklist

- **Answers:** Q75, Q60 · **Area:** services · **Size:** M (~100 lines) · **Priority:** P1 · **Depends on:** ANS-LOC-1, ANS-MIX-4, ANS-SYNC-1, ANS-GAP-7
- **Goal:** Every ledger row is DONE, or DONE except an explicitly named device-only item, or an explicit Levi 'default' deferral.
- **Needs Levi:** Phone session for the device checklist (Q9 decoder warm-up, Q13 AAC priming, Q36, Q41, Q84, Q86, Q6 quality, Q15 BT)
- **Files:**
  - `docs/ARCHITECTURE-ANDROID.md`
  - `android/specs/answers/PROGRESS.md`
  - `android/specs/answers/DEVICE-CHECKLIST.md`
- **Acceptance:**
  - Each PARTIAL/Planned ledger row (SURF-2/3/5/6/7/8/9, SVC-1/4/7-11/14, PB-5/10, COL-6/7/10/12/18/20, BRW-10/12/13/16/17, MIX-5/11-18, STU-3 ...) re-checked: emulator steps run, code gaps either fixed by an ANS package or listed with the Levi default that keeps them
  - DEVICE-CHECKLIST.md: one checkbox per device-only item with exact steps
  - Any new decision appended to android/specs/parity/QUESTIONS.md OPEN
  - JVM test COUNT moved by this package's new tests (not just exit 0); `./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip
  - android/specs/answers/status/<ID>.md set to implemented with a summary; the integrator updates the docs/ARCHITECTURE-ANDROID.md ledger rows named in `ledger_rows` (no PARTIAL left for the answered gap)
- **Unit tests:** Full suite count recorded (no new tests required)
- **Emulator / device verification:**
  - All steps above; shots in pocketdj-answers/_shots/verify/
  - Device-only: The checklist itself.
- **Ledger rows to update:** (all)

## Not scheduled

- **Q25** — Not a package here - feat/am-token-test-flow (see External dependencies).
- **W2, W4, W7** — FR2 pocket colour wheel does not exist on either platform (design only: docs/design/pocket-wheel.md on branch feat/pocket-wheel, iOS first). Fold the answers into that design: W2 count songs PLAYED THROUGH (SkipTracker not-skipped), hard stop at 100, no 'keep going'; W4 motion may upload (listening-pockets payload + App Store 'Fitness' + Play Data safety + ACTIVITY_RECOGNITION); W7 a Mix-cell best match loads Mix Auto-DJ via a MixFacade 'list of songs' source (~150 lines once the wheel exists).
- **Q1** — 'both' (Play internal track + sideload APK) is the release plan's job (docs/plans/android-release.md, branch docs/android-release-plan, phases A1/A3/B/E).
- **Q7, Q14** — Handed to feat/android-ui-polish.
- **Q9, Q13** — Leave as is; decide after real-phone testing (device checklist).
- **Q4, Q8, Q10, Q16, Q19, Q22, Q26-Q28, Q30, Q39 and every 'default' answer** — No code change (Q10 gets a 30-line strip only if C1 deploys sync - inside ANS-SYNC-1).
