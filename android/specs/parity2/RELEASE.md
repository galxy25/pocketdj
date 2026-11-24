# Parity 2 release notes and Play declarations

Release path (P2Q8 default, awaiting Levi's word): build the AAB from main, upload to **Internal testing**, run
`DEVICE-CHECKLIST.md` on a phone, then **production at 20 % staged rollout**. Update the Data safety form in Play
Console in the same submission. Nothing here is uploaded automatically.

## 0. Pre-submission blockers (hard)

1. `docs/legal/PRIVACY.md` must be updated with the section 4 motion text (and the lawyer re-check) BEFORE the Data safety form is submitted; it still says Android does not read physical activity.
2. Confirm server-side deletion of uploaded listening-pockets data (and the motion label with it) before declaring a deletion path in Data safety.
3. `android/scripts/release-aab.sh` (signed AAB, R8 mapping gate, 16 KB alignment) and the emulator release smoke (no FATAL in logcat) must be run from main and recorded in the status file; not done by P2-REL-1.
4. Reconcile the What's new copy with P2Q22 and P2Q36 (section 6) at submission time.

## 1. What's new (Play listing, <= 500 characters)

```
Mix Mode keeps the next songs ready so playback never stalls. DJ Mode blends tracks with beat-matched crossfades, and a double-tap on skip sweeps to the next song. The Pocket wheel learns your listening by time of day and plays a 100-song run that adapts as you skip. Listen Together and Backseat sync playback across phones with no internet. Vinyl album sides, new Android Auto Up Next and For You, voice commands and Gemini actions.
```

Feature-state check for this copy (code at this commit): DJ Mode ships ON (`ParityFlags.DJ_MODE` getter is `true`, P2Q22 default on); if P2Q22 flips to hold, delete the "DJ Mode blends ..." sentence. The copy deliberately says nothing about internet Remote or link-a-device (P2Q36 broker undeployed, link-a-device dormant); do not add them. Listen Together / Backseat are described as "no internet" (device to device), which holds without the broker.

Current text is 434 characters (Play Console enforces the 500 limit on paste).

## 2. Data safety deltas (vs the live form)

| Item | Declaration |
|---|---|
| **Health and fitness > Fitness info (physical activity)** | NEW. Collected: yes (only if the user turns on Settings > Pocket Wheel > motion). Shared: no. Purposes: App functionality, Personalization. Optional: yes (user can turn off). Processed ephemerally: no; only the "walking" / "running" label is attached to plays and uploaded with listening pockets. Raw Activity Recognition transitions stay on the device in a 7-day timeline. Not used for ads. Encrypted in transit: yes. Deletion: on device, Settings > History > Delete history (and Delete account) erase the motion timeline, opt-in and run state (verified: `wheelClearLocal` is wired to both). The uploaded listening-pockets copy is NOT in the account-deletion cloud key list (`AccountDeletionService.cloudDocKeys`); its server-side deletion path is unverified, so answer the Console deletion question only after confirming it with the backend (pre-submission blocker). |
| **Nearby devices / Bluetooth (Remote over Nearby Connections)** | No new data type. Nearby and Bluetooth are used for app functionality (Listen Together, Backseat, MIDI) only. No data is collected: session traffic is device to device, and nothing is sent to our servers. `neverForLocation` is set on `BLUETOOTH_SCAN` and `NEARBY_WIFI_DEVICES`. |
| Camera | Unchanged data-wise: QR scanning for link-a-device and Remote invites; no image is stored or sent. |
| Location, Microphone, App activity, Device IDs | Unchanged. |

The Play "Health apps" declaration is not required: motion is used only to tune music, not for health or medical
purposes (state this in the Health apps form if Console asks).

## 3. Permission declarations (manifest as of this release)

| Permission | Why | When requested |
|---|---|---|
| `ACTIVITY_RECOGNITION` | Pocket wheel motion (walking/running) | Only after the in-app prominent disclosure in Settings > Pocket Wheel; off by default |
| `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `NEARBY_WIFI_DEVICES` (neverForLocation), `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE` | Remote over Nearby Connections; MIDI controllers | Start or join a Remote session, behind a rationale sheet |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | A Remote controller with no local playback survives in the background | While a Remote session runs |
| `CAMERA` (hardware optional) | QR scan: link a device, Remote invite | On demand |
| `RECORD_AUDIO` | Studio recording, dictation | On demand |
| `ACCESS_*_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE_LOCATION` | Places and trips (unchanged) | Opt-in, prominent disclosure |
| `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE(_MEDIA_PLAYBACK / _DATA_SYNC)`, `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED`, `INTERNET`, `ACCESS_NETWORK_STATE` | Playback, downloads (unchanged) | Unchanged |

Foreground-service declaration (Play Console > App content): add `connectedDevice` (Remote keep-alive, user-started)
alongside the existing `mediaPlayback`, `dataSync`, `location`. The release gate script's `permissions.txt` output
lists the final merged set; compare it to this table before uploading.

**App Actions:** `shortcuts.xml` capabilities need a Play Console upload (Release > App Actions, test with the
App Actions test tool after upload). Deep links and launcher shortcuts work regardless (P2Q7).

## 4. Privacy policy line for motion

`docs/legal/PRIVACY.md` is a legal document (not edited by this package). Section 4.6 currently says "iPhone only"
and ends "The Android app does not read physical activity" (also the permissions list in the Android section and the
Data table at line 66). Before this ships, replace with:

> **Walking and running, if you turn it on.** Settings > Pocket Wheel > Notice walking & running is off by default.
> With your permission (Android: Physical activity; iPhone: Motion & Fitness), PocketDJ reads your device's activity
> recognition on the device to tell whether you were walking or running while a song played. Raw readings stay on the
> device and are kept for 7 days; only the label ("walking", "running", or "on a trip") travels with the play in your
> listening-pockets upload, and only while both this setting and listening pockets are on. Turning the setting off
> stops it and erases the stored timeline.

Also add to the Android permissions sentence: "physical activity (only for the walking-and-running setting) and
nearby devices (Bluetooth and Wi-Fi, only for Listen Together / Backseat and MIDI controllers)". The lawyer who
signed off the policy should see this delta.

## 5. Building the release AAB

```
android/scripts/release-aab.sh          # from main; versionCode = unix timestamp, versionName 1.0.0 unless overridden
```
Preflight needs the signing keys in `~/.config/pocketdj/android-signing`. It builds the upload-key AAB, the
app-signing-key APK, runs the R8 mapping gate, pins both certificate fingerprints, and checks 16 KB alignment and
no x86. Use `ship-play.sh` when the sideload APK should publish at the same time. Bump `VERSION_NAME` (e.g.
`VERSION_NAME=1.1.0`) if Play listing wants a new visible version. Always wrap in `scripts/dev/one-at-a-time.sh`
on the dev Mac.

## 6. Open decisions that affect this release

See `QUESTIONS.md`. Release-relevant: P2Q22 (DJ Mode on in release, `ParityFlags.DJ_MODE`), P2Q5/P2Q36 (broker
`/remote` routes undeployed: internet Remote will not connect until deployed), P2Q6/P2Q39 (profile-sync endpoints
unpublished, link-a-device dormant), P2Q24 (motion Settings row: resolved by P2-POC-12), P2Q1 (rip-ahead needs a
configured rip server).
