# Parity 2 device checklist

Run on Levi's phone with the release build (Play Internal testing) before production rollout. One row per package `device_only` item in `roadmap.json`, plus device-only follow-ups from `QUESTIONS.md`. Result: P = pass, F = fail (note the symptom), N/A = hardware unavailable.

| # | Package | Check | Result | Notes |
|---|---|---|---|---|
| 1 | P2-PB-1 | Real MusicKit: burned row -> stalled AM-only row -> hop to a burned row; the AM song must never start over the hop target. | | |
| 2 | P2-MM-2 | SAF picked folder on a real SD/USB folder. | | |
| 3 | P2-MM-4 | Cellular vs Wi-Fi policy on a phone with a SIM. | | |
| 4 | P2-ALB-2 | Two devices with profile sync (only if P2-SOC-3 goes live). | | |
| 5 | P2-MM-5 | Audible gap check on headphones during swap-on-land. | | |
| 6 | P2-ALB-4 | Verify Media3 metadata-only replaceMediaItem never re-prepares on a real phone; VBR side seek accuracy. | | |
| 7 | P2-MM-8 | Bluetooth disconnect pauses the DSP. | | |
| 8 | P2-SURF-4 | 'Hey Google, play … on PocketDJ' on a phone. | | |
| 9 | P2-MM-9 | Real AM subscription: touch the tempo slider on an AM row -> hand-off to the rip without a gap. | | |
| 10 | P2-SURF-2 | Android Auto Now Playing shows the buttons on a DHU. | | |
| 11 | P2-SURF-5 | App Actions test tool / Assistant phrase after Play Console upload. | | |
| 12 | P2-SURF-7 | DHU. | | |
| 13 | P2-DJ-3 | Battery/thermal behaviour over a 1 h DJ session. | | |
| 14 | P2-LIB-2 | Real subscribed account: library counts match the Music app. | | |
| 15 | P2-POC-8 | A real 100-song run stops at the 100th play-through. | | |
| 16 | P2-REM-3 | Bluetooth headset + Android Auto ⏯ forwarded on a controller. | | |
| 17 | P2-DJ-8 | Listen: equal-power fade with no level dip on headphones. | | |
| 18 | P2-LIB-4 | Real ShazamKit + subscription. | | |
| 19 | P2-POC-16 | DHU / real head unit; 'Hey Google, play my pocket on PocketDJ'. | | |
| 20 | P2-DJ-9 | Bluetooth headset ⏭ and Android Auto ⏭ on a DHU. | | |
| 21 | P2-POC-11 | Real walk/run produces transitions; re-registration after reboot. | | |
| 22 | P2-DJ-11 | Perceived loudness consistency across a 10-song set. | | |
| 23 | P2-REM-9 | Two phones: Listen Together in sync; Backseat with one phone on the car stereo; host leave -> hand-over. | | |
| 24 | P2-SURF-11 | Gemini Nano path on a Pixel 9+. | | |
| 25 | P2-SURF-8 | DHU. | | |
| 26 | P2-SURF-9 | DHU artwork size for the QR. | | |
| 27 | P2-REM-13 | Two phones: 40 ms sync target measured by ear/recording. | | |
| 28 | P2-SOC-2 | Two-device link and pull. | | |
| 29 | P2-SURF-12 | Gemini on an Android 16 phone. | | |
| 30 | P2-MM-8 / Q13 | Mid-song growing-stream stall fallback: toggle airplane mode mid-song on a long digital rip; expect plain-stream fallback at the playhead after ~5 s. | | |
| 31 | P2-ALB-5 / Q14 | Seeks inside an analog album side land accurately (no drift); if drift, enable mp3 index seeking. | | |
| 32 | P2-SURF-9 / Q33 | Jukebox QR artwork size/legibility on a DHU or device. | | |
| 33 | P2-REM-13 / Q40 | Mix Together 40 ms sync target with two phones, same Wi-Fi, by ear/recording. | | |
| 34 | P2-SURF-2 / Q15 | Media card on Android 16 / lock screen / Android Auto show heart, shuffle, repeat, thumbs; reorder if thumbs are hidden. | | |
| 35 | P2-POC-12 | Motion opt-in: Settings > Pocket Wheel shows the prominent disclosure before the ACTIVITY_RECOGNITION prompt; declining leaves motion off. | | |
| 36 | P2-DJ-8 / Q22 | DJ Mode is ON in the release build (ParityFlags.DJ_MODE true): equal-power fade, no level dip on headphones; flip the flag off to hold. | | |

## Always (every release)

| Check | Result | Notes |
|---|---|---|
| Cold launch, play a song, background and return: no crash | | |
| Play seed setlist, Mix Mode on, DJ on, wheel tab, Remote showcase: no FATAL in logcat | | |
| Permission prompts appear only after their disclosure screens (location, motion, Nearby, camera, mic, notifications) | | |
| Upgrade install over the previous production build keeps data and sign-in | | |
