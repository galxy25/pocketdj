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

## ANSWERED

(none yet)
