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

## ANSWERED

(none yet)
