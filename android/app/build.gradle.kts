plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Release signing inputs (release plan A1/A3): environment first, then Gradle properties
// (-P or ~/.gradle/gradle.properties). Nothing secret lives in git; without
// ANDROID_UPLOAD_STORE_FILE the release build is left unsigned (CI / other agents still build).
fun releaseInput(name: String): String? =
    System.getenv(name)?.takeIf { it.isNotBlank() }
        ?: project.findProperty(name)?.toString()?.takeIf { it.isNotBlank() }

android {
    namespace = "com.levi.pocketdj"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.levi.pocketdj"
        minSdk = 35
        targetSdk = 36
        // Play + sideload share one monotonic sequence: a Unix timestamp passed as
        // -PversionCode=$(date +%s) (same scheme as BUILD_NUMBER in apple/scripts/testflight.sh).
        // Dev builds keep 1.
        versionCode = (project.findProperty("versionCode") ?: "1").toString().toInt()
        versionName = (project.findProperty("versionName") ?: "1.0.0").toString()

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Diagnostics upload channel gate (decision D8): DEBUG || DIAG_CHANNEL.
        // Release builds stay false; a TestFlight-style internal channel flips it.
        buildConfigField("boolean", "DIAG_CHANNEL", "false")
        // Build identity for Settings ▸ Debug (SVC-5); "unknown" outside a git checkout.
        val gitSha = runCatching {
            val p = ProcessBuilder("git", "rev-parse", "--short", "HEAD").directory(projectDir)
                .redirectErrorStream(true).start()
            p.inputStream.bufferedReader().readText().trim().also { p.waitFor() }
        }.getOrNull()?.takeIf { it.matches(Regex("[0-9a-f]{4,40}")) } ?: "unknown"
        buildConfigField("String", "GIT_SHA", "\"$gitSha\"")

        // STU-2: Studio native DSP lib (cpp/pdjdsp). ABI filters live on the build types below:
        // build-type filters MERGE with defaultConfig's, so one here could never be narrowed.
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                // Play's 16 KB page-size rule: NDK r27 links 4 KB-aligned unless asked
                // (CMakeLists.txt also passes -z max-page-size=16384).
                arguments += listOf("-DANDROID_STL=c++_shared", "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON")
            }
        }
        // Q99: the diag-key import VIEW filters (incl. content:// */*) live on an activity-alias
        // that is enabled only in builds with the diag channel (debug, or -PdiagChannel=true).
        manifestPlaceholders["diagKeyImport"] = "false"
    }

    signingConfigs {
        create("release") {
            val store = releaseInput("ANDROID_UPLOAD_STORE_FILE")
            if (store != null) {
                storeFile = file(store)
                storePassword = releaseInput("ANDROID_UPLOAD_STORE_PASS")
                keyAlias = releaseInput("ANDROID_UPLOAD_KEY_ALIAS") ?: "upload"
                keyPassword = releaseInput("ANDROID_UPLOAD_KEY_PASS") ?: storePassword
                if (store.endsWith(".p12") || store.endsWith(".pfx")) storeType = "pkcs12"
            }
        }
    }

    ndkVersion = "27.2.12479018"
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/pdjdsp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        debug {
            // Real devices are arm64; x86_64 serves the emulator.
            ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
            manifestPlaceholders["diagKeyImport"] = "true"
        }
        release {
            // Play/sideload ship ARM only: the Apple Music SDK (mediaplayback AAR) has arm64-v8a +
            // armeabi-v7a only, so an x86_64 copy would have no Apple Music. -PincludeX86=true adds
            // x86_64 back for the emulator smoke test of a minified build (never for upload).
            ndk {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
                if (project.findProperty("includeX86") == "true") abiFilters += "x86_64"
            }
            if (releaseInput("ANDROID_UPLOAD_STORE_FILE") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            // -PdiagChannel=true: internal diag-channel build (D8 / Q99).
            if (project.findProperty("diagChannel") == "true") {
                buildConfigField("boolean", "DIAG_CHANNEL", "true")
                manifestPlaceholders["diagKeyImport"] = "true"
            }
            isMinifyEnabled = true
            isShrinkResources = true
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

    // MIX-2: instrumented audio tests share the JVM mp3 fixtures
    sourceSets.getByName("androidTest").resources.srcDir("src/test/resources")

    buildFeatures {
        compose = true
        buildConfig = true
        prefab = true // Oboe ships as a prefab AAR (STU-2)
    }
}

dependencies {
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
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

    // Decision D4 dependency sweep: later packages add files, not build lines.
    implementation(libs.androidx.material3.adaptive.navigation.suite)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.glance.appwidget)
    implementation(libs.androidx.media3.common)
    implementation(libs.play.services.location)

    // STU-2: Oboe low-latency output (prefab; linked from cpp/pdjdsp).
    implementation(libs.oboe)

    debugImplementation(libs.androidx.ui.tooling)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.androidx.work.testing)
}
