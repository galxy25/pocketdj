---
name: android-emu
description: Boot and drive the Android emulator for PocketDJ. Use when asked to "run the android app", "boot the emulator", "screenshot the android app", "verify on the android emulator", or to functionally drive/verify an Android build. Covers the pocketdj AVD, headless boot, install/launch, screenshots, taps, and teardown.
---

# Android emulator (AVD `pocketdj`)

One AVD is provisioned: **`pocketdj`** — Pixel-7 profile, **Android 16 / API 36**
(`system-images;android-36;google_apis;arm64-v8a`), 1080×2400.

Environment (every shell):

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

## Boot

```bash
emulator -list-avds                                   # → pocketdj
# headless (agent verification):
emulator -avd pocketdj -no-window -no-audio -no-boot-anim -no-snapshot &
# WITH a window (Levi checkpoints — he verifies on the visible emulator):
emulator -avd pocketdj &

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 3; done
```

Boot takes a few minutes cold. Run long boots via run_in_background, never a
foreground sleep-loop past the timeout.

## Install · launch · drive · screenshot

```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.levi.pocketdj/.MainActivity
adb exec-out screencap -p > /tmp/pdj-android.png      # then Read the png to verify visually
adb shell wm size                                     # 1080x2400 — compute tap targets from this
adb shell input tap 679 1834                          # e.g. Mix tab in the bottom bar
adb shell input text "hello" ; adb shell input keyevent 66   # type + Enter
adb logcat -d -s AndroidRuntime:E                     # crash check after driving
```

Bottom-bar tab x-centers at 1080 wide (6 tabs, y≈1834): Browse 90 · History 270
· Jukebox 450 · Playlists 630 · Mix 810 · Producer 990 — ± a few px; screenshot
first and confirm before relying on taps.

## Teardown / hygiene

```bash
adb emu kill                        # stop the emulator
adb devices                         # expect "emulator-5554  device" when up
adb uninstall com.levi.pocketdj     # clean app state (or: adb shell pm clear com.levi.pocketdj)
```

New AVDs / SDK packages: `sdkmanager --sdk_root=$ANDROID_HOME "<package>"` then
`avdmanager create avd -n <name> -k "<system-image>" -d pixel_7`.

## Verification bar (checkpoints)

Per [ship-and-verify-each-feature]: a checkpoint build must be functionally
driven — launch, navigate to the feature, exercise it, screenshot each state,
check `logcat` for crashes — before presenting it to Levi.
