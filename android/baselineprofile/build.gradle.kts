// Baseline + Startup Profile producer for :app (androidx.baselineprofile).
//
// Regenerate (connected API 33+ device or emulator; no root needed; ~15 min on the pocketdj AVD).
// It runs on EVERY connected device, so pin one when other emulators are up:
//   cd android && ANDROID_SERIAL=emulator-5554 ./gradlew :app:generateReleaseBaselineProfile
// (uninstall any differently-signed com.levi.pocketdj from that device first.)
// The result is written to app/src/release/generated/baselineProfiles/{baseline,startup}-prof.txt
// and committed; release builds compile it into the APK/AAB (assets/dexopt/baseline.prof) and R8
// uses the startup profile for DEX layout. Re-run after large UI changes.
plugins {
    alias(libs.plugins.android.test)
    alias(libs.plugins.androidx.baselineprofile)
}

android {
    namespace = "com.levi.pocketdj.baselineprofile"
    compileSdk = 36

    defaultConfig {
        minSdk = 35
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    targetProjectPath = ":app"
}

// Connected device (the pocketdj AVD / a phone); no Gradle-managed device download.
baselineProfile {
    useConnectedDevices = true
}

dependencies {
    implementation(libs.androidx.test.ext.junit)
    implementation(libs.androidx.test.uiautomator)
    implementation(libs.androidx.benchmark.macro.junit4)
}
