---
name: android-build
description: Build the native Android PocketDJ app under android/. Use when asked to "build the android app", "compile the android app", "assemble the apk", or to produce an installable APK for the emulator or a device. Covers the JDK/SDK environment, the Gradle wrapper (never brew Gradle), and APK output paths.
---

# Build the native PocketDJ app (Android)

The Android app lives in **`android/`** — a single-module Gradle project
(`:app`), Kotlin 2.x + Jetpack Compose (Material 3), package
**`com.levi.pocketdj`**, compileSdk/targetSdk **36**, minSdk **35** (Levi
targets only the last two Android versions).

## Environment (every shell — Bash tool calls don't persist env)

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

Levi's interactive fish shell already has these via
`~/.config/fish/conf.d/android.fish`.

## Build

**Always the wrapper** — `./gradlew` (Gradle 8.13, paired with AGP 8.9.1).
Brew's `gradle` (9.x) is only for regenerating the wrapper and will NOT build
the project.

```bash
cd android
./gradlew :app:assembleDebug
# product: app/build/outputs/apk/debug/app-debug.apk  (~58 MB)
```

First-ever build downloads dependencies — allow up to ~10 min; later builds are
fast. Release: `:app:assembleRelease` (unsigned until a keystore is set up).

## Versions (pinned in gradle/libs.versions.toml)

AGP **8.9.1** · Gradle wrapper **8.13** · Kotlin **2.1.0** (+ compose &
serialization plugins) · Compose BOM **2025.01.00** · Navigation Compose ·
kotlinx-serialization + OkHttp + Coil. Bump versions in the catalog, not in
module files. AGP↔Gradle compatibility is strict — if you bump one, check the
other.

## Install + launch (booted emulator or device)

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.levi.pocketdj/.MainActivity
```

See the **android-emu** skill for booting the `pocketdj` AVD, screenshots, and
input taps; **android-test** for unit/instrumented tests.

## Conventions

- In-app accent = `#6EA8FF` (PocketDJ blue, same as `apple/…/Theme.swift`);
  launcher-icon background = PDX turquoise `#00A99D` (sampled from the iOS icon).
- Compose-only UI (no AppCompat/Material XML widgets); base XML theme is
  `android:Theme.Material.NoActionBar` with a dark window background.
- `android/local.properties` (sdk.dir) is machine-local + gitignored.
