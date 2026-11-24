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
