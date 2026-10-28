package com.levi.pocketdj.data.settings

/**
 * Shell-owned Settings values (SURF-6). Persisted DataStore key names are FROZEN once shipped
 * (additive-optional: a missing key yields the default).
 */
object ShellSettings {
    /** iOS `SettingsStore.recentlyAddedDefaultCount` / `recentlyAddedMaxCount`. */
    const val RECENTLY_ADDED_DEFAULT = 3650
    const val RECENTLY_ADDED_MIN = 1
    const val RECENTLY_ADDED_MAX = 100_000

    /** Settings ▸ Collections "Default recently added" (iOS `defaultRecentlyAddedCount`). */
    val DEFAULT_RECENTLY_ADDED_COUNT = PrefKey.int("defaultRecentlyAddedCount", RECENTLY_ADDED_DEFAULT)

    /** Settings ▸ Import server "Rip from cloud source" (iOS `ripFromCloud`, default off). */
    val RIP_FROM_CLOUD = PrefKey.boolean("ripFromCloud", false)

    /** iOS didSet clamp: min(max(v, 1), max). Applied on write AND on read. */
    fun clampRecentlyAdded(value: Int): Int =
        value.coerceIn(RECENTLY_ADDED_MIN, RECENTLY_ADDED_MAX)

    /**
     * Text-field entry: digits only; blank/unparseable leaves the stored value unchanged (null),
     * overflow clamps to the max (iOS number-format field behaves the same way).
     */
    fun parseRecentlyAdded(text: String): Int? {
        val digits = text.trim()
        if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
        return clampRecentlyAdded(digits.toBigInteger().min(RECENTLY_ADDED_MAX.toBigInteger()).toInt())
    }

    /** Profile name as stored: trimmed (blank means "Studio" at the consumers). */
    fun normalizeProfileName(raw: String): String = raw.trim()
}

suspend fun AppSettingsStore.setDefaultRecentlyAddedCount(value: Int) =
    set(ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT, ShellSettings.clampRecentlyAdded(value))

suspend fun AppSettingsStore.defaultRecentlyAddedCount(): Int =
    ShellSettings.clampRecentlyAdded(get(ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT))

suspend fun AppSettingsStore.setRipFromCloud(on: Boolean) = set(ShellSettings.RIP_FROM_CLOUD, on)
