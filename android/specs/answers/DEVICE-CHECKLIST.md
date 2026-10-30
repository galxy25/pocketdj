# Device checklist (phone session)

Everything the emulator cannot prove. One checkbox per item. Use the release-like debug APK unless noted; record result + build number next to each box. Items cite the question/ledger row they close.

## Audio engine / Mix
- [ ] **Q9 Mp3Decoder warm-up** (MIX-2). Burn 2 mp3 songs, load on a Mix deck, seek 20 times (drag the seek bar, tap cue). Expect no audible gap/click after each seek. Check logcat `PocketDJ.mix`; if clean at 12 frames try lowering the warm-up constant and re-test. Report seek latency feel.
- [ ] **Q6 Mix stretch quality** (MIX-2/MIX-5). Deck A: song at +5 %, +15 %, +25 %, then +30 % tempo; sync deck B to A. Judge artifacts (Sonic). Also pitch +/-3 semitones. Note the worst acceptable range. Q107: with Sync on, check by ear that beats stay locked (emulator residual was 4-13 ms).
- [ ] **ANS-MIX-4 Oboe sink**: logcat shows `sink backend=oboe` on the phone (not audiotrack). Play 10 min of Auto-DJ; no glitches/xruns. Unplug wired headphones and connect/disconnect Bluetooth mid-mix: audio re-primes on the new route within ~1 s.
- [ ] **Mix + routing** (PB-5/MIX-11): start a Mix, lock screen; lock-screen and Bluetooth/AVRCP play/pause/next work; widget shows Mix; Android Auto/DHU shows Mix row. Pause the Mix >15 s then press Bluetooth play (Q122: should resume the paused single, confirm that is what you want).
- [ ] **Phone call / focus** (STU-16, Q86): during Sample and Pattern playback take a call: they pause and resume after. Loop/Multitrack/Instrument/Demux STOP on transient focus loss (as built) - confirm wanted or ask for park+resume. Unplug headphones and reconnect BT during each Studio engine: re-primes, no silence.
- [ ] **Doze / OEM kills** (SHELL-1): leave a playing queue 30 min with screen off on battery; playback continues. Force-stop, then wait for the nightly workers (or `adb shell cmd jobscheduler run -f`): no crash, no audio start.
- [ ] **Mix Skip double-tap** (MIX-14): during Auto-mix, double-tap "Skip to next" with a finger: the crossfade takes ~5 s (fast sweep); a single tap uses Settings ▸ Mix ▸ Skip fade (15 s default). adb taps on the emulator are too slow to register as a double-tap.
- [ ] **Jank** (MIX-3): Developer options > GPU profile bars, scroll Browse (full library), Mix deck sliders, History: no sustained red bars.

## Studio / Producer
- [ ] **Q13 AAC priming** (STU-2): import an m4a, loop it on the Loops tab; listen for a ~46 ms gap/offset at the loop seam. Decide: trim by iTunSMPB/edit-list (recommended) or keep untrimmed.
- [ ] **Q41 Loops background audition** (STU-4): audition a loop, press Home. Default: it stops. Decide if a foreground service is wanted.
- [ ] **Latency feel** (STU-8): play on-screen keys with the SF2 bank on Oboe; judge tap-to-sound latency; time the first large-bank load.
- [ ] **Seam clicks / low-RAM** (STU-4/5): a 20 s+ and a 5 min clip in Sequencer and Multitrack on a low-RAM phone: no OOM, no glitches; bounce a multitrack project.
- [ ] **Real mic + MIDI** (STU-3/10): record a Sample via mic (built-in and Bluetooth input); USB and BLE MIDI keyboard note-on drives instruments; DRM-protected file import is refused with the message.
- [ ] **Real stems** (STU-7/15/14): Stemify a song, download stems, play synced stems in Demuxer (mute/solo), chord quality on a real song.

- [ ] **Cue seek on Apple Music** (STU-6): drop a cue on an AM-backed row in Producer ▸ Cues and tap it: playback starts then seeks to the cue (emulator verified the local-file path only).
- [ ] **In the Pocket cloud mode** (GM-7): with the listening-pockets service accepting the profile (green MAX_PROFILES cap is currently full), a round uses server pocket results and uploads the round.

## Apple Music / accounts (needs a subscribed account)
- [ ] **Full-track AM** (PB-2/3, Q36): sign into Apple Music, play an AM-only song full length; in a game round confirm 30 s previews are used (Q36 default: previews only).
- [ ] **AM sign-in + link** (SURF-3, COL-1): onboarding stage 2 completes with a real account.
- [ ] **AM library write** (BRW-1/16, GAP-3): Discover + Add an album: it appears in the Music library; remove it from library.
- [ ] **AM playlist sync / favorites** (COL-9/11, GAP-2): link a pocket to an AM playlist, add/remove tracks; Q114: remove a track from a Web-API-created playlist and see whether Apple accepts the DELETE.
- [ ] **Jukebox AM request** (GAP-1/SURF-10): host a jukebox, guest requests an AM song; AM catalog search stage returns results; Q113 rip-on-accept latency.

## Sync / storage / SD
- [ ] **Private rips bucket** (SVC-1): with the real (private) rips bucket, play a queue that includes a not-yet-ripped song; when its rip lands mid-queue it must play (the app now presigns the durable URL; emulator-verified only against a mock server).
- [ ] **Restore / relink** (SYNC-1, SVC-9): enable "Sync across devices" on phone A, Link a device on phone B (code entry + QR display), data appears; delete account on B, A shows the Q120 message. Needs the endpoints doc published (Q119).
- [ ] **SAF burn folder** (SVC-14, COL-4, STU-1/4, PB-7): pick a folder on a real SD card; burn a song: 4 stems + analysis json appear; revoke the grant in system settings: app degrades without crashing; sample/loop trees on SD play.
- [ ] **Release cert / App Links** (SURF-2/4): install the Play-signed build; `adb shell pm get-app-links com.levi.pocketdj` shows jukebox.pocket-dj.com verified; tapping a https jukebox link opens the app.

## Location / places & trips (ANS-LOC-1)
- [ ] Grant disclosure -> while-in-use -> background in sequence. Play music with places on, walk/drive 10+ min with screen off: a place/trip appears in History > Pockets. Q124: watch the notification at play start for flicker/duplicates (FGS type 2->10->2->10).
- [ ] Approximate-only grant: Settings asks for precise location; denying keeps the app working.
- [ ] Q123: Play Console Foreground Service "location" declaration filed before submission.

## Widgets / Auto / lock screen
- [ ] **Glance widget** (SURF-7): small/medium/large render, controls work; media-button cold start after force-stop; next after force-stop.
- [ ] **Android Auto** (SURF-8/9, PB-6): on a head unit or DHU: Continue/Playlists/Pockets/Mix browse; voice "play X on PocketDJ"; after reboot the System UI resume card resumes the held queue.
- [ ] **Assistant voice** (SURF-5): "Hey Google, play my warmup pocket on PocketDJ".

## Recognition / speech
- [ ] **Q84 Shazam**: needs `shazamkit-android.aar` + developer token supplied; then recognise a playing song through the ?♪? button (release hides it until then). Microphone permission flow.
- [ ] **Dictation** (GM-8): In the Pocket feedback speech recognizer with the Google app.
- [ ] **Games with AM** (GAME rounds / runs): full-track AM takeover inside a run (DRM) behaves per Q36.

## Network
- [ ] **Flaps** (MIX-1): Auto-DJ streaming over mobile data, toggle airplane mode for 10 s, then restore: recovers without dead air >N s; Q103 5xx gate behaviour on first stream.
