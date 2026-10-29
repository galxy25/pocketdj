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
| 6 — cloud (code + infra only, NOT deployed) | todo | | | |

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

## Remaining / follow-ups

- Levi: add **"Fitness"** to the App Store privacy label before shipping Phase 6 (W4). Not touched by this build.
- Device/drive-only verification list: see the final report section at the bottom (filled as phases land).
