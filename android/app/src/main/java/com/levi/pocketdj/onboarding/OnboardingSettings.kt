package com.levi.pocketdj.onboarding

import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.data.settings.SourceConfig

/** Onboarding's own preference keys (names are persisted: never rename once shipped). */
object OnboardingPrefs {
    /** iOS-compatible marker JSON key. */
    val MARKER = PrefKey.string("pdj.onboarding.v1")

    /** The "PocketDJ name" entered in stage 1 (optional; Settings ▸ Profile edits it later). */
    val PROFILE_NAME = PrefKey.string("pdj.profile.name")
}

/** Marker persistence over the settings DataStore. */
class DataStoreOnboardingMarkerStorage(private val settings: AppSettingsStore) : OnboardingMarkerStorage {
    override suspend fun read(): String? = settings.get(OnboardingPrefs.MARKER).ifBlank { null }
    override suspend fun write(json: String) = settings.set(OnboardingPrefs.MARKER, json)
}

/**
 * iOS `SettingsStore.applyOnboardingSources`: reconcile the three built-in sources with the
 * user's picks. A pick that is absent is appended (enabled); an unpicked one that is present
 * (matched by name OR url) is removed. Zero picks are legitimate. Pure.
 */
fun applyOnboardingSources(
    current: List<SourceConfig>,
    vinyl: Boolean,
    digital: Boolean,
    streaming: Boolean,
): List<SourceConfig> {
    val builtins = listOf(
        Triple(vinyl, Endpoints.SOURCE_NAME_VINYL, Endpoints.VINYL_INDEX_URL) to AppSettings.defaultSources().first(),
        Triple(digital, Endpoints.SOURCE_NAME_DIGITAL, Endpoints.DIGITAL_INDEX_URL) to AppSettings.digitalSource(),
        Triple(streaming, Endpoints.SOURCE_NAME_APPLE_MUSIC, Endpoints.APPLE_MUSIC_INDEX_URL) to AppSettings.appleMusicSource(),
    )
    var out = current
    for ((spec, preset) in builtins) {
        val (want, name, url) = spec
        val present = out.any { it.name == name || it.url == url }
        out = when {
            want && !present -> out + preset
            !want && present -> out.filterNot { it.name == name || it.url == url }
            else -> out
        }
    }
    return out
}

/** Stage 3 commit: transactional write of the picks into `AppSettings.sources`. */
suspend fun AppSettingsStore.applyOnboardingSources(vinyl: Boolean, digital: Boolean, streaming: Boolean) {
    updateSources { applyOnboardingSources(it, vinyl, digital, streaming) }
}
