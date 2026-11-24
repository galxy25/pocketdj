"""Top-level roadmap content for Android parity 2 (decisions, conflicts, not scheduled, wave names, release cuts)."""

WAVE_NAMES = {
    1: "P0 fixes + interop: AM cancelled start, stall episodes, snapshot passthrough, burned vinyl side file, credentials host guard, PlayEvent fields, attribution, AutoTransition, temp-hold ledger",
    2: "Sequencer seams I, Mix Mode sweep + lane + growing-file engine, loudness meter, DJ planner (pure), Mixing settings pane, Mix crate-stall fix",
    3: "Sequencer seams II, Mix Mode in the sequencer (swap-on-land), edits sync, analog start readers + end rule, wheel engine + palette, Remote pure core, NP thumbs",
    4: "Mix Mode UI + growing starts, album run engine, moment cache, run planner, Remote transport + resolver, voice play-by-name",
    5: "FX Lock, AM rows in Mix Mode, buffer storage UI, album run clocks + ▶, best match, lock-screen/Auto buttons, add-to by voice, Auto For You",
    6: "DJ shell + two-deck engine, pocket run store, Remote surface gate, album waveform editor, progressive analysis, AM library store, Mix Volume Glide",
    7: "DJ conductor (transitions), wheel UI, Auto pocket rows + 'play my pocket', Remote controller I, album page parity, AM library fold, store album page, edition rule A",
    8: "DJ planner + skip mix, History ▸ Pockets segment, Remote controller II + UI, motion engine, parity goldens, W7 Mix path",
    9: "DJ leveling, Remote hub + Nearby transport (Remote on), motion settings + adapt, upload Phase 6, Mix Together core, social gaps, widget thumbs",
    10: "DJ automation display, MixEngine sync seams, voice Mix Mode/stems, create pocket, Auto Up Next + Mix controls, edit sheets, inline player",
    11: "Mix Together live, broker transport (optional), AppFunctions, launcher extras, profile-sync scanner (dormant)",
    12: "Release: ledger, device checklist, Play listing + Data safety, release AAB",
}

RELEASE_CUTS = {
    5: "RC-1 (shippable): every P0 fix + NP Mix Mode phases 1-4 (incl. Storage buffer UI), FX Lock, vinyl album sides end to end (engine + clocks + album ▶ via the sequencer), NP/lock-screen/Auto thumbs + shuffle/repeat buttons, voice play-by-name + add-to-collection, Android Auto For You. DJ/wheel/Remote engines that landed stay invisible (ParityFlags).",
    9: "RC-2 (shippable): + DJ Mode (transitions, skip mix, PocketDJ selector, leveling), pocket wheel + adaptive runs + History ▸ Pockets + Auto pocket rows + 'play my pocket', motion opt-in, Remote (Listen Together / Backseat over Nearby), album waveform editor + page parity, AM library source, store album page.",
    11: "Full parity 2 (minus not_scheduled): + Mix Together, Auto Up Next + Mix controls, voice Mix Mode/stems, create pocket, AppFunctions, edit sheets, broker transport code (undeployed).",
}

DECISIONS = [
    {"id": "L1", "by": "Levi (standing)", "decision": "Android ships the latest main (no release branch); the Play app is FREE (no paywall/IAP); request every permission needed to be full-featured with prominent-disclosure flows; minSdk 35."},
    {"id": "L2", "by": "Levi 2026-11-23", "decision": "Bring Android to parity with iOS 'as the platform allows' and submit a new release; the 2026-11-02 'ship without the pocket wheel for now' deferral is over — the wheel is in scope."},
    {"id": "L3", "by": "Levi 2026-10-29 (W1-W7, QUESTIONS.md ANSWERED)", "decision": "W1 wheel in History ▸ Pockets with Wheel|List (Wheel default); W2 100 = songs PLAYED THROUGH, hard stop, no 'keep going'; W3 automatic synced 12-colour palette; W4 motion may upload (sensor modes only; Play Data safety Fitness info); W5 artist ban = run only + decaying penalty; W6 cycling folds into Trip, collection mode labelled 'Home'; W7 a Mix-cell best match loads Mix Auto-DJ when >= 10 deck-loadable songs."},
    {"id": "L4", "by": "Levi 2026-11-10", "decision": "Play on a pocket is a DERIVED run, never a replay ('Play the original songs' is secondary); >= 60 % of every run prefix unplayed in 30 days; long-press/right-click the centre ▶ for 'Clear this pocket'."},
    {"id": "L5", "by": "Levi 2026-11-03", "decision": "FX Lock capsule sits in the Effects header (upper right), no new row and no status line."},
    {"id": "L6", "by": "Levi Q116", "decision": "Mix decks stay mp3-only (Mix Together and DJ inherit this: non-mp3 rows are 'not a complete local file')."},
    {"id": "L7", "by": "Levi Q122", "decision": "Do not resign a paused owner: play after pause resumes whatever was last paused (DJ/Mix Mode owner hand-offs must respect it)."},
    {"id": "D1", "by": "architect", "decision": "Sequencer extension seams first (P2-PB-2/-3): hook bus, TransitionCause, start/advance interceptors, advance-without-load, session extras, replaceUpcoming, external-driver APIs. Later feature packages put their logic in NEW files and touch SetlistSequencer.kt only additively. Rationale: 10+ features need the sequencer; without seams every one would rewrite the same 1,641-line file serially."},
    {"id": "D2", "by": "architect", "decision": "DJ transitions use the NP DSP's existing private two-deck MixGraph ('ping-pong decks' + the graph's equal-power crossfader) instead of iOS's sample-accurate outgoing->tail move; same audible behaviour, less code, and it reuses the Mix tab's proven graph."},
    {"id": "D3", "by": "architect", "decision": "SharePlay -> Google Nearby Connections (P2P_STAR, offline, no server) as the Remote transport; an optional long-poll broker on the jukebox server keeps a future iOS<->Android route open. The Remote wire stays byte-identical to iOS."},
    {"id": "D4", "by": "architect", "decision": "Siri/App Intents -> one ShellActions door + deep links (always work) + launcher shortcuts + Assistant MEDIA_PLAY_FROM_SEARCH + App Actions capabilities (declared, best-effort) + AppFunctions on API 36+ (runtime-gated)."},
    {"id": "D5", "by": "architect", "decision": "CoreMotion retroactive query -> Activity Recognition Transition API recording a device-local 7-day timeline while opted in; the same pure MotionSettle runs over it."},
    {"id": "D6", "by": "architect", "decision": "Vinyl album run = one ExoPlayer item per side with sequencer-armed boundaries (ExoPlayer PlayerMessage) and metadata-only replaceMediaItem retitles; per-song ClippingConfiguration is kept only for lone songs."},
    {"id": "D7", "by": "architect", "decision": "Every synced/persisted document keeps iOS key names and shapes; Android decoders keep unknown keys (passthrough) wherever Android re-writes a document iOS also writes (playback-session, play-history, edits, pocket-palette, apple-music-library)."},
    {"id": "D8", "by": "architect", "decision": "Release safety: UI that lands before its engine is hidden behind A/ParityFlags.kt constants flipped by the engine package, so a release can be cut after any wave (release_cuts)."},
    {"id": "D9", "by": "architect", "decision": "Waves are computed by tools/build_roadmap.py (dependency order, priority, <= 8 per wave, owned files disjoint, hot files <= 2 touchers per wave); edit spec.py and rebuild rather than hand-moving packages."},
]

MICRO_DECISIONS = [
    {"id": "M1", "topic": "Apple Music rip-ahead owner gate (P2-MM-9)", "default": "Gate on 'a rip server is configured' (Android has no catalog-owner identity)."},
    {"id": "M2", "topic": "DJ ⏭ double-tap (P2-DJ-9)", "default": "Tap acts at once (Skip fade); a second tap during the mix upgrades to the 5 s sweep — no double-tap delay."},
    {"id": "M3", "topic": "DJ suspended chip wording while a Remote session is attached (P2-DJ-6)", "default": "'DJ — paused · Remote session' (iOS says 'SharePlay session')."},
    {"id": "M4", "topic": "Remote device name", "default": "Profile 'PocketDJ name' + Build.MODEL (\"Levi's Pixel 9\"); platform 'android'."},
    {"id": "M5", "topic": "Nearby payload size", "default": "maxStateBytes = 30,000 for Nearby (window halving handles it); broker keeps 60,000."},
    {"id": "M6", "topic": "Android Auto root tab limit (P2-SURF-7)", "default": "With ROOT_CHILDREN_LIMIT 4: Playlists (Continue folded in as its top row) · Pockets · For You · Mix."},
    {"id": "M7", "topic": "Motion confidence on Android", "default": "Activity transitions carry no confidence: treat every segment as 'medium' (passes MotionSettle's minConfidence)."},
    {"id": "M8", "topic": "AM library dateAdded", "default": "Use the Web API value when present, else first-indexed time; a pulled iOS doc's value wins."},
    {"id": "M9", "topic": "Album side seeking", "default": "Enable Mp3Extractor FLAG_ENABLE_INDEX_SEEKING for analog side keys only if a real side lacks a Xing/VBRI TOC (checked in P2-ALB-5)."},
    {"id": "M10", "topic": "Remote invite", "default": "QR + 6-character code encoding pocketdj://remote/join/<token>; discovered nearby hosts listed with a confirm prompt; Nearby auth digits shown."},
    {"id": "M11", "topic": "Studio pin reasons (P2-MM-3)", "default": "'demux', 'tracks-stems', 'sample', 'take' (iOS reason strings)."},
    {"id": "M12", "topic": "Golden fixtures that need Swift output (Remote wire, pocket-wheel parity)", "default": "Remote goldens hand-derived from RemoteWire.swift CodingKeys and marked; pocket-wheel parity generated by P2-POC-14 with xcodebuild via one-at-a-time.sh."},
]

CONFLICTS = [
    {"id": "C1", "title": "Profile sync: Q119 'not needed for the first Android release' vs parity",
     "facts": ["Android<->Android sync is built and dormant (no profileSyncBase in the live endpoints doc).", "iOS<->Android sync is impossible without iOS adopting the S3 backend (out of scope)."],
     "proposal": "Ship P2-SOC-2 (scanner, link deep link, delete-profile) dormant; publish the endpoints doc only on Levi's word.", "packages": ["P2-SOC-2"]},
    {"id": "C2", "title": "apple-music-library sync key: remote-social audit says 'iOS-only (MusicKit mirror)', vinyl audit ports it via the Web API",
     "facts": ["The Web API with the Music-User-Token returns the same library songs/albums/playlists.", "Sharing the doc keeps ids (amlib_/amlibpl_) identical across platforms."],
     "proposal": "Port it (P2-LIB-2/-3) with the iOS doc shape and register the sync key.", "packages": ["P2-LIB-2", "P2-LIB-3"]},
    {"id": "C3", "title": "QUESTIONS.md 'OPEN — Pocket wheel' still lists the pre-answer W defaults (W2 'started; keep going', W4 'on-device only', W7 'regular player')",
     "facts": ["The ANSWERED section and the iOS build use the answered values (played through + hard stop; motion may upload; W7 Mix Auto-DJ)."],
     "proposal": "Build to the answered values (decision L3); the integrator moves the stale OPEN block to ANSWERED in android/specs/parity/QUESTIONS.md.", "packages": ["P2-POC-8", "P2-POC-13", "P2-POC-15"]},
    {"id": "C4", "title": "Remote suspends DJ Mode, but iOS words it as SharePlay",
     "facts": ["Android's Remote is Nearby/broker, not SharePlay."], "proposal": "Same rule, Android wording (M3).", "packages": ["P2-DJ-6", "P2-REM-6"]},
    {"id": "C5", "title": "Q122 'do not resign a paused owner' vs DJ/Mix Mode owner hand-offs",
     "facts": ["DJ adoptDsp and Mix Mode swap-on-land move the session owner between ExoPlayer and the DSP session player while PLAYING."],
     "proposal": "Hand-offs only happen while playing; a paused owner is never resigned (tests in P2-MM-5 and P2-DJ-8).", "packages": ["P2-MM-5", "P2-DJ-8"]},
]

STALE_PREMISES = [
    {"where": "docs/ARCHITECTURE-ANDROID.md", "note": "MIX-18 (Stem Lock) still says 'Planned'; it merged and was emulator-verified. Fixed by P2-REL-1."},
    {"where": "A/widget/NowPlayingSnapshot.kt", "note": "'Android has no For You verdicts yet' — false since the answers program; P2-SURF-3 removes it."},
    {"where": "A/auto/AutoBrowseTree.kt doc comment", "note": "'minus For You' — P2-SURF-7 adds the tab."},
    {"where": "A/data/jukebox/JukeboxModels.kt:27", "note": "'Android P1 always creates timeless:false' — P2-SOC-1."},
    {"where": "A/screens/nowplaying/NowPlayingSeams.kt", "note": "rating seam exists but is never installed — P2-SURF-1."},
    {"where": "android/specs/parity/QUESTIONS.md OPEN — Pocket wheel", "note": "pre-answer W defaults; see C3."},
    {"where": "android/specs/answers/roadmap.json not_scheduled (W2/W4/W7)", "note": "'FR2 does not exist on either platform' — iOS shipped the wheel in 1.0.3-1.0.6."},
]

EXTERNAL_DEPS = [
    {"id": "X1", "note": "pocket-wheel-parity.json is generated by a Swift test on this Mac (P2-POC-14, xcodebuild through one-at-a-time.sh)."},
    {"id": "X2", "note": "Play Console: Data safety (Fitness info for ACTIVITY_RECOGNITION), permission declarations, App Actions shortcuts upload, release submission (P2-REL-1)."},
    {"id": "X3", "note": "jukebox-server /remote routes deploy (P2-REM-10) — only on Levi's word."},
    {"id": "X4", "note": "endpoints doc profileSyncBase publish (P2-SOC-2) — only on Levi's word."},
    {"id": "X5", "note": "Real-device verification: Nearby (2 phones), Android Auto (DHU/head unit), MusicKit subscription, ShazamKit AAR (Q84), motion transitions — DEVICE-CHECKLIST.md."},
]

NOT_SCHEDULED = [
    {"feature": "Join an iOS SharePlay session from Android", "reason": "platform-impossible",
     "why": "GroupActivities/GroupSession is an Apple-only framework; sessions are created and routed by FaceTime/Messages/Apple nearby-sharing through Apple servers with no public protocol or non-Apple client. Android gets the same capability over Nearby (P2-REM-9); a future iOS BrokerTransport over P2-REM-10's routes is the only cross-platform route."},
    {"feature": "Spotlight / launcher indexing of collections and iOS 27 indexed audio entities", "reason": "platform-impossible",
     "why": "No public Android API puts third-party content into system or launcher search (AppSearch PlatformStorage is visible only to allow-listed system packages). Dynamic + pinned shortcuts (present + P2-SURF-6) are what launcher search surfaces."},
    {"feature": "iOS<->Android profile sync", "reason": "out-of-scope",
     "why": "iOS syncs through CloudKit (private iCloud DB); Android cannot reach it with the user's iCloud identity. Needs iOS to adopt the S3 profile-sync backend — an iOS change, not Android parity."},
    {"feature": "Remote audio relay (host streams audio to peers)", "reason": "out-of-scope", "why": "Parked on iOS (docs/design/remote-audio-relay.md, 2026-11-08); not built there."},
    {"feature": "4-deck band-jam Mix Together", "reason": "out-of-scope", "why": "Not built on iOS; Levi scheduled it as a separate later release."},
    {"feature": "tvOS / visionOS shells, TV Remote view, Mac/iPad keyboard commands (⌘⌥M / ⌘⌥J)", "reason": "out-of-scope", "why": "No Android TV/XR target; keyboard commands were N/A under the parity-1 multi-window decision."},
    {"feature": "Mac rip server, Music.app capture, Apple Music (Local) private source", "reason": "out-of-scope", "why": "Deliberately iOS/Mac-only by design (Levi's own-rip-server model; Android users point at a rip server)."},
    {"feature": "Live Activity", "reason": "out-of-scope", "why": "iOS has none (no ActivityKit in apple/); Android's Media3 ongoing media notification already is the ongoing surface."},
    {"feature": "Stale MusicKit card / release on leaving Apple Music (fa8085da)", "reason": "out-of-scope", "why": "Already structurally present on Android (in-process SDK, one MediaSession owned by SessionSwitchboard); the residual cancellation bug is P2-PB-1."},
    {"feature": "Privacy manifest + App Store labels (8b8410f2), MUT .ignoreCache re-mint (67c26bd2), emulator AM tokens (338400ab)", "reason": "out-of-scope", "why": "Apple-side plumbing; the Android equivalents are Play Data safety (P2-REL-1) and the reconnect prompt (P2-LIB-4)."},
    {"feature": "Games, Producer/Performance UI, onboarding", "reason": "out-of-scope", "why": "No iOS changes since 2026-10-26 (Studio's only change, explicit-use pins, is P2-MM-3)."},
]
