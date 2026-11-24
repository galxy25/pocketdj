# Android parity 2 — questions for Levi

Work never blocks on these: each item records the default the program uses meanwhile.
Format: `Q<n> [package] question — default meanwhile`. Integrators append new items to OPEN; move answered items to ANSWERED with the answer + date.

## OPEN

- **P2Q1 [P2-MM-9]** iOS rips upcoming Apple-Music-only rows only for the catalog OWNER. Android has no owner identity. Gate rip-ahead on 'a rip server is configured' (your 2026-11-02 rule: each user runs their own rip server)? — *Default: Yes — rip-ahead only when Settings ▸ Import server has a URL+token; otherwise those rows show 'Apple Music only'.*
- **P2Q2 [P2-DJ-9]** iOS uses tap = 15 s Skip fade and double-tap = 5 s sweep. On Android a double-tap detector would delay every single tap by ~300 ms. OK to act on the first tap immediately and upgrade to the fast sweep if a second tap lands during the mix? — *Default: Yes — tap acts at once; a second tap upgrades to the 5 s sweep.*
- **P2Q3 [P2-LIB-2]** Index your own Apple Music library as a Browse/Collections source on Android (iOS public mode does this), via the Apple Music Web API once a day after sign-in? — *Default: Yes, on by default after Apple Music sign-in; a Settings ▸ Apple Music toggle turns it off.*
- **P2Q4 [P2-REM-9]** Remote on Android uses Google Nearby Connections (Bluetooth + Wi-Fi, no server, works offline in a car). It needs Bluetooth/Nearby-devices permissions. OK? — *Default: Yes — Nearby is the primary transport; permissions are requested only when you start or join a Remote session.*
- **P2Q5 [P2-REM-10]** Deploy the jukebox-server /remote broker routes to jukebox.pocket-dj.com so Remote works over the internet (and, later, iOS↔Android)? — *Default: Build + test locally only; do not deploy until you say so.*
- **P2Q6 [P2-SOC-2]** Publish the endpoints doc with profileSyncBase so Android↔Android profile sync goes live? (Q119 said not for 1.0.) — *Default: Ship the scanner/link code dormant; do NOT publish the endpoints doc.*
- **P2Q7 [P2-SURF-5]** Google is winding App Actions down in favour of Gemini/AppFunctions. Still declare App Actions capabilities (harmless if ignored) next to the deep links? — *Default: Yes — declare them; deep links + launcher shortcuts are the doors that always work.*
- **P2Q8 [P2-REL-1]** Release path for the parity-2 build: Play internal testing first, then production staged rollout? — *Default: Upload to internal testing, run the device checklist, then production at 20 % staged rollout; the Data safety form is updated in Play Console in the same submission.*
- **P2Q9 [P2-DJ-5]** Suspended-remote DJ chip wording: iOS verbatim "DJ — paused · SharePlay session" vs design doc "Remote session" for Android. — *Default: iOS verbatim (pinned by DjModeTest); one-line change.*
- **P2Q10 [P2-MM-5]** Integrator added a hand-off attempt at first audio (a row preloaded as a stream whose file landed while it was still "next" otherwise kept streaming). Does iOS do the same, or should the preload swap to the local file instead? — *Default: attempt at first audio (observed on emulator: `hand-off ... reason=first-audio`).*
- **P2Q11 [P2-MM-6]** Mix Mode chip uses iOS verbatim words ("Buffering 42%", "Ready") instead of the roadmap's "Buffering 1 of 3". Keep iOS wording? — *Default: iOS verbatim.*
- **P2Q12 [P2-ALB-4]** Skip-back onto a song BEFORE the loaded album-side item's clip start (album started mid-side) reloads instead of seeking in place (the run item starts at the song, per the acceptance). Acceptable, or load every side from 0 so back always seeks in place? — *Default: reload in that one case.*
- **P2Q13 [P2-MM-8]** Mid-song growing-stream stall: Android falls back to the plain stream at the playhead after a 5 s hold (22 s at start). Emulator network shaping cannot deliver slow bytes (it blocks the connection), so this was verified by unit tests plus the start-hold fallback only. OK to treat the mid-song path as device-verified later? — *Default: yes; add to the device checklist (airplane-mode toggle mid-song on a long digital rip).*
- **P2Q14 [P2-ALB-5]** Mp3 index seeking (ConstantBitrate/index seeker) for analog album sides is NOT enabled: no real side header to inspect, and the flag forces a full-file scan on progressive http. If device seeks inside a side land inaccurately, turn it on (flag documented in the status file). OK to leave off until a device shows drift? - *Default: off; add a device-pass check of seeks inside a side.*
- **P2Q15 [P2-SURF-2]** The system media card on Android 16 shows only the first two custom buttons (heart, shuffle) in its compact view; repeat and thumbs are listed in the session (dumpsys) but live in overflow/other surfaces (Android Auto, lock screen). Acceptable, or reorder so thumbs outrank shuffle when a rec target exists? - *Default: keep order heart, shuffle, repeat, thumbs; verify on a device and Android Auto DHU.*

- **P2Q16 [P2-ALB-6]** Tapping the album waveform when the side is not loaded starts the album at that track, so earlier tracks are not in the queue (iOS keeps the whole album queued). Queue the whole album and cue the tapped track instead? — *Default: current behaviour (queue from the tapped track).*
- **P2Q17 [P2-DJ-6]** DJ Mode chip stays hidden behind ParityFlags.DJ_MODE until P2-DJ-8. The integrator added a debug-only toggle (Debug ▸ "Parity: show DJ Mode chip") so the shell can be driven before then. Fine to keep? — *Default: keep; it only exists in debug and is moot once DJ_MODE flips on.*

- **P2Q18 [P2-LIB-3]** Fold a library song onto its "Apple Music (Local)" twin by appleMusicId only for the catalog OWNER (iOS gate). Android has no owner probe, so `amLibrarySupersedesOntoLocal` is OFF: library songs stay listed beside their local twins (verified: 121 rows). A real "this catalog is my own" signal is needed to turn it on (debug `-e pdj.amFold 1` verifies the fold: 120 rows). What is the owner signal on Android? - *Default: fold OFF, duplicates shown.*
- **P2Q19 [P2-LIB-3]** Signing out of Apple Music (and "erase everything") clears the local library index; it is re-indexed on the next sign-in. Acceptable? - *Default: yes, clear.*
- **P2Q20 [P2-LIB-4]** Discover album rows now open the store album page instead of expanding in place. Keep an in-place expand next to it? - *Default: page only.*
- **P2Q21 [P2-MM-10]** Add the un-muted "Clean/Explicit edition" chip note and a lazy rip of the wanted edition? - *Default: no, rule A only.*
- **P2Q22 [P2-DJ-8]** The integrator flipped `ParityFlags.DJ_MODE` to true (DJ chip visible in release) after the emulator run. Ship DJ Mode in the next release or hold it behind the flag until a device listen test (equal-power fade, no level dip)? - *Default: on; flip the getter back to false to hold.*
- **P2Q23 [P2-DJ-8]** Starting DJ Mode runs disk reads on the main thread (StrictMode DiskReadViolation, about 130 ms: BurnStore.localUrlPreferringCut via DjModeWiring.currentMixable and NowPlayingDspHost.resolveLocal). Move to an IO dispatcher in a follow-up? - *Default: follow-up, not blocking.*

## ANSWERED

(none yet)
