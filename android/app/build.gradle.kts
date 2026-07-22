plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.levi.pocketdj"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.levi.pocketdj"
        minSdk = 35
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)

    // Declared for Phase 1+ use (network + serialization + image loading).
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.coil.compose)

    // Playback: Media3/ExoPlayer + MediaSession (locked decision 4). HLS for the
    // rip server's live-stream path (playback.md §4.5).
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.exoplayer.hls)
    implementation(libs.androidx.media3.session)

    // Settings persistence (additive-safe Preferences DataStore).
    implementation(libs.androidx.datastore.preferences)

    // QR generation for Jukebox Hero (jukebox.md §6.1) — pure-Java, offline.
    implementation(libs.zxing.core)

    // Apple Music for Android SDK (specs/applemusic.md §1). Vendored AARs — not
    // on Maven — wired as file dependencies (settings.gradle.kts sets
    // FAIL_ON_PROJECT_REPOS, so a module-level flatDir repo is rejected).
    //   musickitauth  : dev-token → Music-User-Token sign-in (auth activities).
    //   mediaplayback : full-track DRM controller (arm64/armv7 native .so only).
    implementation(files("libs/musickitauth-release-1.1.2.aar"))
    implementation(files("libs/mediaplayback-release-1.1.1.aar"))
    // The auth activities extend AppCompatActivity — mandatory transitive dep the
    // AARs assume but don't declare (specs/applemusic.md §1, fact 0.4).
    implementation(libs.androidx.appcompat)

    debugImplementation(libs.androidx.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
