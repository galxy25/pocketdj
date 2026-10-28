package com.levi.pocketdj.data.edition

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * "Prefer explicit versions" TRI-STATE, persisted as "" (never chosen) / "true" / "false".
 * null => nothing is substituted; false => prefer clean; true => prefer explicit.
 */
object EditionSettings {
    val PREFER_EXPLICIT_RAW = PrefKey.string("preferExplicitVersionsRaw", "")

    fun decode(raw: String): Boolean? = when (raw) {
        "true" -> true
        "false" -> false
        else -> null
    }

    fun encode(v: Boolean?): String = v?.toString() ?: ""

    fun flow(store: AppSettingsStore): Flow<Boolean?> = store.flow(PREFER_EXPLICIT_RAW).map(::decode)

    suspend fun get(store: AppSettingsStore): Boolean? = decode(store.get(PREFER_EXPLICIT_RAW))

    suspend fun set(store: AppSettingsStore, v: Boolean) = store.set(PREFER_EXPLICIT_RAW, encode(v))
}
