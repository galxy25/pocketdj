# Android parity — questions for Levi

Running list of decisions that need Levi's input. Work does NOT block on these:
each item records the default being used meanwhile. When Levi asks "what needs my
input?", answer from the OPEN section; move answered items to ANSWERED with the
answer + date, and apply the answer.

Format: `Q<n> [wave/package] question — default meanwhile — why it matters`

## OPEN

- **Q1 [distribution]** How do you want to install Android builds: Play Console internal testing track (TestFlight-like, needs a Play developer account + signing key upload) or direct APK sideload via adb to your phone? — *Default: debug APK, emulator only.* — Needed before the first wave worth installing on a real phone.
- **Q2 [COL-1]** `amPlaylistId` is persisted on Playlists but NOT on Pockets (matches iOS exactly). Keep as-is, or persist it on both platforms? — *Default: match iOS.*
- **Q3 [SURF-4 / GM-10, App Links]** OK to publish `/.well-known/assetlinks.json` (Android signing-cert fingerprint) on jukebox.pocket-dj.com so `https://jukebox.pocket-dj.com/join|mwf` links open the app? Depends on Q1's signing key. — *Default: `pocketdj://` links only.*
- **Q4 [GM-10, Music with Friends push]** The jukebox broker only speaks APNs. Add Firebase/FCM to the app + a broker change for push, or ship Android with 4 s polling (what iOS falls back to)? — *Default: polling, no Firebase.*
- **Q5 [SVC-7..9, profile sync, D7]** Android has no CloudKit, so profile sync = new `pocketdj-profile-sync` Lambda + S3 on the green account, link-a-device by code (QR scanning deferred). OK to deploy that AWS infra when waves 12–13 land? — *Default: build + test against an in-memory store; deploy only with your OK.*
- **Q6 [D1, Mix engine]** Mix tempo/pitch uses Media3 Sonic (pure Kotlin/Java); quality degrades beyond ±25 % stretch. Acceptable, or should the Mix move to the Oboe/C++ path (Signalsmith) later? — *Default: Sonic for Mix, Oboe+C++ for Studio.*
- **Q7 [UX, shell]** Android shows 7 bottom tabs (Browse, History, Jukebox, Collections, Mix, Producer, Games) with the label only on the selected tab. OK, or would you rather fold some (e.g. Jukebox/Games) into a "More" tab? — *Default: 7 tabs, selected-label-only.*
- **Q8 [STU-1]** Studio loops are `.wav` on Android (iOS uses `.caf`) because the document is device-local. Keep, or write CAF later so a studio doc can be shared with iOS? — *Default: .wav.* — Affects any future cross-platform Studio sharing.
- **Q9 [MIX-2]** Mp3Decoder warm-up is 12 frames after seek (emulator's software decoder emits ~8 frames of silence after flush). Real-device codecs may differ; OK to confirm on a phone once Q1 is settled? — *Default: 12 frames (about 300 ms of decode per seek).* — Seek latency vs. gap-free seeks.
- **Q10 [BRW-5]** Sync OpenSearch credentials across devices (iOS uses SettingsCredentialsSync) or keep Keystore-local on Android? -- *Default: Keystore-local, not synced.* -- Belongs with profile-sync (SVC-7..9).
- **Q11 [PB-1]** Add a Settings control for cloud/device playback mode now, or wait for the burn store UI? Should an Apple-Music-only row inside a run take over from the sequencer once AM end detection exists? -- *Default: cloud mode, no control; AM-only rows skipped in runs.*
- **Q12 [SURF-4]** Jukebox/play/collection-file deep links are route-only until JBX-2 (join panel), SURF-5 (play) and the import package assign their seams. -- *Default: link opens Jukebox tab / item screen; import shows "coming soon".* -- No decision needed, tracking only.
- **Q13 [STU-2]** Decoded m4a keeps AAC priming (about 2050 frames, 46 ms) and ~20 ms padding on the emulator codec; the acceptance wants the priming head trimmed (iOS primingHeadFrames). Trim by the m4a edit-list/iTunSMPB value (exact, container-aware) or a measured constant? -- *Default: untrimmed; instrumented smoke tolerances relaxed (100 ms duration, onset <= 2200 frames) with a KNOWN GAP comment.* -- Loop seams and beat-grid alignment for imported m4a.
- **Q14 [SVC-3]** Request POST_NOTIFICATIONS at runtime (Android 13+) so the "Downloading... n of m" foreground notification is visible, and wire the Burn Stop button to BurnStore.cancelTransfers (UI files owned by a later package)? -- *Default: no prompt, download still runs; Stop not wired.*
- **Q15 [PB-2]** ResumptionSnapshot / onPlaybackResumption (resume last queue from notification/Bluetooth after process death) waits on PB-4's HeldQueue. OK to leave PARTIAL until PB-4? -- *Default: PARTIAL; latch + onHeldRestored hook in place.*
- **Q16 [BRW-4]** Multi-select Share (ShareText.forSongs) has no consumer; add to History/Browse multi-select bars in a later UI package. -- *Default: song/album Share only.*
- **Q17 [PB-3]** Rip-on-demand wait is capped at 10 minutes before the row fails (no iOS equivalent). Keep, shorten, or uncap? Also: the Settings Debug "Playback dead air" readout is not built (DeadAirMeter.summaryLine() is the data). -- *Default: 10 min cap; readout deferred.*
- **Q18 [MIX-5]** Nothing calls MixEngine.restorePersistedMixIfIdle()/materializePendingRestoreIfNeeded() yet; the launch task or the Mix screen (MIX-14) must. -- *Default: only the Debug "Mix: restore" button calls them.* -- Without a caller the Mix does not come back after process death.
- **Q19 [COL-3]** The on-device LLM tie-break of iOS's duplicate judge has no Android equivalent: borderline pairs count as NOT duplicates. Acceptable, or add a server-side tie-break? -- *Default: exact + same-release tiers only.*
- **Q20 [SURF-10]** The Jukebox "Require access tokens by default" setting is not access-controlled today (server mints no guest token), and `JukeboxRepository.adopt(id)` has no UI caller (no sessions picker). Build a sessions picker? -- *Default: setting is an intent flag only; no picker.*
- **Q21 [PB-3]** Duplicate `POST /rip` for one row: the log shows two `rip-post begin` lines ~20 ms apart for the same song (one from the run, one more resolver call). Harmless against a server that dedupes, but worth a look when the playback lane is next touched. -- *Default: left as is.*
- **Q22 [STU-3]** Finished mic takes are mono PCM16 WAV written under an `.m4a` file name (crash-safe orphan recovery). Transcode to AAC after stop? — *Default: stay WAV.*
- **Q23 [STU-3]** Mic/import/carve samples go only to the app-managed samples root, not a SAF user folder. Copy out to the SAF folder? — *Default: app root only.*
- **Q24 [PB-5]** Cumulative per-song skip count has no Kotlin sink (no PlayCountService equivalent). Build a PlayStatsStore sink with SVC-6? — *Default: skip verdicts live on PlayEvent only.*
- **Q25 [SVC-15]** Apple Music catalog search needs a developer token minted by the rip server; emulator cannot reach it. Library/favorites writes need a real Music-User-Token. Confirm on a phone once Q1 is settled. — *Default: unit-tested only; debug probe in Settings > Debug.*
- **Q26 [SURF-5 / MIX-7]** Mini player shows the track title after a collection search/shortcut play (iOS-style), not the collection name the roadmap step says. Show the collection name? Also MixFacade and the MIX-7 Auto-DJ hooks await MIX-9/MIX-14. — *Default: track title.*
- **Q27 [PB-2 / COL-10]** The notification/lock-screen heart was never bound (FavoriteCommand.seam stayed null); it is now wired to the favorites store (toggles the local favorite, queues the Apple Music mirror only if that opt-in is on). Keep the heart on the Android notification by default? -- *Default: shown whenever the standalone player owns audio.*
- **Q28 [SVC-3]** A burn whose background download later fails (HTTP 400/403) is counted as `burned` in the immediate BurnResult (queued), then flips to an error row; the stem/beat-grid post-pass also still runs for those songs. iOS behaves the same way; tighten on Android (skip the post-pass for songs that failed)? -- *Default: match iOS.*
- **Q29 [PB-4]** Restore assumes an edition row's storage id is `<songId>_<variant>`, and the stem lock is not carried (Android sequencer has no stem lock yet). OK until the stem-lock package? -- *Default: guess kept; stemLock round-trips as null.*
- **Q30 [PB-4]** A held (restored) deck had no entry point: the mini player only showed for a live player. Added a "Paused" strip with a play button for the held deck (integration fix). Keep this, or hide the strip until the first play like iOS's no-card rule? -- *Default: strip shown.*
- **Q31 [GM-5]** No golden cross-platform test for the In the Pocket scorer (needs reference output from the iOS Swift scorer). Capture one on a Mac? -- *Default: lambda-fixture tests only.*
- **Q32 [BRW-2]** Hide-skips toggle is wired only for the filter state; History applies it later. changeOp clears the value (iOS keeps it). -- *Default: as built.*
- **Q33 [GM-1]** Games tab: Gem Collector / In the Pocket cards are inert and Music with Friends New/Join absent until GM-3/4, GM-7/8, GM-10; no sync engine calls GameScoreboardStore.reloadFromDisk. -- *Default: tracking only.*
- **Q34 [MIX-8]** Loop, stem decks and beat-pulse have no UI until MIX-13/14 and the emulator has no stemmed burn / stem server, so only a smoke run was possible. -- *Default: JVM-verified; verify on device once the Mix UI lands.*

## ANSWERED

(none yet)
