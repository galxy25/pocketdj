# Pocket Wheel — build status

Design: `docs/design/pocket-wheel.md` (decisions W1–W7 in §9, 2026-10-29).
Branch: `feat/pocket-wheel` (worktree `pocketdj-wheel`). NOT merged to main, NOT shipped to TestFlight.

Gates per phase: iOS unit suite on sim `3FE7AC66…` with the executed count moving up from the 3608 baseline; macOS + tvOS-sim + visionOS-sim builds green.

## Phases

| Phase | State | Commit | Unit tests (executed) | Platforms |
|---|---|---|---|---|
| 0 — attribution fixes + event fields | DONE | phase-0 commit | 3622 (+14) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 1 — motion (CoreMotion settle, opt-in) | DONE | phase-1 commit | 3632 (+10) | mac ✓ tv-sim ✓ vision-sim ✓ |
| 2 — moment engine + palette | todo | | | |
| 3 — wheel UI | todo | | | |
| 4 — best match + cold start + CarPlay row + intent | todo | | | |
| 5a — adaptive run (plan, play, learn, persist) | todo | | | |
| 5b — adapt to activity mid-run | todo | | | |
| 6 — cloud (code + infra only, NOT deployed) | todo | | | |

## Decisions made while building (beyond §9)

- **Favorites attribution.** There is no "play the Favorites filter" surface in Browse (Browse plays singles), so `fav_songs` enters attribution as a MEMBERSHIP: a no-origin play of a ♥'d song credits "Favorite songs" in the §1.5 fallback. `historyContext`/`originCollection` also resolve `fav_songs` (and catalog `pl_…` ids) for any future caller that stamps it as an origin.
- **Mix origin** rides per Auto-DJ ROW (`AutoMixItem.originCollectionId`, persisted in `AutoRow`), not a single engine field, because two-crate mixes interleave crates.
- **Motion opt-in** lives in its own device-local document (`pocketdj-listening-motion.json`, `ListeningMotionStore`) rather than `SettingsStore` — same pattern as places & trips; the opt-in is per device because the coprocessor and permission are. Not gated on listening pockets (the wheel is local).

## Test-run notes

- Phase 1 full run: 3632 executed, 6 failures — all in `TransferCoordinatorTests` (two tests that wait 5 s on a `DispatchQueue.global(qos: .background)` hop). Reproduced alone while the machine's load average was 450–650 (other agents' Gradle + Swift builds); background QoS starves under that load. Not wheel code (the tests touch no wheel type). Re-verify when the machine is quiet.

## Remaining / follow-ups

- Levi: add **"Fitness"** to the App Store privacy label before shipping Phase 6 (W4). Not touched by this build.
- Device/drive-only verification list: see the final report section at the bottom (filled as phases land).
