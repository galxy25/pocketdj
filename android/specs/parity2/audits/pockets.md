# Parity 2 audit: Pockets (wheel, runs, listening pockets, collections, recs)

Audited 2026-11-23 against `main` @ `4bcd08db` (both trees read; nothing built or run).
iOS root: `apple/PocketDJ/`. Android root: `android/app/src/main/java/com/levi/pocketdj/`.

## TL;DR

* **The Pocket Wheel (FR2) does not exist on Android at all.** iOS shipped it in 1.0.3 to 1.0.6
  (phases 0 to 6, then derived runs, freshness, Clear-this-pocket and the replan artist-spacing
  fix). On Android there is no `data/pockets/wheel/`, no motion source, no `PocketMode`, no run
  store, no `replaceUpcoming`, and no wheel UI. Levi's 2026-11-02 "ship without the wheel for
  now" deferral has ended, so **the wheel is in scope**. It is the bulk of this area: about
  5,500 Kotlin lines plus tests.
* **There is a live interop defect worth landing first, even before any wheel UI.** Android's
  `PlayEvent` (`data/history/PlayHistoryModels.kt`) has no `motion` or `pocketRun` field.
  `PdjJson.lenient` drops them on decode, and Android republishes `play-history` without them.
  iOS's union merge restores them (`PlayHistoryStore.swift` ~L606/L643 treats "mine has
  pocketRun, theirs doesn't" as "doc lacks flags", so it pushes again). The result is a
  strip/restore ping-pong across devices. Any freshly installed iOS device that pulls an
  Android-written doc loses the run tags that `PocketTuning.fold` needs for cross-run learning
  (R8). The fix is about 60 lines.
* The cloud listening-pockets plumbing is mostly at parity: the upload, the collections
  snapshot plus `addEvents`, results, rounds, and the profile-cap 403. It lacks the Phase 6
  **capability gate** (`caps:["wheel"]` echoed by the Lambda, `SyncDoc.serverCaps`) and the
  `mode` and `run` wire fields. The green Lambda already has Phase 6 deployed (2026-10-29).
* In the Pocket, pockets × collections membership, collections dedupe, For You tiles and
  feedback are all **present**. Older partials still open:
  * For You `endPlaybackScope` is never called on Android (Q100 default-deferred).
  * Android Auto has no For You tab (iOS CarPlay F9).
  * Attribution gaps (Phase 0) on Android's play paths.

## Binding decisions that apply (do not relitigate)

* **W1**: History ▸ Pockets with a **Wheel | List** toggle. Wheel is the default. The Pockets
  *collection* tab is untouched.
* **W2**: the 100 counts songs **PLAYED THROUGH** (skips don't count). At 100 the run
  **stops**, with no "keep going". A skip tops the queue up from the bench.
* **W3**: colours are automatic: a stable 12-colour palette, synced, with no picker.
* **W4**: motion **may** leave the device in the pockets upload (sensor modes only).
  * Android consequences: the `ACTIVITY_RECOGNITION` runtime permission, a Play **Data
    safety** update (Health & fitness ▸ Fitness info: collected, linked, app functionality +
    personalization, not shared for ads), and a privacy-policy mention.
  * The iOS label was updated with Fitness (Levi did ASC). Android's Play listing was not.
* **W5**: the artist ban lasts for the run only. It becomes a decaying penalty (30-day
  half-life) in later runs.
* **W6**: cycling folds into Trip. The `collection` mode is labelled **"Home"**.
* **W7**: a Mix-mode best match loads **Mix Auto-DJ** when at least 10 deck-loadable songs
  exist; otherwise it uses the sequencer.
* **Levi 2026-11-10**:
  * **Play on a pocket plays a DERIVED run, never a replay.** This applies to the List
    segment too. "Play the original songs" is a secondary action.
  * **Freshness**: at least 60% of every run prefix must be unplayed in 30 days.
  * Long-press or right-click the centre ▶ for **Clear this pocket**.
* Android standing decisions:
  * The Play build is free, with no paywall.
  * Request every permission needed to be full-featured. The policy-compliant disclosure flow
    applies to ACTIVITY_RECOGNITION too.
  * minSdk 35, so ACTIVITY_RECOGNITION is always a runtime permission.
  * Ship from latest main.

## Design and reference documents

* `docs/design/pocket-wheel.md`: the full design. §7 is the Android mapping table, still
  accurate. §9 records the W1–W7 decisions.
* `docs/design/pocket-wheel-STATUS.md`: build notes, the adversarial-review fixes (these are
  **invariants**, see below), and device-verify items.
* Memory notes:
  * `pocket-runs-derived.md`: derived runs, freshness, Clear, the 11-11 pocket-collapse fix.
  * `queued-after-android-waves.md`: FR2.
  * `listening-pockets-program.md`
  * `pockets-collections.md`: membership is CURRENT and RETROACTIVE.
  * `in-the-pocket-game.md`
  * `collections-dedupe-pass.md`
  * `foryou-10-feature-batch.md`
* Shared fixture `apple/Tests/Fixtures/pocket-wheel-history.json` (57 KB, the 3-week scenario)
  exists and is meant to be read byte-for-byte by Android tests. The golden
  `pocket-wheel-parity.json` named in design §7 has **not been generated yet**.

---

## Inventory

Legend: **state** is the Android state. **feas** is direct, equivalent, platform-impossible
or out-of-scope.

| # | Feature | Android | Feas | Value | ~Lines |
|---|---|---|---|---|---|
| P1 | PlayEvent `motion` + `pocketRun` fields (carry, merge, record, stamp) | missing (fields dropped on decode → sync ping-pong) | direct | high | 120 |
| P2 | Phase 0 play attribution (originId through playSongIds / Auto source playlists, `fav_songs`, Mix per-row crate origin, `pl_`/`pwr_`/`fav_songs` context rules) | partial | direct | high | 180 |
| P3 | Motion: running/walking/automotive/cycling settle onto plays (opt-in), "Notice walking & running" settings | missing | equivalent | high | 550 |
| P4 | Moment engine: `PocketMode` derivation, `PocketMomentKey`/`PocketClock`, decayed + smoothed 168×7 cells, attribution, mega-collection exclusion, run plays ½× | missing | direct | high | 700 |
| P5 | Palette store: 12 OKLCH slots, stable assignment, 30-day free, CloudSync `pocket-palette`, overflow hash | missing | direct | medium | 280 |
| P6 | Moment cache: off-main rebuild on history revision (5 s debounce), disk cache `pocketdj-pocket-wheel-cache.json` | missing | direct | medium | 200 |
| P7 | Best match for centre ▶ (kernels, quality, continuity ± skip-streak negation, cloud ×1.15, cold-start tiers T0–T4, 3 alternatives) + PocketProfile | missing | direct | high | 600 |
| P8 | Wheel UI (Canvas rings×hours×mode slivers, fisheye, needle, scrub, mode chips, legend, moment card, centre ▶ with progress / long-press menu, empty state, a11y) | missing | direct | high | 1300 |
| P9 | History ▸ Pockets Wheel/List segment + relaxed tab gate (history non-empty) + "declined cloud → no List" | missing | direct | high | 90 |
| P10 | Adaptive 100-song pocket run: planner (derived profile, neighbour collections, seed cap, quotas, artist cap/spacing, newcomer floor, freshness, flow), bench | missing | direct | high | 750 |
| P11 | Live learning + re-plan + top-up (PocketTuning fold, bans, slot-wise replacement, W2 invariant, ownership gate) | missing | direct | high | 950 |
| P12 | Sequencer seams: `QueueItem.plan`, `replaceUpcoming` w/ protection, `appendRunRows`, pinned on move/insert, repeat forced off (effective repeat), `pwr_` kept on restore, durable-session plan | missing | direct | high | 280 |
| P13 | List segment Play → derived run; "Play the original songs" | missing (Play = exact replay) | direct | high | 70 |
| P14 | Clear this pocket (centre ▶ long-press / card) + Pocket finished card + past-runs strip | missing | direct | medium | 120 |
| P15 | "Re-tuned ✦" Up Next badge (4 s, only landed rows) | missing | direct | low | 60 |
| P16 | Adapt runs to walking & running mid-run (5b, ≥ 3 min sustained, once per mode) | missing | equivalent | medium | 140 |
| P17 | W7 Mix-cell run through Mix Auto-DJ (≥10 loadable; per-row run tags; mixOwnsRun) | missing | direct | medium | 200 |
| P18 | Listening-pockets upload Phase 6: `caps` gate, `serverCaps`, `mode` (sensor only), `run` wire, fingerprint suffixes | missing | direct | medium | 120 |
| P19 | Android Auto: "▶ Pocket for now" row + "Pockets right now" list | missing | equivalent | high | 170 |
| P20 | Voice: "Play my pocket" (Siri PlayPocketForNowIntent → shortcut + Assistant phrase) | missing | equivalent | medium | 110 |
| P21 | Account deletion / Delete history wipes wheel local state + `pocket-palette` key | missing | direct | medium | 40 |
| P22 | Cross-platform golden tests on the shared fixture | missing | direct | high | 600 (tests) |
| P23 | Android Auto For You tab (CarPlay F9) | missing | equivalent | medium | 260 |
| P24 | For You playback-scope retire (`endPlaybackScope` on playNow replace; Q100) | partial | direct | low | 40 |
| P25 | DJ Mode must keep artist spacing on pocket runs (cross-area dependency) | n/a until DJ Mode lands | direct | medium | 40 |
| P26 | Profile-cap 403 (`profile-cap-reached`) in pockets + rec-engine clients | present | — | — | 0 |
| P27 | Pockets × collections upload (`collections` ids-only snapshot, `addEvents`), membership-aware In the Pocket | present | — | — | 0 |
| P28 | Collections dedupe (same-release tier, Remove duplicates per collection / all) | present | — | — | 0 |
| P29 | In the Pocket game (rounds, feedback dictation, golden scorer) | present | — | — | 0 |

---

## Detail per gap

### P1: `PlayEvent.motion` and `pocketRun` (land first)

**iOS.** `State/PlayHistoryStore.swift`:
* Fields at L114–124. The CodingKeys include `motion` and `pocketRun`.
* Lenient decode at L672.
* `stampPocketRun` at L372.
* Merge at L606: first-writer-wins per field. L643 reports that the doc lacks flags, which
  triggers a re-push.
* `PlayContext.pocketRun` at L259/L296. `record()` copies it.

**`PocketRunTag`** is defined in `Services/PocketWheel/PocketWheelModels.swift` L168:
* `runId`: a UUID string.
* `momentKey`: `"h08|d2|carPlay"`.
* `rowCollectionId?`
* `slot`: 1-based.

The decoder is lenient: `momentKey` defaults to `""` and `slot` to `0`.

**Android.** `data/history/PlayHistoryModels.kt` `PlayEvent` (L81–104) stops at `carPlay`.
`PlayHistoryStore.kt` merge is at L305–333.

**Approach.**
* Add `val motion: String? = null` and `val pocketRun: PocketRunTag? = null`. `@Serializable`
  `PocketRunTag(runId: String, momentKey: String = "", rowCollectionId: String? = null,
  slot: Int = 0)`.
* Put `PocketRunTag` in `data/pockets/wheel/PocketWheelModels.kt`, or in history to avoid a
  dependency cycle.
* Merge: `if (mine.motion == null && theirs.motion != null)`, and the same for `pocketRun`.
  Also extend the "we hold flags the doc lacks" check so Android re-pushes them like iOS does.
* Add `PlayHistoryStore.stampMotion(ids → token)`. It is write-once and touches only this
  install's events (`originInstallId == null || == installId`), mirroring the listeningContext
  stamp.
* `record(...)` accepts the `pocketRun` from the play context.

**Invariants.**
* Never add a `PlaySource` case for runs. Run plays stay `source = pocket`, because older
  builds drop unknown sources (LenientEvent).
* The fields are additive-optional and need no schema bump.
* JSON keys must be exactly `motion` and `pocketRun{runId,momentKey,rowCollectionId,slot}`.
  The `runId` string is uppercase UUID as iOS `UUID` encodes it. Preserve it verbatim and never
  re-case it.

**Tests.** Decode an iOS doc carrying both fields, then round-trip it byte-stable for those
keys. Cover the merge rules and stamp write-once on a peer event.

### P2: Attribution fixes (Phase 0)

**iOS** (commit `7df7017f`):
* `IntentServices.playSongIds(..., originId:)` forwards the origin.
* `CarPlayModel.playPlaylist` and `CollectionPlayMenu` stamp the source-playlist id.
* `PocketWheelIds.favorites = "fav_songs"` (name "Favorite songs").
  `CollectionsStore.historyContext`/`originCollection` resolve `fav_songs` (L2595/L2615) and
  `pl_…`.
* Mix Auto-DJ rows carry `AutoMixItem.originCollectionId`, which is persisted in `AutoRow`. The
  Mix history hook stamps it as `originCollectionId`.
* `ListeningPocketsCollections.context` (`Services/ListeningPockets/ListeningPocketsCollections.swift`
  L116) does three things:
  * It returns nil for `pwr_` and `fav_songs`.
  * It maps `pl_` to `source` whatever the surface.
  * `wireEvent` picks the first of `[pocketRun.rowCollectionId, originCollectionId, contextId]`
    that isn't `pwr_`.

**Android gaps.**
* `shell/ShellActions.kt` L197 `playSongIds` has no `originId`.
* `auto/AppAutoServices.kt` L180–189: the SOURCE playlist path calls `collections.playNow`
  without `originId`.
* `mix/model/MixModels.kt` `AutoMixItem` has no `originCollectionId`.
  `mix/engine/MixPlayOutcomeBridge.kt` L68 records the Mix context without an origin.
* `data/pockets/ListeningPocketsCollections.kt` L139 lacks the `pwr_`, `fav_songs` and `pl_`
  rules. `ListeningPocketsService.kt` L380 uses `originCollectionId ?: contextId` with no
  `pocketRun` and no `pwr_` filter.
* No `fav_songs` anywhere.

**Approach.**
* Add an `originId` parameter to `ShellActions.playSongIds` → `collections.playNow(originId=)`.
* Pass `ref.id` for AutoCollectionKind.SOURCE.
* Add `originCollectionId` to `AutoMixItem`. Set it from the `MixSource` id in `MixGraph` /
  `CollectionMixDownloader` and in two-crate interleave, per row. The bridge passes it to the
  history record.
* `CollectionsStore.historyContext`/`originCollection`: resolve `fav_songs` and `pl_`.
* Port the context() rules exactly.

**Invariant.** Origin attribution is per ROW for Mix, because two crates interleave.

### P3: Motion (running, walking) on Android

**iOS.**
* `Location/MotionActivityProviding.swift`:
  * Protocol `MotionActivityProviding`, `MotionSegment {start,end,activity,confidence}`.
  * Pure `MotionSettle`: `minAgeMs` 2 min, `horizonMs` 6.5 d, `fallbackDurationMs` 180 s,
    `minConfidence` medium. The window is length × fraction, floored at 30 s.
  * The overlap-seconds winner. Ties go to the more active state, in the order running >
    walking > cycling > automotive > stationary.
  * `ListeningMotionStore`: a device-local doc `pocketdj-listening-motion.json {isEnabled}`,
    never synced. It has `adaptToActivityKey = "pdj.wheel.adaptToActivity"`.
* `Location/CoreMotionActivitySource.swift`: the retroactive 7-day query.
* `Location/ListeningMotionSettingsSection.swift`: toggles "Notice walking & running" and
  "Adapt pocket runs to walking & running".
* The settle runs on foreground (`PocketDJApp.settleMotionSoon`).

**Android equivalent.** Android has no retroactive history query, so transitions must be
recorded continuously while opted in.
* **New `data/motion/ActivityTransitionSource.kt`:**
  * `ActivityRecognition.getClient(ctx).requestActivityTransitionUpdates(...)` for
    ENTER/EXIT of RUNNING, WALKING, ON_BICYCLE, IN_VEHICLE and STILL.
  * It delivers to a manifest-registered `MotionTransitionReceiver` (a mutable `PendingIntent`
    broadcast, which is required for the extras).
  * Re-register on app start, on `BOOT_COMPLETED` and on `MY_PACKAGE_REPLACED`, because
    registrations do not survive a reboot or an update. That adds `RECEIVE_BOOT_COMPLETED` if
    it is not already present.
  * The dependency `play-services-location` 21.3.0 is already in `app/build.gradle.kts`.
* **New `MotionTimelineStore.kt`:** a 7-day ring of `MotionSegment` built from ENTER/EXIT
  pairs. It maps `IN_VEHICLE`→automotive, `ON_BICYCLE`→cycling and `STILL`→stationary. ON_FOOT
  is not requested.
  * Transition events carry no confidence, so treat them as medium.
  * The device-local file is `pocketdj-motion-timeline.json` and is never synced.
* **Port `MotionSettle` verbatim** (pure): `data/motion/MotionSettle.kt`.
* **`ListeningMotionStore.kt`** holds the opt-in doc (same file name as iOS, device-local) and
  runs settle on foreground through the `AppLifecycleObserver` funnel. It is gated on
  permission.
* **Manifest:** `<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>`.
* **Permission UI:** a Settings section beside the ANS-LOC-1 places & trips section
  (`screens/settings/...`). Add a prominent-disclosure dialog before the runtime request, in
  the bg-location pattern. Denied means the feature is inert and the toggle explains why.
* **The "now" read** for best match is the latest segment in the last 5 minutes from the
  timeline.

**Invariants.**
* Opt-in, default OFF, per device.
* Stamp only own-install plays, write-once.
* Raw motion never leaves the device. Only the derived *mode* rides the upload (P18), and only
  while the toggle is on.
* No GPS involved.

**Play policy.** Data safety: Fitness info. Note: transitions recorded while the app is not
running need no foreground service, so no new FGS type is needed.

### P4: Moment engine (pure)

**iOS.**
* `Services/PocketWheel/PocketWheelModels.swift`: `PocketMode`.
  * Tokens `carPlay, running, walking, trip, mix, browse, collection`. **Never rename**: they
    are persisted.
  * Precedence order, labels, related pairs and `derive`.
  * `MotionToken`.
  * `PocketMomentKey`: token `h%02d|d%d|mode`, ISO weekday 1=Mon.
  * `PocketClock.local`: pure; 1970-01-01 is ISO 4.
  * `PocketWheelIds`: `runTagPrefix = "pwr_"`, `favorites`.
* `PocketMomentEngine.swift` (421 lines):
  * `halfLifeDays` 45, `runPlayFactor` 0.5.
  * Kernels: ±1 h 0.5, ±2 h 0.15, same day type 0.25, related mode 0.3.
  * `dominantMinShare` 0.25, `topCollections` 8, `topFeatures` 8, `topSeeds` 40.
  * `fallbackWeight` 0.5, mega-collection = more than 3,000 songs or more than 25% of the
    library.
  * Add-time `membershipScale` (45 d half-life, `unknownAddScale` 0.75).
  * `round6` rounding for deterministic goldens.
  * `PocketWheelSnapshot` is the cached output.

**Android.** None. Building blocks exist:
* `data/collections/CollectionFlattener.kt` (`flatten`, `addTimes` L124).
* `data/recs/SimilarityFamilies.kt` (eraWindow/eraFit, timbreProfile/timbreDistance, musical
  profile).
* `data/recs/RecIdentity.kt` `creditArtistKeys` L68.
* `data/games/inthepocket/InThePocketMembership.kt`.
* `data/location` ListeningContextTag.

**Approach.** Create a new package `data/pockets/wheel/` with `PocketWheelModels.kt`,
`PocketMomentEngine.kt` and `PocketMomentSnapshot.kt`. Port line for line with the same
constants and the same rounding.

**Invariants.**
* Run plays count 0.5× in plays and collections, but 1× in skips (feedback-loop guard).
* `distinctDays` counts direct credit only.
* Games are excluded.
* Soft membership never colours a cell.
* Membership is current and retroactive. Add-time recency is measured from now, not from the
  play.

### P5: Palette store

**iOS.** `Services/PocketWheel/PocketPaletteStore.swift`:
* Doc `pocketdj-pocket-palette.json`: `{schemaVersion:1, entries:{collectionId:{slot,
  assignedAtMs, lastSeenMs}}}`, with per-entry lenient decode.
* `merge`: earliest `(assignedAtMs, slot)` wins the slot; `lastSeenMs` is the max.
* `normalized` resolves slot collisions to the lowest free slot.
* A slot is freed 30 days after `lastSeenMs`, or when its collection is deleted. `fav_songs` is
  never freed.
* The `darkRGB`/`lightRGB` tables are 12 precomputed sRGB triples. **Copy the numbers
  exactly.**
* Overflow is an sha256(id) hue at C 0.08, drawn hatched.
* CloudSync key **`pocket-palette`**, registered in `PocketDJApp` L1957. It is in the
  `AccountDeletionService` key list (L54).

**Android approach.**
* `data/pockets/wheel/PocketPaletteStore.kt`, with the same file name and JSON.
* Register a `SyncEntry("pocket-palette", "pocketdj-pocket-palette.json", onPulled=reload)`
  through the FeatureModule `syncEntries` (see `data/sync/SyncRegistry.kt`). Add the key to
  the account-deletion sweep (`di/ServicesGraph.kt` ~L617 list).
* Colours become Compose `Color` from the same tables. Add theme tokens. Do not recompute
  OKLCH at runtime unless for overflow; port `oklchToSRGB` for that case.

**Invariant.** Slots never move after assignment. Cross-device sharing means iOS and Android
must paint the same colours, so it must be byte-compatible with iOS.

### P6: Moment cache

**iOS.** `PocketMomentCache.swift`:
* `historyDidChange` is debounced 5 s and rebuilds off-main.
* `pocketdj-pocket-wheel-cache.json` is device-local, so the wheel paints instantly at launch.
* `makeInput` joins history, the catalog, collections (`fav_songs` is added as a pseudo
  collection, L154) and cloud pattern refs.
* It frees palette slots of deleted collections (L112).

**Android.** Add `PocketMomentCache.kt` driven by the `PlayHistoryStore` revision flow on
`Dispatchers.Default`. It exposes a `StateFlow<PocketWheelSnapshot>`.

**Invariant.** No derivation in composables. The wheel draws only from a precomputed layout.

### P7: Best match and profile

**iOS.** `PocketBestMatch.swift` (353 lines):
* `PocketProfile` (Codable). It is persisted in the run file, so its shape matters.
* `from(moment:)`.
* `from(listening:features:numeric:membership:candidates:songIds:)`, used for the List Play.
* `Now`.
* Constants: `richMinMatch` 0.35, `richMinPlays` 3, `neighbourhoodHours` 3,
  `neighbourhoodMinPlays` 5, `coldMinPlays` 20, `continuityWeight` 0.35, `cloudBoost` 1.15,
  `skipStreakRate` 0.5.
* Kernels kt, kd, km and kl (design §3.2).
* `best()` gives the winner plus 3 alternatives with distinct dominant collections.
* Tiers rich, neighbourhood, cloud, cold and empty, using `InThePocketScorer.cloudProfile`.
* `modeNow` and `recentActivity` (a 45-minute window).

`PocketWheelController.swift` provides refresh, `profile(forMode:)`, `playBest`,
`playMoment`, `play(alternative:)`, `momentsNow(count:)` (±1 h), and summaries.

The T4 empty fallback is in `PocketDJApp` L1838: Favorites `fav_songs`, then the most recent
collection.

**Android approach.**
* `PocketBestMatch.kt` and `PocketProfile.kt` (`@Serializable`).
* `PocketWheelController.kt`, app-scoped in a new `di/PocketsGraph.kt`.
* Reuse `data/games/inthepocket/InThePocketScorer.kt` profile builders. Refactor them to
  internal helpers; do not copy.
* `modeNow`: Android Auto connected (`PocketsPlayListener` / the `carPlayProbe` source, i.e.
  UiModeManager car mode) → carPlay. Otherwise the motion timeline's last 5 minutes. Otherwise
  the ListeningPlaceEngine trip guess.

### P8: Wheel UI

**iOS.**
* `Views/PocketWheel/WheelLayout.swift` (pure geometry):
  * `holeFraction` 0.30, `focusScale` 1.8, `weekendGapFraction` 0.025, `ringGapFraction` 0.006.
  * `maxSlivers` 3, `minSliverShare` 0.2.
  * Polar hit-test. Midnight is at 12 o'clock, clockwise. Monday is the innermost ring.
* `PocketWheelView.swift` (465 lines):
  * A Canvas draws from the layout.
  * Mode chips All, CarPlay, Trip, Run, Walk, Mix, Browse and Home.
  * A Mon…Sun row picks the fisheye.
  * The "now" needle.
  * Scrub with a callout.
  * The centre ▶: best-match colour ring, `done/total` progress, ⏸ while running.
  * Context menu: Clear this pocket, Start a new pocket for now, Not this? alternatives.
  * Empty state: "Play for a week to paint your wheel."
  * A11y: 7 adjustable ring elements.
* `PocketMomentCard.swift`:
  * Title, collection bars with %, top artists and genres, BPM, place chips, plays and skip
    rate.
  * ▶ Play this pocket, with Clear in its menu.
  * "Why this colour", the Past runs strip, and the legend with week share. Tapping the legend
    highlights.
* `PocketWheelActions.swift`: the action bundle.
* `PocketsTabView.swift`: the segment.
* Test ids `pocket-wheel-*`, `pocket-card-*`, `pocket-legend-*`. Keep the same testTags on
  Android.

**Android approach.**
* `screens/history/wheel/PocketWheelScreen.kt` uses Compose `Canvas` with
  `drawArc`/`Path` annular sectors from a remembered `WheelLayout`, and
  `pointerInput{detectTapGestures + detectDragGestures}` for polar hit and scrub (with a Popup
  callout).
* `PocketMomentCard.kt` is a `ModalBottomSheet` on phone and a side pane at ≥600 dp.
* TalkBack: `semantics { }` per ring with `progressBarRangeInfo`/`stateDescription` and
  `customActions` for ±hour, or a 7-node `Column` overlay with `setProgress`. The design names
  `CustomAccessibilityAction`.
* The centre ▶ uses `combinedClickable(onLongClick)` → DropdownMenu.
* Reduce Motion is `Settings.Global.ANIMATOR_DURATION_SCALE == 0`.
* Mode glyphs map to Material icons: DirectionsCar, DirectionsRun, DirectionsWalk, Route,
  Tune, List, Home.
* Phone width is 16 dp gutters. Wheel radius ≈ (width − 32)/2.

### P9: History ▸ Pockets segment and gate

**iOS.** `HistoryView.swift` L285 `pocketsTabOn`: the tab shows if history is non-empty or the
wheel snapshot is non-empty. Otherwise the old cloud gate applies. `PocketsTabView` hides the
List segment when `listeningPocketsChoice == false`. The segment is remembered per viewer in
`pdj.history.pockets.segment`.

**Android.**
* `screens/history/HistoryScreen.kt` L152–159: `PocketsTabGate.tabVisible(rec, on,
  answered)` is the cloud-only gate.
* L299: POCKETS → `ListeningPocketsScreen` directly.

**Approach.** Extend `PocketsTabGate.tabVisible` with `historyNonEmpty`. Add
`PocketsTabScreen.kt` with a `SegmentedButton` Wheel | List, rememberSaveable plus DataStore
for the segment. Hide List when the user declined (`LISTENING_POCKETS_ANSWERED && !ENABLED`).

### P10: Run planner

**iOS.** `PocketRunPlanner.swift` (555 lines):
* Constants:
  * `slots` 100, `artistCap` 6, `artistSpacing` 4, `newcomerFloor` 0.2.
  * `dominantMinSlotShare` 0.4, `softCap` 0.25, `softMinFit` 0.6.
  * `benchCap` 400, `poolCap` 600, `firstDrawFrom` 8, `nextDrawFrom` 6.
  * `instantLeadSlots` 3, `replanFloorShareOfMedian` 0.6, `minPocketFit` 0.3.
  * **`seedWeight` 0.3, `seedSlotShare` 0.25.**
  * **`neighbourMaxCount` 3, `neighbourShare` 0.3, `neighbourMinSim` 0.55,
    `neighbourMinMembers` 5, `neighbourMaxMembers` 1500** (the genre cosine gate is 0.5 in
    `collectionSim`).
  * **`freshDays` 30, `freshFloor` 0.6, `freshWeight` 0.6.**
* `derived()` = `fillingGapsFromSeeds` + `withNeighbourCollections`.
* `plan()`: the fresh floor is **paced over every prefix**, not back-loaded. It relaxes only
  when no fresh song is left.
* Familiarity counts only when negative. The score adds `0.6·(1−recency)`.
* `flow` uses BPM and Camelot. `quotas` are per collection.
* `replan`, `topUp` and `musicalSim` (no artist family).
* `PocketRunCandidates.swift` builds candidates from the playable universe (rip manifest ∪
  burned ∪ AM with an `appleMusicId` when AM can stream). Each candidate carries memberships
  with add-time scale, `fav_songs` at 0.75, the genre category from the album (`other`→nil)
  and `creditArtistKeys`. `startsInstantly` is set for burned songs.
* Exclusions: played in the last 12 h, or a lifetime 👎 (`RecFeedbackStore` rejected).

**Android approach.**
* `PocketRunPlanner.kt` and `PocketRunCandidates.kt`.
* Playability comes from `data/games/inthepocket/InThePocketInputs.kt` (`AudioAvailability`
  analogue: ripIds, burnedIds, AM).
* Timbre comes from `data/recs/TimbreCatalog.kt`.
* Seeded RNG: use the existing `data/games/inthepocket/SplitMix64.kt` so draws match iOS for
  goldens. Check that iOS uses the same generator (InThePocketScorer does).

**Invariants.**
* Play is derived, never a replay.
* No artist twice within 4 slots, at most 6 per 100.
* At least 20% newcomers.
* The first 3 rows are biased toward instant starts.
* Pinned and manual rows are never replaced.
* The "Apple Music rows have no BPM/key" neutrality is data, not code.

### P11: Run store, live learning and re-plan

**iOS.** `State/PocketRunStore.swift` (659 lines):
* `target` 100, `replanDebounce` 1.5 s, `rescoreEvery` 5, `ownershipGraceMs` 10 s,
  `topUpBackoffMs` 30 s.
* The run file `pocketdj-pocket-run.json` holds the RunState: runId, momentKey, label, seed,
  profile, bench, banned, processed ids, the playedThrough/skips counters, `mixSlots`,
  `mixCollections`, `retargetedMode` and `past[]`.
* `start(profile:)`:
  * The plan is built off-main.
  * The tuning prior comes from `PocketTuning.fold(..., allowBans:false)`.
  * Rows are tagged with a `PlanTag`. Play goes through `sourceSetlistId = "pwr_<uuid>"`.
  * Log line: `[pocketrun] start run=… moment=… rows= fresh= bench= mix=`.
* `evaluate()` is a 1 Hz ticker:
  * **One bounded tail walk** back to the run start, never a full scan.
  * Verdicts come only from the SkipTracker → history pipeline. **There is never a second skip
    pipeline.**
  * Bans come from THIS run's evidence only (W5).
  * Ownership-loss grace is 10 s. While a run doesn't own the sequencer it learns only.
* `trimToInvariant` and `rowsNeeded`:
  * The W2 formula with a spare row.
  * The sounding row counts as done once it is at least 90% played, so no 101st song starts.
  * Pinned run rows count toward the total, but only unpinned rows are trimmed.
* `topUp`: scores off-main, appends on main only if the run still owns the sequencer, and
  backs off 30 s on empty.
* `replanNow`: computed off-main, applied on main through `replaceUpcoming`.
* `PocketTuning.swift`:
  * Signal strengths: fast skip below 0.15 = −1.0, skip = −0.6, complete = +0.5,
    partial = +0.2.
  * Multiplier formulas per feature family. Ban at 0.35 or below.
  * Fold with a 30-day half-life. Related moments ×0.5, global ×0.15.
* **cdbf9e87 fix:** a replan replacement must also clear the artist-spacing window around its
  slot, covering live rows and the prev/next neighbours.

**Android approach.**
* `data/pockets/wheel/PocketRunStore.kt` and `PocketTuning.kt`.
* A coroutine ticker on `Dispatchers.Main.immediate` with heavy work on `Default`.
* Hooks:
  * `SkipTracker.currentEventId` (`playback/outcome/SkipTracker.kt` L72).
  * `PlayHistoryStore` events.
  * `RecFeedbackStore` rejected ids.
* Wire it in `di/PocketsGraph.kt`.

**Invariants** (the review-fix list from STATUS.md):
1. Edits happen only while the run owns the sequencer, meaning `isRunning &&
   sourceSetlistId == pwr_<id>`.
2. A `pwr_` id is never a context id.
3. Repeat is effective-off during a run, and the sticky mode is never written.
4. The top-up runs off-main.
5. Failures surface: start returns false, and voice/Auto get "Not enough playable songs fit
   your pocket right now…".
6. A held (restored, not playing) run does no per-tick work.
7. Top-up and replacement rows are edition-stamped like `play()` rows.

### P12: Sequencer seams

**iOS.** `Playback/SetlistPlayer.swift`:
* `PlanTag` (L100) is excluded from Item equality.
* `effectiveRepeatMode`/`isRepeatForcedOff` (L309–316). Repeat taps are inert while forced
  off (L1138).
* `replaceUpcoming(_:removing:)` (L1322), with `isReplaceablePosition`:
  * never `≤ index`;
  * never `plan == nil` or pinned;
  * `index+1` only with at least `replaceNextMinRunwaySeconds` = 30 s left;
  * a rip in flight only for an instant or on-device replacement.
* Replacements take the uid's slot in `canonicalOrder`. Touching the prefetch window re-runs
  the prefetch. The session is persisted.
* `appendRunRows` (edition-stamped).
* `pinned = true` in `moveUpcoming`, `moveUpcomingNext` and inserts (L1245/1426/1437).
* Restore keeps `pwr_` (only `puzzle_` is nil'd).
* The durable session Row gets an optional `plan`.

**Android.**
* `playback/sequencer/SetlistSequencer.kt` has a private `replaceTail` (L986),
  `removeUpcoming` (L1018), `appendRows(items, runTag)` (L1037), `canonicalOrder` (L151),
  `rowOnDevice` (L105), and the `GHOST_RUN_PREFIX = "puzzle_"` restore rule (L1641).
* `QueueItem.kt` has `runTag`, with no plan.
* `NextRowPreloader` holds the prefetch window.
* `playback/durable/PlaybackSessionStore.kt` holds rows.

**Approach.**
* Add `QueueItem.plan: PlanTag?` and exclude it from equality checks where iOS does.
* Add public `replaceUpcoming(replacements: Map<String, QueueItem>, removing: Set<String>):
  Int` over `replaceTail`. It re-checks protection at apply time and re-arms `NextRowPreloader`
  when it touches `index+1`.
* `effectiveRepeatMode` feeds the MediaSession repeat (the lock screen, Auto and the widget
  show off), and `setRepeatMode` is a no-op while `pwr_` owns the sequencer.
* Mark rows pinned in `moveUpcoming`, `moveUpcomingNext` and `moveUpcomingToEnd`.
* Add optional `plan` to the durable row JSON.
* Android has no Mac capture rip, but the rip-request window still applies (Rip server rows).
  Use the existing resolver's "requested" set if present, else treat rows with a pending rip
  request as `requiresInstant`.

### P13: List segment Play → derived run

**iOS.** `Views/ListeningPocketsView.swift` ~L512:
* `play()` → `runs.start(profile: .from(listening:…))`.
* Notes: "Building a mix from this pocket…" and "Playing a fresh mix from this pocket."
* A failure shows `buildState.failed` text.
* A secondary "Play the original songs" button (`pocket-replay`) does the exact replay.

**Android.** `screens/history/ListeningPocketDetailScreen.kt` L147–156: Play calls
`shellActions.playSongIds(songIds, title, SOURCE_SETLIST)`, an exact replay.

**Approach.** Switch Play to `PocketRunStore.start(PocketProfile.fromListening(...))`. Keep
the old call as a TextButton with testTag `pocket-replay`.

### P14: Clear this pocket, finished card, past runs

**iOS.**
* c7a8d3a7: the centre ▶ context menu while a run plays has "Clear this pocket"
  (`PocketRunStore.stop`, which ends into past runs and stops the queue) plus "Start a new
  pocket for now". The card has a Clear button and a long-press on ▶ Play this pocket.
* The finished card offers "▶ another pocket" (`dismissFinished`).
* `runHistory(for:)` returns `{playedThrough, skipRate}` rows.

**Android.** Port these with `combinedClickable` long-press, and a right-click via
`pointerInput` for mouse/ChromeOS (`PointerButton.Secondary`).

### P15: Re-tuned badge

**iOS** (`7fa721f4`): `PocketRunStore.retunedUids` lights only rows that landed, and clears
`retunedBadgeSeconds` (4 s) after the latest swap. `RetunedBadge` appears in
`NowPlayingPanel` Up Next (L1282).

**Android.** Add the badge to the Up Next row composable (PB-7 Up Next).

### P16: Adapt to activity (5b)

**iOS.** `PocketRunStore.noteActivity`. `ActivityTracker.sustainSeconds` is 180. The re-target
happens once per mode per run, through the same protected replace path. It runs only on the
sequencer path, and only while "Adapt pocket runs to walking & running" is on. Live updates
start and stop with the run.

**Android.** Feed the transition receiver into a `SharedFlow` that the run store collects
while a run plays. Transitions are already push-based, so no extra sampling is needed.

### P17: W7 Mix path

**iOS.** `PocketRunStore.playThroughMix`, `mixOwnsRun` and `mixTag(forSongId:label:)`, wired
in `PocketDJApp` L1867–1887. A run needs at least 10 loadable rows; otherwise it falls back to
the sequencer. The Mix path does no live replan (an accepted iOS follow-up).

**Android.** `shell/MixFacade.kt` only starts a `MixSource` (pocket, playlist or setlist).
`mix/engine/AutoDj.kt` L155 has `startAutoMix(items: List<AutoMixItem>, …, label)`.
* Add `MixFacade.startAutoMixSongs(songIds, label): Int` (the answers roadmap estimated about
  150 lines).
* `MixPlayOutcomeBridge` stamps `pocketRun` via `runStore.mixTag(songId, label)`.

### P18: Upload Phase 6

**iOS.**
* `ListeningPocketsModels.swift`: `ListeningPocketsUploadEvent.mode` and `run{id, moment,
  slot, collectionId}` are encoded **only when present** (absent, not null).
* `ListeningPocketsUploadResponse.caps`.
* `ListeningPocketsService.swift` L128–144 `SyncDoc.serverCaps`, L502 `noteServerCaps`, L509
  `serverSupportsWheel`.
* `wireEvent`: `mode` is set only if `serverSupportsWheel && motionOptedIn`, via `sensorMode`.
  That covers running, walking, and trip only when motion is automotive or cycling.
* `run` is sent only if `serverSupportsWheel`.
* Fingerprint suffixes `|m:<mode>` and `|r:<id>/<slot>` are appended only when present.

**Android.**
* `data/pockets/ListeningPocketsModels.kt` L82–155 has no mode or run. The response has no
  caps (L158).
* `ListeningPocketsService.kt` `SyncDoc` L124 has no `serverCaps`.

**Invariant (data-loss guard).** **Never put `mode` or `run` on the wire before the server
has echoed `caps:["wheel"]`.** An old Lambda 2xx's while dropping them, and the fingerprint
would then never re-send. Keep pre-existing fingerprints byte-identical, so there is no mass
re-send.

### P19: Android Auto "Pocket for now"

**iOS.**
* `CarPlay/CarPlayPocketWheel.swift`:
  * Row id `pocketwheel:now`, titled "▶ Pocket for now", with subtitle "Potential · Tue 8 AM".
  * `pocketwheel:m:<token>` rows for the top 5 moments within ±1 h.
* `CarPlayScene` L757/783 refreshes on connect.
* Play goes through `IntentServices.playPocketForNow`/`playPocketMoment`, which honour the
  onboarding veto and readiness. On failure it toasts instead of opening an empty Now Playing.

**Android.** `auto/AutoBrowseTree.kt` root is Playlists and Pockets tabs (L157–220).
* Add a playable root item `pocketwheel:now` (flagged `FLAG_PLAYABLE`) and a browsable
  "Pockets right now" node.
* `AutoLibraryCallback` handles the play. `AppAutoServices` calls the controller.
* Failure throws `AutoPlayException("Not enough playable songs fit your pocket right now…")`.
* Refresh happens in `onGetLibraryRoot`.

### P20: Voice "Play my pocket"

**iOS.** `Intents/PocketWheelIntents.swift` `PlayPocketForNowIntent` returns the dialog
"Playing your pocket: <caption>.". The App Shortcut is in `PocketDJShortcuts.swift`.

**Android equivalent.**
* A static shortcut in `res/xml/shortcuts.xml` ("Play my pocket") that deep-links
  `pocketdj://pocket/now`.
* A `DeepLinkParser` route → `ShellActions.playPocketForNow()`.
* `assistant/MediaSearchHandler.kt`: treat the queries "my pocket", "pocket for now" and
  "play my pocket" as the best-match run (Assistant media voice search: "play my pocket on
  PocketDJ").
* Optionally an App Actions `actions.intent.PLAY_...` capability. Siri dialog text maps to a
  Toast or Snackbar.
* Coordinate with the voice auditor.

### P21: Deletion

**iOS.** `accountDeletion.wheelClearLocal` (`PocketDJApp` L2084) clears the run store, the
moment cache, the palette and motion. The `pocket-palette` key is in the deletion sweep.

**Android.** Add `pocket-palette` to the sweep in `di/ServicesGraph.kt`. Clear the wheel
cache, the run file, the motion timeline and the motion opt-in on Delete history and on
account deletion.

### P22: Golden parity tests

* Read `apple/Tests/Fixtures/pocket-wheel-history.json` from the Android unit tests (the
  `timbre-parity.json` / `inthepocket-golden-input.json` precedent).
* `pocket-wheel-parity.json` does not exist. Generating it requires a Swift test that dumps:
  moments for the fixture, best match at a fixed `Now`, the first 100 rows for a fixed seed,
  and the post-Drake replan. Running it needs xcodebuild on the iMac (the ANS-GM-1 "captured on
  this iMac" pattern).
* Until it exists, port the iOS test cases one to one:
  * `PocketMomentEngineTests`, `PocketPaletteStoreTests`, `WheelLayoutTests`.
  * `PocketBestMatchTests`, `PocketRunPlannerTests`, `PocketDerivedRunTests`.
  * `PocketRunStoreTests`, `PocketWheelCloudTests`, `MotionSettleTests`,
    `PlayAttributionTests`.
  * `SetlistPlayerReplaceUpcomingTests`, as a property test of the protection invariants.

### P23: Android Auto For You

**iOS.** The CarPlay tab bar is Playlists, Pockets and For You (`CarPlay/CarPlayModel.swift`
L103; `CarPlayForYou.swift`).
* Order is load-bearing: `playSongIds` → `playNow` → `onPlaybackReplaced` →
  `endPlaybackScope`, **then** `beginPlayback(scope)`.
* Tile counts are built on connect.

**Android.** The `AutoBrowseTree` doc comment says "minus For You". Add a For You tab driven by
`ForYouFeed` tiles; release rows are not playable there.

### P24: For You scope retire (Q100)

**iOS.** `CollectionsStore.onPlaybackReplaced` fires at every `playNow` (L2261/2281/2314) →
`RecFeedbackStore.endPlaybackScope`.

**Android.** `RecFeedbackStore.endPlaybackScope()` (L337) is never called. Add an
`onPlaybackReplaced` seam in `CollectionsStore.publishNowPlaying` (L1897), wired in
`di/CollectionsGraph.kt`. For You's tile ▶ must call `beginPlayback` **after** `playNow`
returns, to keep the iOS ordering. This stops a stale "playing scope" from absorbing a sync
accept/reject meant for a later queue. Note that the Q100 default was "defer"; Levi's
"parity as the platform allows" ask now covers it.

### P25: DJ Mode × pocket runs (dependency)

iOS `Playback/DJSetPlanner.swift` (cdbf9e87):
* Candidates carry artist keys.
* No artist may repeat within `artistSpacing` = 4 while another free row can take the slot.
* A scarcity rule applies.
* `appendRunRows` rows are "planner material" that DJ Mode may re-order.

Android has no DJ Mode yet. Whoever ports it must include this, or pocket runs collapse
(GoldLink/Cousin Stizz alternation, drive 2026-11-10). This is listed here so the dependency
is not lost.

---

## Suggested package order

1. **P1 + P2 + P18 + P21**: data plumbing, about 460 lines. Land these first and ship them
   alone. They fix the sync ping-pong and make Android-recorded plays attribute correctly for
   iOS wheels, even before the Android wheel exists.
2. **P4–P7 + P22 (engine part)**: pure engine and goldens.
3. **P12**: sequencer seams, with property tests.
4. **P10 + P11 + P13 + P14 + P15**: runs.
5. **P8 + P9**: UI.
6. **P3 + P16**: motion. It depends on the permission and disclosure flow, plus the Play Data
   safety change.
7. **P17, P19, P20**: surfaces.
8. **P23, P24**: For You leftovers.

## Device-only checks (add to DEVICE-CHECKLIST)

* ACTIVITY_RECOGNITION prompt and disclosure. Transitions arrive after a real walk or run.
  Re-registration after a reboot.
* A real 100-song run: it stops at the 100th play-through, skips top up the queue, and Drake
  bans show in logs as `[pocketrun] replan … banned=[…]`.
* Android Auto: the "Pocket for now" row on DHU or a head unit.
* Dead air at run transitions. Replacing the next row needs at least 30 s of runway.
