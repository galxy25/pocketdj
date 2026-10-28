
## Wave 1
Merged (clean, no conflicts): SURF-1, GM-2, MIX-0, BRW-1, COL-1, SVC-12. Tests: 626 run, 0 failures (count moved from ~275 baseline).
Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave1/):
- SURF-1: PASS launch lands on History; 7 destinations, label only on selected; Collections restored after force-stop; Games placeholder opens. NOT verified: rail layout (wm size 1280x800 is only ~488dp at 420dpi so stays bottom bar; needs wm density change), staged-push route, Settings block order.
- COL-1: Collections screen lists playlists/pockets; fixture adb-push step not run.
- SVC-12, BRW-1: emulator steps not run (timing logs / filter UI).
- GM-2, MIX-0: pure JVM, pass.
No FATAL/ANR in logcat.
Open issues: nav label "Collections" truncates to "Collecti" at 411dp; amPlaylistId persistence decision (COL-1); amrec_album_ preview fallback deferred (SURF-1); Browse must consume NavRequestBus.pendingBrowseQuery; 13 screens still collect full catalog state (SVC-12 partial).

## Wave 2
Merged: SVC-5, COL-2, SURF-2, BRW-3, MIX-3, BRW-8 (only conflict: di/BrowseGraph.kt, BRW-3 settingsSections + SURF-2 flushables, both kept). Tests: 812 run, 0 failures (626 -> 812). assembleDebug green.
Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave2/). Debug-only seams added to Settings > Debug (Recs section + Seed 500 songs) for BRW-8, BRW-3, COL-2 steps.
- SVC-5: PASS (fake non-AWS-valid key). Debug shows DISABLED - no diag key; key paste+import -> Key: AKIA..; real S3 PUT answered HTTP 403 (expected, fake secret); offline -> FAILING UnknownHostException; network back + telemetry on + tapping -> FAILING HTTP 403 (retry is event-driven, not timer-driven). Capture on/off -> saved session file, Share opens the system chooser. NOT verifiable: object landing in s3://pocketdj-logs-623170744161/diag/ and .pdjdiagkey From-file import (need a real write key from Levi).
- COL-2: PASS. Seed 500 songs (no flush) -> HOME -> force-stop 0.3 s later -> relaunch: Seed500 playlist has 500 songs (ON_STOP flush works). Shuffle-play of the 500-song playlist: Now Playing opens, no ANR/FATAL; gfxinfo on software-rendered headless emulator 28% janky, p50 25 ms, p90 105 ms (not a device number).
- SURF-2: PASS with caveat. Songs filter survived HOME + force-stop + relaunch. dumpsys jobscheduler shows both WorkManager jobs; forced run dispatches RipReconcileWorker and StoragePruneWorker but WorkManager defers a periodic job run before its schedule, so no manifest refresh log; the worker body is not exercised on the emulator.
- BRW-3: PARTIAL. Settings > Explicit versions toggle ON persists UI-side; Edition probe (debug) resolves sng_1a7f6bc854af to explicit id 1771706119 with pref=true. The "song detail shows the resolved play id" half cannot pass until PlaybackController is wired to resolveForEdition (follow-up package). Device-only: real explicit/clean streaming.
- BRW-8: PASS. Load timbre corpus -> 19,864 rows online (roadmap said ~14,916, corpus has grown); cold-start offline (wifi+data off, force-stop) -> 19,864 rows from disk cache.
- MIX-3: no emulator steps (pure DSP, unit tests only).
No FATAL/ANR from com.levi.pocketdj in logcat.
Open issues: nothing calls NPLog/DiagLog yet outside diag/ and Debug (a capture with no app traffic saves no session); PlaybackController edition wiring; worker cold start still builds AppGraph (SURF-2); TimePitch allocates a new Sonic per applied step, no seam crossfade, needs device check (MIX-3); WorkManager periodic body untested on emulator; "Add to playlist" write-back resolution / membershipRevision not built (COL-2).

## Wave 3
Merged (all clean, no conflicts): SVC-1, SURF-3, MIX-2, COL-10, MIX-1, STU-1. Tests: 1070 run in the XML results, 0 failures/errors. assembleDebug green; connectedDebugAndroidTest 6/6 on the pocketdj AVD after one fix.
Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave3/):
- SURF-3: PASS. pm clear -> stage 1 (name, Use on this device) -> stage 2 (killed + relaunched: resumes stage 2; Continue without Apple Music) -> stage 3 (toggled AM off) -> Browse loads with only My Vinyl + My Digital; relaunch shows no onboarding; forced flow via `--ez pdj.showOnboarding true` shows it on an existing install. Real AM sign-in is device-only.
- COL-10: PASS. Songs row heart -> History "Hearted"; Favorites filter shows only it; unheart -> "Removed heart" row; relaunch -> still unfavorited.
- MIX-2: instrumented Mp3DecoderInstrumentedTest 6/6. FOUND + FIXED: after any mid-file seek the emulator decoder returned ~8 frames (about 8.8k samples) of silence, failing seekMidFileLandsOnTheSameSamplesAsLinearDecode; Mp3Decoder.WARMUP_FRAMES 2 -> 12 makes seek bit-exact (lag 0). The 529-sample click test passes (CODEC_TRIMS_DECODER_DELAY=true is right). Audible output: device-only.
- STU-1: PASS (partial). `--ez PDJ_SEED_STUDIO true` writes pocketdj-studio.json + tone files; relaunch persists. NOT run: delete-tone -> prune and revoked-SAF steps (the sandbox blocked an adb rm; both are covered by JVM StudioReconcile tests); SAF persistence is device-only.
- SVC-1: PASS with a throwaway mock rip server and a temporary debug cleartext config (not committed): POST /rip -> Preparing -> the 20 s interactive wait ends and RipJobTracker keeps polling /jobs until ready; on ready the app asks /rips/presign once and plays the presigned URL. The "Still ripping" snackbar text was not caught on screen (shown for a few seconds only).
- MIX-1: stores have no UI yet (Mix tab is a placeholder), so the adb run-as file check could not be exercised; covered by 42 JVM tests with iOS fixtures.
No FATAL/ANR from com.levi.pocketdj in logcat.
Open issues: COL-10 remapSongIds + backup/profile-sync registration; SURF-5 must call onboarding.vetoIfIncomplete(); launch work outside screens must await waitUntilComplete(); Browse debug seeds should be added for Mix stores; STU-1 reconcile not sequenced after onboarding; Q8/Q9 added.

## Wave 4

Merged (no conflicts): PB-1, SVC-2, SURF-4, BRW-5, MIX-4, BRW-9. JVM suite: 1366 tests, 0 failures, assembleDebug green.

Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave4/); no FATAL/ANR in logcat:
- SURF-4: pocketdj:// and https jukebox links delivered, no crash; pm clear + link parks, onboarding shows, after Start DJing lands on Jukebox tab (PASS). Join panel not shown (seam awaits JBX-2); play link / .pdjcollection import seams unassigned (partial, as documented). App Links verification device-only.
- BRW-5: cloud toggle works; with no credentials shows "Add OpenSearch credentials in Settings to search online." (PASS). NOT RUN: key paste/'midnight' results/BPM sort reset, because the read-only djpocketsearch key is not available to the integrator.
- PB-1, SVC-2: NOT RUN on emulator (need a seeded playlist with rip rows and live rips bucket + burn UI/debug action; neither seeded/available). Covered by JVM tests only.
- MIX-4: instrumented smoke (MixGraphSmokeInstrumentedTest) not run this wave; JVM render tests pass. Cue on real stereo is device-only.
- BRW-9: pure, n/a.

Open: SVC-2 drainPendingAfterRip/flush hooks unwired; MIX-4 retry on unaligned handover, looping decks; PB-1 system next/previous interim (PB-2 replaces); see Q10-Q12.

## Wave 5

Merged (no conflicts): PB-2, SVC-3, BRW-4, COL-4, MIX-6, STU-2 (plus committed wave-4 leftover debug seams first). JVM suite: 1620 tests, 0 failures (was 1366), assembleDebug green.

Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave5/); no FATAL/ANR from com.levi.pocketdj in logcat (the only FATALs are uiautomator-dump "already registered" from the adb tool itself):
- COL-4: PASS. Long-press a Browse song -> "Add to Playlist" menu; More... opens the sheet with the search field focused and keyboard up; created pocket "Zed" via the sheet (sheet dismissed after add, default); reopened menu shows Zed with a check; tapping it removes with no snackbar; History > Collection shows Added then Removed rows. Not run: typing two letters to narrow the list (only one pocket existed).
- BRW-4: PARTIAL PASS. Album Shuffle starts a Now Playing run and History reads "Album . You're The One For Me". Album and song detail show Share + Add buttons. NOT run: Lyrics section / airplane-mode cache (no song with lyricsStatus found is reachable and no lyrics-cache dir yet), Storage lyrics category screenshot, audio-analysis section.
- STU-2: PASS (with known gap Q13). connectedDebugAndroidTest for studio package: native lib loads and kernels match Kotlin mirrors on x86_64, native stretch exact frames + pitch, decode/encode/renderLoop/1 s playback through AudioTrackSink OK. AAC priming not trimmed (relaxed tolerances).
- SVC-3: PARTIAL. dumpsys jobscheduler shows the WorkManager SystemJobService job registered for com.levi.pocketdj. NOT run: 5-song burn + force-stop survival, 400 error-row check (no seeded collection with rips, no rip server reachable, no burn debug action); JVM tests only.
- PB-2: NOT RUN. Playback does not start on the emulator without a reachable rip URL (media session stack empty), so media_session dispatch/dumpsys steps could not be exercised. JVM tests only (29). Device-only: BT/AVRCP, lock-screen render.
- MIX-6: NOT RUN. Needs a debug action to open a stream (none exists) and a rip server; JVM tests only (28).

Note: connectedDebugAndroidTest uninstalls the app, wiping seeded data; run it last.

Open: Q13-Q16 added. MIX-6 yieldBackgroundDownload wiring deferred to SVC-3 TODO; ARCHITECTURE-ANDROID.md ledger rows for the six packages still to be updated.

## Wave 4 verification

Emulator-verified (emulator-5554) against the live catalog + public rips (debug seeds: Settings > Debug "Seed rip playlist" / "Play seed queue" / "Burn first 3"). JVM: 1621 tests, 0 failures. `connectedDebugAndroidTest`: 7/7 PASS (AudioDecoder, Mp3Decoder x4, MixGraphSmokeInstrumentedTest.tapPulseAdvancesWhileAToneRendersOnTheAudioTrackSink). Logcat lanes now mirror to `PocketDJ.<lane>` (`adb logcat | grep PocketDJ.playback`).

- PB-1 step 1 (track start per row, rows advance at clip end): PASS. `[playback] track start song=.. index=i/n backend=rip|burned`; `advance ... cause=AUTO` at natural end (digital rips; analog clips not exercised, no analog seed). Only verifiable after the SetGatedPlayer fix below (the wave-5 PB-2 merge broke advance).
- PB-1 step 2 (10x rapid next): PASS. 10 media-next presses -> 10 `cause=USER` advances, one live row, no stale load afterwards.
- PB-1 step 3 (metadata-only row between playables): PASS. `advance: unplayable ... reason=METADATA_ONLY` + `cause=UNPLAYABLE_HERE`, set continues.
- Dead source mid-song (network off): PASS. `engine error ERROR_CODE_IO_NETWORK_CONNECTION_FAILED` -> `item failed mid-song` -> advance, no replay, no dead air.
- Resolve-stall hop / start watchdog: not applicable to PB-1 (PB-3..PB-10 scope); NOT RUN.
- SVC-2 step 1 (burn against live rips): PASS. `files/burns` holds descriptive `Artist-Title-Album-Camelot-Key-BPM-<songId>.mp3` + `.txt` sidecars, plus `stem-*`, `analysis-*`; `pocketdj-burns.json` shows `state:ready`; the non-ripped song is recorded as an error item and the loop continues (BurnResult burned=2 notRipped=1).
- SVC-2 step 2 (delete an mp3, relaunch): PASS for the ledger (item dropped on launch). Minor: the orphaned `.txt` sidecar is left behind (not removed by reconcile).
- SVC-2 offline playback (wifi+data off): FAIL before, PASS after. The burned rung was never wired (`PlaybackController.localFiles` stayed `None`), so burned songs streamed from the network and died offline. Now `backend=burned`, full file plays offline, unburned rows hop.
- MIX-4: JVM + MixGraphSmoke instrumented PASS. Cue on real stereo / latency remain device-only.

Bugs fixed: (1) burned rung wiring (PlaybackGraph.wire + `burnedLocalFile`), (2) wave-5 regression: `SetGatedPlayer.GatedListener` used `Player.Listener by d`, which Kotlin does not delegate for Java default methods, so the MediaSession controller saw IDLE and no row ever advanced; now explicit forwarding + regression test, (3) lane logs mirrored to logcat, engine state/error lines added.

Note: a concurrent wave-5 session shares this emulator and worktree (the app was reinstalled/wiped twice mid-run; the wave-5 "PB-2/SVC-3/MIX-6 NOT RUN, playback does not start" results were this same bug).

## Wave 6

Merged: PB-3, PB-6, SVC-4, MIX-5, SURF-10, COL-3. Conflicts resolved: PlaybackController imports (PB-3), SetlistSequencer (PB-3 health vs PB-6 gate-halt: one `pausedByCascade` flag now serves both the cascade breaker and the autoAdvanceGate halt; `cascadeHalted` removed), SequencerState duplicate field, PlaybackGraph (SVC-4 shared `burnedFirst` resolver replaces the inline burned lookup). JVM suite: 1906 tests, 0 failures, 0 skipped (was 1620); assembleDebug green.

Integration fixes: duplicate `pausedByCascade` declarations; RipOnDemandSession now remembers the real failure so Media3's retry reports it (was a misleading "rip resolve not in flight"; this exposed the CLEARTEXT cause when testing with an http:// server URL) + regression test; debug seeds added in Settings > Debug: "Seed duplicate pocket" (COL-3), "Mix: load 2 + play / twist / status / restore" (MIX-5).

Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave6/); no FATAL/ANR from com.levi.pocketdj:
- PB-6: PASS. Playlist Play opens Now Playing; record frames change while playing, identical after pause (frozen), resume continues; landscape keeps transport usable; mini bar "Open Now Playing" returns to the deck; cascade banner "Playback paused - the last few tracks didn't play" shown, Play retries the row. Not verified: exact resume angle (frame-equality only).
- PB-3: PASS. Unreachable https rip server: `resolve stalled 6s ... hop to on-device` logged; airplane mode: `silent` supervisor lines, 3 quick failed rows -> `cascade-stop`; `files/pocketdj-dead-air.json` has activeSeconds + byPair transitions. L1/L2/L3 escalation lines not seen (rows failed fast, before the 8 s/20 s watchdogs). Device-only: cellular dead zones, Apple Music lane.
- SVC-4: PASS. Burned playlist plays offline from local files (`backend=burned`); device mode skips un-burned rows (`reason=NOT_ON_DEVICE`); burn bar (Rip/Burn/device-cloud toggle) on playlist and pocket detail. Not run: the "none burned -> banner once" case; mini-player glyph only confirmed via the "Playing from device" label.
- MIX-5: PASS. Two burned tracks load and play, tempo/vol/crossfader setters take effect (positions advance at 1.05x/0.97x), `mixdiag` heartbeat render=1 sigAge~0 for both decks; after force-stop + relaunch the decks restore parked at 17.7 s / 16.8 s, silent (restore triggered by the Debug button, see Q18). Device-only: audible tempo/pitch quality, cue routing.
- SURF-10: PASS. Live broker (funnel): session started, play/pause/resume/pause/skip leaves one Played row per track; Settings "Require access tokens by default" off -> create view shows off, back on -> on.
- COL-3: PASS. Pocket menu > Remove duplicates -> "Removed 1 duplicate", pocket shows one row; Playlists sort menu > Remove duplicates in all collections -> confirm -> alert; second run "No duplicates found".

Open: Q17-Q21 added. ARCHITECTURE-ANDROID.md ledger rows for wave-6 packages still to be updated.
