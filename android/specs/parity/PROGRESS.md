
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
