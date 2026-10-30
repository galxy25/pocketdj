# Pocket Wheel — build status

Design: `docs/design/pocket-wheel.md` (decisions W1–W7 in §9, 2026-10-29).
Branch: `feat/pocket-wheel` (worktree `pocketdj-wheel`). NOT merged to main, NOT shipped to TestFlight.

Gates per phase: iOS unit suite on sim `3FE7AC66…` with the executed count moving up from the 3608 baseline; macOS + tvOS-sim + visionOS-sim builds green.

## Phases

| Phase | State | Commit | Unit tests (executed) | Platforms |
|---|---|---|---|---|
| 0 — attribution fixes + event fields | DONE | phase-0 commit | 3622 (+14) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 1 — motion (CoreMotion settle, opt-in) | DONE | phase-1 commit | 3632 (+10) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 2 — moment engine + palette | DONE | phase-2 commit | 3658 (+26) — verified in the Phase 3 tip run | mac ✓ tv-sim ✓ vision-sim ✓ |
| 3 — wheel UI | DONE | phase-3 commit | 3666 (+8) + XCUITest PocketWheelUITests ✓ | mac ✓ tv-sim ✓ vision-sim ✓ |
| 4 — best match + cold start + CarPlay row + intent | DONE | phase-4 commit | 3678 (+12) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 5a — adaptive run (plan, play, learn, persist) | DONE | phase-5 commit | 3706 (+28, 0 failures) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 5b — adapt to activity mid-run | DONE (same commit) | phase-5 commit | (incl. above) | ✓ |
| 6 — cloud (code + infra only, NOT deployed) | DONE (not deployed) | phase-6 commit | 3716 + node 68/68 | mac ✓ tv-sim ✓ vision-sim ✓ |

## Decisions made while building (beyond §9)

- **Favorites attribution.** There is no "play the Favorites filter" surface in Browse (Browse plays singles), so `fav_songs` enters attribution as a MEMBERSHIP: a no-origin play of a ♥'d song credits "Favorite songs" in the §1.5 fallback. `historyContext`/`originCollection` also resolve `fav_songs` (and catalog `pl_…` ids) for any future caller that stamps it as an origin.
- **Mix origin** rides per Auto-DJ ROW (`AutoMixItem.originCollectionId`, persisted in `AutoRow`), not a single engine field, because two-crate mixes interleave crates.
- **Motion opt-in** lives in its own device-local document (`pocketdj-listening-motion.json`, `ListeningMotionStore`) rather than `SettingsStore` — same pattern as places & trips; the opt-in is per device because the coprocessor and permission are. Not gated on listening pockets (the wheel is local).

## Test-run notes

- Every full run here also shows the same load-dependent flakes as the untouched Phase 1 control run: `TransferCoordinatorTests` (two background-QoS 5 s waits) and `SetlistPlayerTests.testCloudStreamAnalogArmsLengthBoundaryAndAdvances` (a timing wait). A Phase 2 run once saw the test host killed repeatedly ("Termination requested by simulator host" / "Restarting after … test timeout") with load average ~400; the identical tree re-ran clean (3666, no restarts) and a Phase 1 control run also ran clean, so it is environmental.

- Phase 1 full run: 3632 executed, 6 failures — all in `TransferCoordinatorTests` (two tests that wait 5 s on a `DispatchQueue.global(qos: .background)` hop). Reproduced alone while the machine's load average was 450–650 (other agents' Gradle + Swift builds); background QoS starves under that load. Not wheel code (the tests touch no wheel type). Re-verify when the machine is quiet.

- Phase 3 screenshots: `wheel-shots/p3-wheel-iphone.png` (seeded wheel, Thursday focused) and `p3-wheel-card.png` (Tuesday 8 AM · CarPlay card after a tap, from the XCUITest).
- Wheel UI deviations: the weekday fisheye is chosen with a Mon…Sun row under the wheel (plus letters drawn on each ring) rather than tapping the tiny letter at 12 o'clock — the letter targets collide with the midnight cells; the "Recurring pockets" VoiceOver rotor is spoken custom content (each ring is ONE adjustable element, so there is nothing for a rotor to jump to). Pinch-to-day-donut (Phase 3b, iPad nice-to-have) not built. tvOS never builds the wheel UI (fenced); History ▸ Pockets there stays the cloud list.

- Phase 4: tier T2 reuses `InThePocketScorer.cloudProfile` directly (it was already `static`, so no refactor was needed). The ×1.15 cloud boost uses the results' overall round-learning `pocketRate ≥ 0.5` (per-pattern rates don't exist in the results contract). Phase 4 shipped an interim ▶ (seed songs + the dominant collection via `playSongIds`); Phase 5 replaces it with the adaptive run.

- Phase 5 decisions: **W2 invariant** — queued run rows = 100 − played-through − (1 if the sounding run row's verdict is pending); the sounding row counts as done at ≥ 90 % of its live fraction (so no 101st song starts), and one spare row stays queued while the 100th can still be skipped; a skip tops the queue up from the planner (`PocketRunStore.rowsNeeded`). **Artist multiplier** — the §4.3 formula as printed gives 0.5 for one fast skip, contradicting its own example (0.33) and ban rule; negative evidence counts double for artist/album so 1 fast skip = 0.333 (banned), 2 ordinary skips = 0.294 (banned), 1 ordinary = 0.455. **Bans** come from the run's own verdicts only; the cross-run fold shifts multipliers but never bans (W5). **W7** — a Mix-mode profile starts the run as a Mix Auto-DJ queue (deck-loadable songs only; ≥ 10 needed, else the sequencer); live re-plan/top-up apply to the sequencer path (the Mix path keeps its initial 100 — noted as a follow-up). The centre ⏸ toggles playback (it does not end the run). Up Next "Re-tuned ✦" badge: the store exposes `retunedUids` for 4 s but the Up Next row badge itself is not drawn yet (follow-up).
- Phase 5b: opt-in toggle "Adapt pocket runs to walking & running" (Settings ▸ Pocket Wheel, under the motion toggle). Live CoreMotion updates only while a sequencer run plays; a change sustained ≥ 3 min into running / walking / driving re-targets the remaining replaceable rows toward the best moment for that mode (once per mode per run), through the same protected `replaceUpcoming`.

## Phase 6 — cloud (code only; NOTHING deployed)

App (upload contract, additive — the app↔cloud goldens are byte-identical):
- `ListeningPocketsUploadEvent` gains `mode` (only SENSOR modes: running / walking from CoreMotion, trip from automotive/cycling motion — W4) and `run` `{id, moment, slot, collectionId}` for wheel-run plays; both absent otherwise. The upload fingerprint appends them only when present, so old plays never mass re-send; a settled motion / run tag re-sends that play once.
- `PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypeFitness` (linked, not tracking, app functionality + personalization).

Lambda (`scripts/lambda/listening-pockets`):
- `store.mjs cleanEvent`: keeps a known `mode` and a well-formed `run` tag (dropped otherwise); merge upgrades a surface mode to a body mode, never back; run tag write-once.
- `analyze.mjs`: `mode` is a CONTEXT dim (sensor modes only — surface modes would duplicate `source`/`carPlay`/`trip`; measured: deriving them pushed 14 source + 6 mood features out of the fixture pockets, so they are not a dim); a run row's collection is its `playContext` (contextKind "wheel"); `wheelRunRounds` turns runs into WEAK round labels (≥ 80 of 100 played through ⇒ positive for its moment's dayType|timeBucket[|place/trip] and its dominant collection; less teaches nothing) merged into `learnFromRounds` — absent runs ⇒ identical documents. `surfaceModeOf` exported for consumers wanting the full §1.3 mode.
- Tests: node 68/68 (4 new wheel tests); goldens unchanged (no regeneration needed).

**To deploy (Levi's OK required; green account, profile llc):** code-only update of the existing function — no new AWS resources:
`POCKETDJ_ENV=green AWS_PROFILE=llc scripts/lambda/listening-pockets/deploy.sh` (idempotent; updates `pocketdj-listening-pockets` code, re-asserts its routes/rule). **Order is safe because of a capability gate, not because old servers ignore unknown keys:** an old Lambda would 2xx a batch while DROPPING `mode`/`run`, and the app would then record the new fingerprint and never re-send — lost forever. So the new Lambda echoes `caps: ["wheel"]` on every POST /events, the app stores it (`SyncDoc.serverCaps`), and only THEN puts `mode`/`run` on the wire. Plays uploaded before the deploy carry neither field and are fingerprinted without them; once the cap is seen their wire rows (and fingerprints) change and they re-send once with the fields. Deploy whenever; nothing is lost either way.

**Levi follow-up (App Store Connect, not touched):** add **"Health & Fitness ▸ Fitness"** (linked to the user, app functionality + product personalization, not tracking) to the App Privacy label before shipping a build with Phase 6.

## Screenshots (iOS simulator, `PDJ_SEED_POCKET_WHEEL`, nothing playing)

`wheel-shots/` in the session scratchpad: `p3-wheel-iphone.png` (seeded wheel), `p3-wheel-card.png` + `p6-wheel-card.png` (Tuesday 8 AM · CarPlay card after a tap, from the XCUITest), `p6-wheel-bestmatch.png` (Thursday 1:30 PM: centre caption "Weekday middays · Chill Lunch · 8 plays", ring in Chill Lunch's colour). Final XCUITest + screenshots ran on a throwaway simulator (since deleted): the shared `3FE7AC66` had another agent's install on it (the seeded launch landed on an empty History), the coordinator-flagged contamination.

## Needs a device / a drive to verify

- **Motion (Phase 1/5b):** the Motion & Fitness prompt on enabling "Notice walking & running"; that a settle pass stamps `motion` on real plays after a walk / run / drive (check History export or a DiagLog `pocketwheel motion settle stamped=` line); "Adapt pocket runs to walking & running" re-targeting after ≥ 3 min of a sustained change (DiagLog `pocketrun retarget`). The simulator has no motion coprocessor.
- **CarPlay (Phase 4):** the "▶ Pocket for now — <collection> · <day hour>" row and "Pockets right now" list on the For You tab; tap starts a run and shows Now Playing. Template plumbing is not headless-testable (the model rows are unit-tested).
- **Dead air (Phase 5):** run transitions vs the 10-24 baseline (`scripts/deadair-report.py` after a drive); the replan's "next row only with ≥ 30 s runway + immediate re-prefetch" rule under real AM / rip timing; an in-flight rip is never swapped for another capture.
- **A real 100-song run:** the stop at the 100th played-through song (no 101st), skips topping the queue up, Drake-style bans (`pocketrun replan … banned=[…]`), and the past-runs strip on the cell card.
- **W7 Mix runs:** a Mix-mode best match loading into Mix Auto-DJ with ≥ 10 deck-loadable songs.

## Adversarial review fixes (8acb9467 → review-fix commit; 3719 executed, only the TransferCoordinator load flake; node 68/68; mac ✓ tv-sim ✓ vision-sim ✓)

1. **HIGH — run edits only while the run owns the sequencer.** `PocketRunStore.ownsSequencer` (`isRunning && sourceSetlistId == pwr_<id>`) gates trim, top-up, re-plan (start AND apply) and re-target; a lost sequencer only learns, then the run ends after the 10 s grace. Test: `testLosingTheSequencerFreezesTheRunAndEndsIt`.
2. **MED-HIGH — no `pwr_` context ids.** The upload's context is the run row's collection (`pocketRun.rowCollectionId`), never the queue tag; `ListeningPocketsCollections.context` refuses `pwr_` and `fav_songs` and maps `pl_` to `source`. Test: `testProductionHookTagsRunPlaysAndUploadUsesTheRowCollection` (real hook context → record → `wireEvent`).
3. **Data-loss on deploy order** — capability-gated (see Phase 6 deploy note). Lambda echoes `caps`; node test pins it.
4. **MED — repeat:** `SetlistPlayer.effectiveRepeatMode` is `.off` while a `pwr_` run owns the sequencer; the sticky `repeatMode` is never written. Test updated (`testRunTreatsRepeatAsOffWithoutClobberingTheSticky`).
5. **MED — main-thread work:** top-up scores the pool on a detached task, appends on main only if the run still owns the sequencer, and backs off 30 s when nothing qualifies; verdicts come from the one bounded tail walk back to the run's start (no full-history scan). Test: `testTopUpRestoresTheHundredRowInvariant`.
6. **MED — failures surface:** `PocketRunStore.start` / `PocketWheelController.play*` return whether a run started; `IntentServices.playPocketForNow` / new `playPocketMoment` throw `noPocketFits` (spoken: "Not enough playable songs fit your pocket right now…"); CarPlay goes through those doors (onboarding veto + readiness) and toasts instead of opening an empty Now Playing. Tests in `CarPlayPocketWheelTests`.
- Low, fixed: top-up and replacement rows are edition-stamped like `play()` rows; pinned run rows count toward the 100 (only unpinned rows are trimmed); a held (restored, not yet ▶) run does no per-tick work; live activity updates restart on relaunch mid-run (and stop at run end); motion-derived `mode` uploads only while "Notice walking & running" is on; users who declined cloud pockets see the wheel without the List segment (no re-offer).
- Production play tagging now lives in `PocketDJApp.historyPlayContext` (the rips/coordinator hook calls it), so tests exercise the real path.

## Remaining / follow-ups

- Levi: add **"Fitness"** to the App Store privacy label before shipping Phase 6 (W4). Not touched by this build.
- Mix-path (W7) runs don't replan/top-up live (sequencer path only).
- Up Next "Re-tuned ✦" row badge (store exposes `retunedUids`; the row view doesn't draw it yet).
- Pinch-to-day-donut (Phase 3b iPad nice-to-have) not built.
- Android port (§7) not started; the shared fixture `apple/Tests/Fixtures/pocket-wheel-history.json` is ready for it.
