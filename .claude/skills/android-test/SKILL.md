---
name: android-test
description: Run the Android PocketDJ app's tests. Use when asked to "test the android app", "run the android tests", "run the kotlin tests", or to verify an Android feature. Covers JVM unit tests via Gradle and (once present) instrumented tests on the pocketdj emulator.
---

# Test the native PocketDJ app (Android)

Environment first (see **android-build** — same exports every shell):

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
cd android
```

## Unit tests (JVM — no emulator)

```bash
./gradlew :app:testDebugUnitTest
# report: app/build/reports/tests/testDebugUnitTest/index.html
```

Single class/method:

```bash
./gradlew :app:testDebugUnitTest --tests "com.levi.pocketdj.TabRegistryTest"
./gradlew :app:testDebugUnitTest --tests "*.TabRegistryTest.someMethod"
```

**Verify the test COUNT moved, not just the exit status** — a new test file that
isn't picked up still exits 0 (same trap as XcodeGen on the Apple side). Count
lives in the XML under `app/build/test-results/testDebugUnitTest/`.

## Instrumented tests (androidTest — need the emulator)

Boot the `pocketdj` AVD first (**android-emu** skill), then:

```bash
./gradlew :app:connectedDebugAndroidTest
# report: app/build/reports/androidTests/connected/index.html
```

## Ground rules

- Unit-test pure logic (stores, filters, schema decode) off the device — mirror
  the Apple split (`Tests/Unit` vs XCUITests).
- Persistence tests must include a decode-of-OLD-document case whenever a saved
  schema gains a field (additive-optional rule — same as iOS).
- Functional verification for a checkpoint = drive the real app on the emulator
  + screenshot (android-emu), not just green unit tests.
