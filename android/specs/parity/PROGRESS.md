
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

## Wave 7

Merged: PB-5, SURF-5, MIX-7, SVC-11, SVC-15, STU-3. Only conflict: docs/ARCHITECTURE-ANDROID.md ledger row (SVC-11), kept the fuller row. Unit suite 2189 tests, 0 failures, assembleDebug green.

Integration fixes: CollectionBurnBar button row now a FlowRow (Stemify as a 3rd button squeezed the device/cloud toggle into a sliver); AppGraph.appleMusicApi wiring (SVC-15 had no consumer); debug probes (AM API probe, Mix download SeedRip) in Settings > Debug.

Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave7/); no FATAL/ANR from com.levi.pocketdj:
- PB-5: PASS. Skip at ~5 s via media-session next -> history row wasSkipped=true listenedFraction=0.079 tzOffsetMin/originInstallId set; natural end -> listenedFraction=1.0 no wasSkipped. History shows skip and check glyphs and highlights the live row. Repeat-one re-zero covered by JVM only (no repeat-one control driven).
- SURF-5: PASS. MEDIA_PLAY_FROM_SEARCH ("play my seedrip playlist") starts playback; pocketdj://play/playlist deep link plays; 3 static shortcuts + dynamic SeedRip listed in dumpsys shortcut. Mini player shows the track, not the collection name (Q26). Real Assistant voice: not verifiable.
- MIX-7: PASS via debug probe (Mix UI-2 not built): begin(SeedRip) -> "2 of 12 downloaded ripping=1 active=true". `mixdl` is a telemetry lane, not mirrored to logcat. Auto-DJ append hooks unwired (MIX-9/14).
- SVC-11: PASS. Burned dir holds 4 stems + analysis json per stemmed song; Stemify on SeedRip completes with "11 already stemmed / 1 unknown" summary (rip server unreachable from emulator, so a live Queued -> stemmed flip is not verifiable).
- SVC-15: PARTIAL. Library call returns NeedsUserToken signed out (PASS); catalog search returns Failure(timeout) because the dev token is minted by the unreachable rip server (infra, Q25).
- STU-3: PASS. Producer 7 segments; mic record 8.9 s row appears (permission granted via adb); SAF import of tone.wav opens editor (3.0 s); from-track carve of a burned song makes an 8.0 s sample with inherited 172.3 BPM grid; un-burned track shows the Rip-first state. Real mic quality, BT picker, DRM: not verifiable.

Open: Q22-Q26 added. ARCHITECTURE ledger rows for wave-7 packages still to update.

## Wave 5 verification

Emulator-verified 2026-10-28 (emulator-5554, post SetGatedPlayer fix) with Settings > Debug seeds. JVM: 2190 tests, 0 failures (+1 regression test). New debug seeds: "Burn 5 long", "Burn 5 (HTTP 400)", "Mix stream open".

- PB-2 media-session next/prev: PASS after a fix. `cmd media_session dispatch next|previous` advance the set (`advance cause=USER`, `rc cmd=next engine=exo verdict=handled`). Two real bugs found: (1) the MediaSessionService is created by the first play AFTER the sequencer already runs, so the command gate was never seeded: the first row showed no SKIP_TO_NEXT/PREVIOUS/SET_REPEAT/SET_SHUFFLE actions and `dispatch next` was silently dropped (fixed: `forwarding.syncGate()` once the session is built; JVM regression test). (2) `[transport] rc` lines were never logged for media-button/system commands because the "internal caller" test compared package names and legacy media-button controllers report our own package (fixed: the in-app MediaController now carries a connection hint `pdj.internal`).
- PB-2 play/pause: PASS. `dispatch pause|play` and `input keyevent KEYCODE_MEDIA_PLAY_PAUSE` toggle PLAYING/PAUSED, one `rc` line each. `dumpsys media_session` actions then include SKIP_TO_NEXT/PREVIOUS/SET_REPEAT_MODE/SET_SHUFFLE_MODE.
- PB-2 heart: found unwired (FavoriteCommand.seam never assigned; no custom action). Wired in AppGraph launch to the favorites store: the notification shows a heart, tapping logs `rc cmd=favorite verdict=handled` and the glyph fills (tap again unfills).
- PB-2 not done / not verifiable: single-song play (no debug seed; covered by JVM SetGatedCommands), headset toggle while BUFFERING (JVM only; device), kill + `KEYCODE_MEDIA_PLAY` resume (force-stop then PLAY key does not restore the queue: ResumptionSnapshot/onPlaybackResumption is PB-4's, Q15). Device-only: Bluetooth/AVRCP, lock-screen render.
- SVC-3 5-song burn + force-stop: PASS. Five 27-41 MB rips enqueued, `am force-stop` 1.2 s in: 5 transfer records + 5 `downloading` rows, no mp3. Relaunch: WorkManager re-ran the workers ~40 s later (WM retry delay), all 5 became `ready` with full files, `pocketdj-transfers.json` emptied. Foreground service/notification start+stop seen in WM logs (the "Downloading... n of m" text itself not screenshotted; POST_NOTIFICATIONS not granted by default, Q14).
- SVC-3 HTTP 400: PASS. A presigned-style URL with a bad signature returns S3's 400 XML: all 5 rows `error "download failed (HTTP 400)"`, bytes 0, no mp3 in files/burns, transfers file empty.
- SVC-3 jobscheduler: PASS. WorkManager SystemJobService jobs registered; `cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.levi.pocketdj <id>` shows RipReconcileWorker/StoragePruneWorker "executed before schedule" (periodic cadence is device-only).
- MIX-6 stream: PASS. "Mix stream open" on a 27 MB un-burned rip: `PocketDJ.mixstream: open ... cut=0`, bytes 0 -> 16.2 MB -> 26.96 MB (expected 26956002) in 2.5 s, `done ... adopted=1`, file lands in files/burns with a ready ledger row, cache/mixstream emptied. Added a logcat mirror (tag `PocketDJ.mixstream`) for the loader telemetry. Not run: resume after a dropped connection, stem sets, a Mix deck taking over a growing stream (Mix UI not built; MIX-9+).
- Environment traps: (a) the emulator's saved rip server URL was a blackhole (`https://10.255.255.1:9`, left by PB-3 testing) which made every burn presign hang ~40 s and report "couldn't get a playback URL"; cleared it in Settings > Import server. (b) With no reachable rip server MixStreamLoader cannot presign; the debug button sets `MixDebug.publicRips` to stream the public rips object instead.

Ledger: ARCHITECTURE-ANDROID.md rows for every merged package still marked Planned (waves 1-7, 22 rows) set to Merged with merge commit; PB-2/SVC-3/MIX-6 rows updated with the results above. Open: Q27-Q28 added.

## Wave 8

Merged: PB-4, BRW-2, GM-1, MIX-8, GM-5, PB-7 (one conflict: CollectionsStore.materializeNowPlayingSetlist existed in both PB-4 and PB-7; PB-7's upsert-from-QueueItem keeps the name, PB-4's keep-if-present variant is now `materializeNowPlayingSetlistIfMissing`). JVM: 2443 tests, 0 failures. assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave8:
- PB-4 PASS after a fix: session file is the iOS shape; after force-stop + relaunch the restore was invisible (mini player required a live player). Added a held "Paused" strip with play to MiniPlayerBar; relaunch now shows it, no audio, file mtime unchanged, play resumes the run. No crash.
- PB-7 PASS: drag reorder of an upcoming row, remove by X, search "love" then Add next for an album (3 tracks) and a song land after the current row (verified in the session file). Jukebox accept placement not driven (needs a guest request; JVM-covered).
- BRW-2 PASS: In-pocket filter narrows to members (13 playlist members, 1 pocket song), In SeedRip + Not-in SeedDup, long-press add to SeedDup drops the row (13 -> 12) with the list not reset. Note: the filter sheet moves while settling; taps need fresh bounds.
- GM-1 PASS: three cards, seeded runs (best 9, MwF 4), long-press delete Gem Collector, rotation during the dialog keeps it, Delete All -> empty, still empty after force-stop + relaunch.
- MIX-8 PARTIAL: Mix debug "load 2 + play" plays both decks with the new engine hooks, no crash. Stem toggle, loop and beat-pulse steps cannot run (no UI until MIX-13/14, no stemmed burn); device-only steps not verifiable.
- GM-5: pure JVM, no emulator steps.

Open: Q29-Q34.

## Wave 9

Merged: BRW-6, GM-3, COL-5, MIX-9, MIX-10, PB-8 (one conflict: di/MixGraph.kt, MIX-9's autoDj and MIX-10's streamDecks accessors are both kept). JVM: 2759 tests, 0 failures (the merge baseline of 2755 + 4 regression tests). assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave9. Mix and Games have no screens yet, so MIX-9/10 and GM-3 were driven through new Settings > Debug probes ("AutoDJ: start / start streamed / skip / pause / resume / status", "Gem: start / skip / status / end").
- BRW-6 PASS: Playback + Collection tabs; live (playing) glyph on the current row and "skipped" badges after quick skips; Hide skips hides them (list also lost the just-rewound song, which Rewind marks skipped); long-press -> Rewind to here -> confirm restarts at that song (cursor move in the live queue); Last played From/To date pickers filter correctly (a future From gives "No matches"); filters persist across force-stop + relaunch. Note: the Hide skips label is not tappable, only the switch.
- COL-5 PASS: long-press -> Select -> "1 selected"; Select all = 110833 (full list) and a search narrowed to 153 gave 153; Add to -> Pockets -> SeedDup grew by 153; with select mode armed in Browse, a pocket song tap opens the detail (no toggle). History > Collection shows one Added row per song.
- MIX-9 PASS after fixes: Auto-DJ banner "n / total - Deck X", skip and double-skip, pause -> hand-load -> resume, mixadvance lines. Lock-screen media pause does not suspend it (MIX-11 not wired, Q37). Fixed: the "no loadable next - N deferred" line was logged at 10 Hz (now once per change).
- MIX-10 PASS after fixes: ripped-not-burned crate streams (deck held 1.2 s then started on 7 s runway, completes, adopted into files/burns). Emulator netspeed throttling has no effect on the host-forwarded network, so hold/extend/"fade frozen" are covered by JVM only. Wifi cut right after start found two real bugs: (1) StreamDecks.autoHooks was never assigned, so a live deck whose stream died before audio never skipped ahead (now wired in MixGraph; wasLive also covers a held deck); (2) the Auto-DJ stayed "mixing" over two empty decks forever (new dead-live-deck lane in idleStep hands over to the next loadable song or ends the mix; recovered ~60 s after the network returned). Regression tests: StreamDecksTest, AutoDjTest x2.
- GM-3 PASS (engine, via debug probes): countdown -> RUNNING with audio, History rows read "Game - Gem Collector", Skip x3 advances cards and the player (cause=USER), playing an album mid-round ends the round (FINISHED) while the album plays, airplane mode: sequencer cascade-halts after 3 failed rows, round keeps running, no loop. Natural-end drift not run (rips are full length), JVM-covered.
- PB-8 PASS (no behaviour change with AM unavailable: rip/burn playback and the preview path verified, unit suite green); full-track DRM is device-only. Fixed: the AM rung now skips run-tagged game rows (GM-3 note), test added.

Open: Q35-Q40.

## Wave 10

Merged (clean, no conflicts): GM-4, COL-7, MIX-13, SVC-6, STU-4, SVC-8. JVM: 2880 tests, 0 failures after merge (the 2759 baseline moved by every package's new tests). assembleDebug green. Node: profile-sync 20/20 pass.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave10:
- GM-4 PASS after a fix: setup counts update after typing stops; 0 matches disables Start; settings (1:00, genre, years) restored after force-stop; a round plays, Skip works, a card filed into two pockets through the Add-to sheet shows "SeedDup +1 more" and scores once; summary + high score. BUG FIXED: a cold start straight onto Games left the catalog unloaded, so setup said "0 songs match" until Browse was visited (setup now kicks loadIfNeeded and re-counts when the catalog lands).
- COL-7 PASS: "Link to Apple Music playlist..." on a hand-made pocket -> picker -> Linked; the menu then shows direction picker, Sync with source, Sync from source now, Re-link. A removed song stayed removed after a catalog refresh; Settings > Collections sync toggle present (linked count text); "Sync from source now" works with the toggle OFF ("Already in sync" - the source membership was already in the pocket, so a real pull diff was covered by JVM only). Fixed a "1 linked item follow" grammar nit.
- MIX-13 PASS (via new Settings > Debug > "Mix: deck UI" harness, since the Mix tab is still the MIX-14 placeholder): two decks load and play, tempo/pitch/EQ/volume/crossfader sliders respond, VU/seek tick, stacked and side-by-side (landscape) layouts render. Waveform stays empty in the harness (no peaks provider; MIX-14 supplies it). The harness dialog is clipped ~136 px at the right edge in landscape on this emulator (display cutout); harness-only.
- SVC-6 PASS: Burn 10 (new debug seed) -> 9 burned; with a 4-song cap Prune now removed 16 downloads, freed 660 MB, kept the played songs and the 2 oldest never-played (never-played first, then oldest play); play-stats JSON recorded plays/skips; Delete songs by artist removed that artist's file. The 20 h gate and the worker cadence are covered by PruneWorkerGateTest only (Doze cadence is device-only). Fixed: the third delete button overflowed the row (now FlowRow).
- STU-4 PASS: 4-beat loop saved from a seeded sample (62446 frames); audition logs decoded=looped=expected=62446; after deleting the sample the loop still auditions and shows "Source sample removed"; Slice into pads auto-slice + Send pads to sequencer baked 4 pads into a pattern. Audible seam-click judgement is device-only.
- SVC-8: not deployed (needs AWS profile llc); node:test 20/20 against the in-memory store. The curl-against-deployed-API step is not verifiable here.

No FATAL EXCEPTION / ANR from com.levi.pocketdj in logcat.

Open: Q41-Q45.

## Wave 11

Merged: MIX-11, STU-6, BRW-10, STU-5, GM-7, SURF-6. One conflict (screens/producer/ProducerScreen.kt: STU-6 Cues + STU-5 Sequencer branches) resolved keeping both. JVM: 3128 tests, 0 failures after merge + fix (the wave-10 2880 baseline moved by each package's new tests plus 2 integration tests). assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave11:
- STU-5 PASS: seeded pattern, toggled 4 steps, Play logs `pattern start ... armed slots` rolling horizon and stopPattern parks the cursor; looper on with 2 bars logs loop=2; Bounce wrote files/studio/sequences/pattern-<id>.m4a (60 KB, "Bounced" notice). Timing/choke audibility device-only.
- STU-6 PASS: Cues tab, burned song picked, cue set at 13.084 s, tapping it plays; media session position=13084 ms. Apple Music play-then-seek device-only.
- SURF-6 PASS: profile name, recently-added count (77) and Rip-from-cloud toggle all restored after force-stop + relaunch.
- MIX-11 PASS after a fix: Auto-DJ over burned songs shows the Mix as the media session (title/position); `cmd media_session dispatch pause/play/next` reach remotePause/remotePlay/skip (log `mix remotePause`, `mixadvance skip`), audio focus acquired/abandoned. BUG FIXED: a Browse/setlist play while the Mix owned the session was silently dropped (the Mix SimpleBasePlayer cannot take media items; the Mix kept playing and the new run never started). Added SessionSwitchboard.yieldMixToExo() called before every controller setMediaItems; verified the handoff (`switchboard yield mix->exo`, `owner=exo`, Mix paused, song plays); 2 regression tests. NOT run: the route-change `recover: sink restarted` step - the emulator console headphone-insert event produced no wired-device connection, so no route change reaches the app (covered by MixRecoveryTest; Bluetooth/phone-call/headset buttons device-only).
- GM-7 PASS (via new Settings > Debug "Pocket: build+start/status/end", launch with `-e pdj.pocketsStub true`, because the GAMES-8 screen does not exist): bridge enabled, 3-song round built and played through -> outcome `pocket`; a second round with song 2 skipped -> `broke`, SKIPPED state at index 2; scoreboard stats 2 rounds / 1 pocket / 50%. The UI-only parts (opt-in/unavailable screen, scoreboard card) wait for GAMES-8; cloud mode needs the services bridge.
- BRW-10 PASS (new Debug "Zone: rank now"): 110833 songs -> queue of 78, logged to PocketDJ.zone (familiar=0 / rediscovery=78 with this device's short history), 6.5 s.

No FATAL EXCEPTION / ANR from com.levi.pocketdj (two crashes in logcat are the uiautomator dump process itself).

Open: Q46-Q49.

## Wave 12

Merged (clean, no conflicts): SVC-7, COL-12, MIX-14, GM-9, STU-7, SURF-11. JVM: 3381 tests, 0 failures after merge (wave-11 3128 moved by the packages' new tests). assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave12:
- SVC-7 PASS: debug in-memory backend on; editing the profile name then Sync now shows "Pushed studio-cues, game-scores, ... profile"; an unchanged second pass says "Everything in sync"; another edit says "Pushed profile". Real backend not reachable (Q42).
- COL-12 PASS: Yours shows "Recently added / 77 songs - newest first" above Your playlists; detail lists newest first with Play/Shuffle/Duplicate/Convert; Settings > Collections count 50 -> row says "50 songs - newest first".
- STU-7 PASS: seeded sample "tone" added to a playlist and a new pocket -> runtime 8:37 to 8:40, pocket "1 song - 0:03", studio row with Studio/Sample badge and key 8A; Play on the pocket plays the local file (engine ready then ended after 3 s, no dead air, gap 0.46 s). Storage > Studio storage shows per-family bytes; Delete all samples -> 0 B, loops stay (500 kB), records gone from the playlist (14 songs). Studio rows are not tappable (Q50).
- MIX-14 PASS: Mix tab -> A crate SeedDup, B same -> Shuffle -> "Auto-mixing 1/6", download bar "6 of 155 downloaded" (no rip server on the emulator, so no progress), crate menu opens on both decks, skip (single tap) triggers one skip, double tap ignored while a fade is in flight (no double fire), loader sheet filters by title and loads a deck, Settings > Mix steppers/cue channel/beat pulse persisted across force-stop. Scroll-while-ticking not separately provable (menu is too short to scroll) (Q51). Skip fade length 1 vs 5 s only covered by SkipGesture JVM tests.
- GM-9 PASS (new Debug "MwF: live smoke", since there is no UI until GAMES-10): create on the live broker, refresh (1 member), suggest (1 suggestion), end, no errors.
- SURF-11 PASS: `adb am start -a VIEW -d pocketdj://jukebox/<id>` adds the session to the joined strip (name + id caption; it does not auto-push the panel, tapping the row opens it); request submitted shows Pending highlighted, host decision via broker flips it to Queued; host state with hear=true shows Tune In, which plays the stream seeked near the host position and re-tunes on a track change; host end shows "This jukebox has ended." and Leave removes the strip row. Host was the same emulator app plus curl as host.

No FATAL EXCEPTION / ANR from com.levi.pocketdj in logcat.

Open: Q50-Q53.

## Wave 13

Merged: MIX-12, SVC-9, COL-8, BRW-7, STU-11, STU-8. Conflicts: di/ServicesGraph.kt resetHooks (SVC-9 profileSecrets + BRW-7 timelineCues, kept both) and screens/producer/ProducerScreen.kt (STU-11 Tracks + STU-8 Instruments branches, kept both). JVM: 3681 tests, 0 failures (wave-12 3381 moved by the six packages' new tests). assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave13:
- BRW-7 PASS: History > Collection opens on Activity; Songs shows the date-added timeline with month header and "13 of 94509 songs heard"; Since Oct 1 narrows to 332 songs; Collections tab "Recently added - 50 songs, newest first" with Settings count 50.
- COL-8 PASS (offline half): 155 queued jobs persisted in pocketdj-playlist-writeback.json and survived force-stop; Settings > Apple Music shows "Waiting to send", "Send my adds" reports the queue; new Debug "Seed 60 AM batch" into the converted pocket shows the "Add to Apple Music? ... 60 songs" confirm dialog and Add 60 songs takes the queue 155 -> 215. Real delivery device-only.
- STU-11 PASS (new Debug "Seed sample (tone)" / "Seed bounce artifact"): New arrangement > Add a track > Add clip from sample SeedTone renders at 0:00 (x=484), Zoom in widens it, Zoom out floors at fit, ruler tap moves the cursor to 0:01, bounce row audition toggles Play -> Pause.
- STU-8 PASS: Packs lists the live S3 index, Download of the 32 MB bank -> Installed; Piano enabled; Record with count-in, 4 key taps -> "Saved Take 1" in Takes; Replay toggles to Stop. No crash. Audibility/latency device-only.
- MIX-12 PASS after wiring (package had no UI): Mix screen Record/Stop row; AutoDJ over burned songs recorded a take, filed in Mix sessions as "Play recording 0:26" and plays; force-stop mid-take and relaunch recovered the 0:10 orphan (recording-2.aac) into the session.
- SVC-9 NOT RUNNABLE: needs the profile-sync endpoint (Q42/Q54) and two instances; Settings shows "Device sync isn't configured for this build". Covered by 47 JVM tests (LinkCode, Enrollment, S3CloudDocDatabase, LinkDeviceProbe).

Integrator additions: MixRecordingUi.kt + MixScreen/MixSessionsScreen wiring (MIX-12); Debug seeds "Seed sample (tone)", "Seed bounce artifact", "Seed 60 AM batch".

No FATAL EXCEPTION / ANR from com.levi.pocketdj in logcat.

Open: Q54-Q58.

## Wave 14

Merged: SVC-10, BRW-11, GM-8, STU-14, SURF-7, STU-9 (no conflicts). JVM: 3993 tests, 0 failures (wave-13 3681 moved by the six packages' new tests). assembleDebug green.

Emulator (emulator-5554), screenshots in pocketdj-parity/_shots/wave14:
- GM-8 PASS: Games > In the Pocket (stub opt-in) shows round with dots/numbered songs and "In the pocket!"; typed feedback updates the 12/2000 counter, Save -> "Saved", feedback persisted across force-stop + relaunch. Mic icon showed (emulator has an on-device recognizer); real dictation device-only.
- STU-9 PASS: Record take on the piano, Save as take, Takes > Open score renders the staff, Edit > Select a note > Undo > Cancel, PDF/MIDI/Audio each open the share sheet with Take 3.pdf/.mid/.m4a.
- STU-14 PASS (after fixes): SeedTone sample -> chord timeline (Am) -> chord chip opens detail sheet; catalog song with local stems (Harbor Lights) -> 253 chords, Stems switch, 4-stem synced playback, mute/solo reflected in the rows.
- SURF-7 PASS (after fix): widget placed from the launcher picker; idle view; play/pause glyph flips with playback; after process kill a widget tap restarts the service and resumes. Medium/large sizes and the queued-heart path not driven (Q62).
- SVC-10 PARTIAL: Settings > Import server token saved -> pocketdj-settings-credentials.json updated with the token. Two-device pull/blank-pull steps not runnable (sync backend unavailable in this build, single emulator); covered by 22 JVM tests.
- BRW-11: n/a (data layer; REC-5 renders).

Integration fixes (not covered by package tests): (1) Demuxer stem rows never recomposed on mute/solo (StemRow skipped; version now passed as a parameter). (2) Demuxer track picker saw an empty catalog until Browse had been opened (now calls loadIfNeeded). (3) SURF-7: widget play with an idle player started PlaybackService via startForegroundService and never called startForeground -> OS ANR/kill after 10 s; PlaybackService now promotes with a placeholder on Media3's notification id and drops it if nothing plays.

No FATAL EXCEPTION in logcat after the fixes.

Open: Q50-Q53, Q59-Q63.

## Wave 15
Merged: SVC-13, GM-10, SURF-8, STU-12, BRW-12, MIX-15 (all clean merges, no conflicts). JVM suite 4167 tests, 0 failures (4011 baseline + 153 package tests + 3 integration tests); assembleDebug OK.

Emulator results:
- BRW-12 PASS (after fix): For You refresh crashed silently (ICU regex rejects the JVM-only `(?U)` flag in RecSoundAdmit.genreBucket, swallowed in appScope) so the tab never showed tiles. Fixed + regression test. Then: tiles New/In Da Zone/SeedDup/SeedRip, In Da Zone rows with Buried badges, Not for me removes the row (90 -> 89), Refresh updates the freshness bar, long-press tile -> Recommendations off -> notice + tile gone, Settings > For You lists SeedDup.
- MIX-15 PASS: Sessions list with Current badge, detail with 220-action replay (plays/advances), take playback + stop, rename, long-press delete -> new Session 2 current.
- STU-12 PASS (logcat/position, not audible): 2-lane arrangement plays, Mute/Solo -> MultitrackPlayer applyMix (anySolo flips), Master FX Drive enable, Loop on wraps position 2->1->0. Oboe latency / FX quality device-only.
- GM-10 PASS: New Session (QR + "Your turn!"), pocketdj://mwf/<id> from a curl-hosted session -> Join sheet with theme preview -> Join -> leaderboard has both; suggest from app, leader accept via broker -> accepted + score 1, +1 -> 2; Download to My Collections created pocket "MwF - Wave15 Host" (1 added, 1 not in library); wifi off -> "Can't reach the server - showing the last known state" + last updated; End -> "Session over", score recorded in Games (Best 2).
- SURF-8 PASS via real media3 MediaBrowser (DHU not possible: emulator Android Auto is a stub with no head-unit server; DHU installed but cannot connect). Found+fixed: onConnect granted DEFAULT_SESSION_COMMANDS so every browse call returned PERMISSION_DENIED (-4); now DEFAULT_SESSION_AND_LIBRARY_COMMANDS (+ guard test). Tree verified after cold start: Playlists (50) / Pockets, Play all / Shuffle all / songs, "Not available here" non-playable rows, art urls, "No songs" empty, search, selecting a song plays (state READY, isPlaying), Add-to chooser lists pockets then playlists. Debug action "Auto browse smoke" added to Debug screen.
- SVC-13 PARTIAL: Settings > Reset all app state with typed RESET -> app relaunches into onboarding (Link a device / Just this device). Delete account + other-device "profile not found" not runnable (no linked profile or sync backend, Q54/Q66).
Not reproduced once: after Download > Open, Games tab taps briefly ignored (seen once next to a wifi toggle; 2 clean repros fine).
No FATAL EXCEPTION after fixes. Open: Q64-Q68.

## Wave 16
Merged: BRW-13, MIX-16, STU-10, STU-13, COL-14, COL-16 (one trivial conflict in docs/ARCHITECTURE-ANDROID.md ledger, both sides kept). JVM suite 4466 tests, 0 failures (4167 baseline + package tests + 1 integration test); assembleDebug OK.

Emulator results (shots in pocketdj-parity/_shots/wave16/):
- BRW-13 PASS: Settings > Recommendations ON reveals lifetime toggle, Last sent, Send now, Delete cloud data; Send now -> Last sent "0 minutes ago" (live service); History > For You > Refresh -> In Da Zone subtitle "Top picks · recommendation engine". Suggested collections block on song detail NOT seen: the service returned no suggestions for the seeded songs (data-dependent; JVM-tested).
- MIX-16 PASS (after 2 fixes): Mix auto plays are in the History store tagged source=mix with the crate name and listened fractions (History tab shows "Mix · SeedRip"). Jukebox against a local dry-run jukebox-server.mjs: the broker state carries the on-air deck track + auto-queue tail; a guest request accepted with Play Next appears first in upNext. Bugs found+fixed: (a) cold start Mix Auto Play said "No songs ... on this device yet" because the catalog was never loaded (MixCratePort.ensureLoaded + regression test); (b) cold start jukebox requests all showed "No match found" (matcher ran on an empty catalog; now loads + waits up to 10 s); (c) accept buttons stayed disabled ("no audio yet") while an auto mix owns the audio, contradicting the repository's park-behind-a-burn design (UiState.mixOwns enables them).
- STU-10 PASS: Arp program 3 keys -> Play -> live staff filled (42 notes); Overdub started ("Recording a new staff") and ended without crash; MIDI section shows the empty state "No MIDI keyboards connected" + Bluetooth MIDI sheet button. Overdub on a saved take deferred (Q71). USB/BLE hardware: not verifiable.
- STU-13 PASS: Bounce all -> bounce-<ts>.m4a (0:03, 44.1 kHz) listed under Bounces; scissor Delete -> Undo -> Delete -> Save changes the clips (gap); Record master -> Stop -> live-recording-<ts>.m4a baked (24.9 s ~ wall clock, 44.1 kHz), partial WAV cleaned from cache. 48 kHz hardware pitch check: not verifiable on the emulator.
- COL-14 / COL-16: pure JVM packages, no emulator steps (IO-2 / LP-2/3 cover them).
Debug-only cleartext network config added so the emulator can reach a local broker (Q74).
No FATAL EXCEPTION / ANR in logcat. Open: Q69-Q74.
