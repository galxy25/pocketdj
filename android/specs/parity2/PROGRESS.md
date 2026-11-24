# Android parity 2 progress

## Wave 1

Merged: P2-ALB-1, P2-DATA-1, P2-PB-1, P2-POC-1, P2-POC-2, P2-DJ-1, P2-MM-1 (one conflict, BurnStore/ServicesGraph constructor args between ALB-1 and MM-1, resolved by keeping both `segmentStartOverride` and the MM-1 buffer lambdas). P2-LIB-1 was not in this wave's merge list (its build was blocked by the machine build lock) and is still unmerged.

Tests: `:app:testDebugUnitTest` 5904 tests, 0 failures; `:app:assembleDebug` green.

Emulator (emulator-5556, debug APK, real rips/CDN data; shots in pocketdj-parity2-pkgs/_shots/wave1/):
- P2-ALB-1 PASS: new debug button "Burn+play analog" burns an analog song; the burned file is the 101 MB shared side (`...alb_b81acaa1c43b.mp3`), ledger startMs=635135, the 22 s window plays and ends (not the cut).
- P2-DATA-1 PASS: seeded a session with iOS 1.0.6 fields (npMixMode, fxLock, djMode with seed 18446744073709551615, row plan/djUserNext/futureRowKey, futureTopLevel) on real song ids, relaunched, played; Android rewrote the file (index/position moved) and every iOS field and the 2^64-1 seed survived byte-for-byte.
- P2-PB-1 PASS: throttled the emulator network (`adb emu network speed 1:1`) with the seed queue; stalled rows hopped forward to NEW rows three times (5cc8 to 40fb to a08f to 3bf0), never back; restoring the network logged `stall episode end reason=first-audio abandoned=3`. Offline (no network at all) rows fail fast and the existing cascade-stop fires instead; that is not a stall.
- P2-POC-1 PASS: pushed an iOS-shaped play-history with pocketRun/motion, relaunched and played; both pocketRun tags and motion kept, event count preserved.
- P2-POC-2 PASS (user playlist): Auto browse smoke play of a SeedRip playlist song recorded `originCollectionId=pls_...`, source=playlist. SOURCE-playlist (`pl_`) path is covered by unit tests only (Apple Music local rows are not playable on the emulator).
- P2-DJ-1 PASS: Mix load 2 + play, AutoDJ start, AutoDJ skip: `mixadvance skip -> next ready=1`, no crash.
- P2-MM-1 PASS: after Burn first 3, `temporaryHolds` is absent (explicit burns never temporary). New debug button "Mix stream buffer" opens a stream with AssetOrigin.Buffer: hold written with expiresAtMs = createdAtMs + 48 h.
- No FATAL EXCEPTION or ANR from com.levi.pocketdj in logcat.

Changes made by the integrator: DebugScreen got two buttons ("Mix stream buffer", "Burn+play analog") so the MM-1 and ALB-1 emulator steps can run.

Open issues:
- Device-only (not verifiable): P2-PB-1 real MusicKit check (burned row then stalled AM-only row must hop to a burned row, AM song never starts over the hop target).
- P2-PB-1: the roadmap step says a hop at about 6 s; the start-stall hop actually fires at 20 s (rekick at 8 s). Behaviour is correct, the expected timing in the step text is off.
- The emulator image carries an old release build (versionCode 1793355941) from earlier; the debug APK needed an uninstall first, which wipes app data.
- P2-LIB-1 still to merge.

## Wave 2

Merged (no conflicts): P2-PB-2, P2-DJ-2, P2-DJ-4, P2-DJ-5, P2-MIX-1 (carries P2-LIB-1's code, merged into it with two LIB-1 fixes; LIB-1's own status file still says in-progress, so treat LIB-1 as landed via MIX-1), P2-MM-2, P2-MM-4, P2-MM-7.

Tests: `:app:testDebugUnitTest` 6165 tests, 0 failures, 0 skipped; `:app:assembleDebug` green. No integration fixes were needed.

Emulator (emulator-5556, which has the real catalog/rips; debug APK installed over wave-1 data; shots in pocketdj-parity2-pkgs/_shots/wave2/):
- P2-PB-2 PASS: Seed rip playlist + Play seed queue, two skips: `transition cause=USER seq=1..4` (an UNPLAYABLE cause=UNPLAYABLE seq=3 for a metadata-only row), `queueGen=1` at start, `queueGen=2` after Now Playing "Play next" (queue reorder). Pocket: build+start plays (start-ok). Kill + relaunch logs `held restore ... rows=13 index=4` and the player comes back paused.
- P2-DJ-2 / P2-DJ-4: pure Kotlin, no emulator step (covered by unit tests incl. the 30-case iOS-compiled battery for DJ-4).
- P2-DJ-5 PASS: Settings > Mixing opens the pane (Crossfades / Now Playing DJ Mode groups); Tempo match toggled off, app force-stopped and relaunched, still off.
- P2-MIX-1 PASS: pointed Import server at a local fake server that answers 401 (http://10.0.2.2:8099), Debug > Mix download SeedRip: Mix bar reads "The import server rejected this device's token (Settings > Import server)" with "Play in Now Playing" and "Stop collection download"; the server saw only 4 requests in about 80 s (no retry storm). "Play in Now Playing" starts the 13 crates in the sequencer (`source=mix`, start-ok). Settings restored afterwards.
- P2-MM-2 PASS (launch trigger): set one temporaryHold's expiresAtMs to the past while the app was stopped, relaunched: `temporary sweep reason=launch deleted=1 freed=39937728`, the other hold and the other burns untouched. The foreground-trigger line itself is unit-tested (TemporarySweepTest); the emulator run hit the launch trigger first.
- P2-MM-4 PASS (regression only, engine-only package): Play seed queue still plays; no `PocketDJ.np` prefetch lines because Stem Lock is off in this profile, so there is nothing to diff.
- P2-MM-7 PASS (regression): "Mix stream open" and "AutoDJ: start streamed" stream and play, `mixstream deck A start ... complete`, heartbeat position advancing, no underrun loops.
- No FATAL EXCEPTION or ANR from com.levi.pocketdj. Settings "Show advanced" (which reveals the Debug panel) does not survive leaving Settings, by design of that toggle.

Open issues:
- Device-only, not verifiable here: P2-MM-2 SAF picked folder on a real SD/USB folder; P2-MM-4 cellular vs Wi-Fi policy on a SIM phone.
- Not wired yet by design: `scheduleCapSweepIfNeeded` (Mix Mode off, P2-MM-4/5) and `sweepForDiskGuard` / DiskGuard footprint and the production `awaitPendingDownload` binding (P2-MM-5); loudness `isComplete` predicate (P2-DJ-11/MIX-2).
- New question P2Q9 (DJ chip wording). StrictMode disk-write on main in DeadAirMeter.save (pre-existing, debug builds only).

## Wave 3

Merged: P2-PB-3, P2-ALB-2, P2-ALB-3, P2-MM-5, P2-POC-3, P2-POC-4, P2-REM-1, P2-SURF-1 (one conflict: AccountDeletionService/Test key lists, edits + pocket-palette/profile-source kept). Unit tests: 6403, 0 failures; assembleDebug green.

Emulator (emulator-5556, shots in pocketdj-parity2-pkgs/_shots/wave3/):
- P2-PB-3 PASS: Up Next > Play next and a drag-reorder both log `row landed next uid=`; session file carries `djUserNext` only on the picked row and no `plan` on non-run rows (`pinned` is derived, never persisted).
- P2-SURF-1 PASS: For You tile (In Da Zone) > Play shows np-feedback; thumbs-up wrote an `accepted`/`nowPlaying` decision to pocketdj-rec-feedback.json (reserved zone scope adds no song, per spec); a normal playlist run hides the thumbs.
- P2-MM-5 PASS with a fix: lane steps and `hand-off row=... reason=landed` observed with PLAYING state kept through the swap (rip-server-free via new debug `npmix=publicrips`, throttled network). Bug found: a row preloaded as a stream whose file landed while it was still "next" never swapped; fixed by trying a hand-off at first audio (test added, P2Q10). `already-local`, `start-pending` (owed, retried on play: `reason=after-start`) and `no-local-file` refusals observed. The `refused reason=paused` line was NOT reproduced live (the pause never coincided with a landing in 4 tries); it is covered by SwapOnLandTest.
- P2-ALB-2 PASS (local half): an iOS-shaped pocketdj-edits.json pushed to the app showed the renamed title in the SeedRip list and the file was byte-identical afterwards. The sync-pull half needs a live sync backend (only the in-memory debug backend exists): not verifiable here.
- P2-ALB-3 PASS: lone analog songs log `clip start=14211 end=126224` (capped at next start, old rule gave 128558) and `start=1476766 end=1622355` (detected end + 15 s, old 1599233).
- P2-POC-3, P2-REM-1: pure, no emulator step. P2-POC-4 PASS: debug `palette=a,b` broadcast created files/pocketdj-pocket-palette.json with two slots.

Integrator changes: debug-only broadcast extras in NpMixWiring (`npmix=publicrips`, `playsong=<id>`, `palette=a,b`), a `clip` playback log line, first-audio hand-off attempt + test.

Open: StrictMode disk reads on main from `NpMixWiring.replanLane` (BurnStore.localUrlPreferringCut via the lane re-plan; debug-only warning, worth moving off-main). Device-only: audible gap during swap-on-land.
