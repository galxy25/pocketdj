package com.levi.pocketdj.studio.packs

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.int
import com.levi.pocketdj.studio.model.lossyList
import com.levi.pocketdj.studio.model.str
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * Instrument-pack manifest (`rips/instruments/index.json`):
 * `{version, attribution, sharedBanks:[{key,bytes,sha256}], packs:[{id,name,instrument,program,bankKey,bytes}]}`.
 *
 * Studio schema doctrine: every FIELD decodes leniently, every LIST per-element lossily — a future
 * manifest's unknown instrument drops that PACK only, never the list or the document.
 */
data class InstrumentBank(
    /** Key relative to [com.levi.pocketdj.data.config.Endpoints.INSTRUMENTS_BASE]; also seeds the local file name. */
    val key: String,
    val bytes: Long = 0,
    /** Hex SHA-256; empty => older manifest without digests (install unverified, logged). */
    val sha256: String = "",
) {
    companion object {
        /** null when there is no key (nothing to download or name). */
        fun fromJson(o: JsonObject): InstrumentBank? {
            val key = o.str("key").orEmpty()
            if (key.isEmpty()) return null
            return InstrumentBank(key, (o.int("bytes") ?: 0).toLong(), o.str("sha256").orEmpty())
        }
    }
}

data class InstrumentPack(
    val id: String,
    val name: String,
    val instrument: InstrumentKey,
    /** GM program (0-based); defaults to the instrument's locked-in program. */
    val program: Int,
    /** The shared bank this pack rides; empty => listable but not downloadable. */
    val bankKey: String,
    val bytes: Long = 0,
) {
    companion object {
        /** null for a missing id or an instrument this build can't play (the "unknown => skip pack" rule). */
        fun fromJson(o: JsonObject): InstrumentPack? {
            val id = o.str("id").orEmpty()
            val inst = InstrumentKey.fromRaw(o.str("instrument")) ?: return null
            if (id.isEmpty()) return null
            val name = o.str("name").orEmpty().ifEmpty { inst.displayName }
            return InstrumentPack(id, name, inst, o.int("program") ?: inst.gmProgram, o.str("bankKey").orEmpty(), (o.int("bytes") ?: 0).toLong())
        }
    }
}

data class InstrumentPackIndex(
    val version: Int = 0,
    /** GeneralUser GS licence attribution, shown on the packs screen. */
    val attribution: String = "",
    val sharedBanks: List<InstrumentBank> = emptyList(),
    val packs: List<InstrumentPack> = emptyList(),
) {
    companion object {
        private val json = Json { isLenient = true }

        /** Lenient + lossy; null only when the body is not JSON at all (a non-object decodes as an empty index). */
        fun decode(text: String): InstrumentPackIndex? {
            val el = runCatching { json.parseToJsonElement(text) }.getOrNull() ?: return null
            val o = el as? JsonObject ?: return InstrumentPackIndex()
            return InstrumentPackIndex(
                version = o.int("version") ?: 0,
                attribution = o.str("attribution").orEmpty(),
                sharedBanks = o.lossyList("sharedBanks") { InstrumentBank.fromJson(it) } ?: emptyList(),
                packs = o.lossyList("packs") { InstrumentPack.fromJson(it) } ?: emptyList(),
            )
        }
    }
}

/** Pack download failures, surfaced per bank on the pack row. */
sealed class InstrumentPackError(val description: String) : Exception(description) {
    object BadResponse : InstrumentPackError("Download failed")
    object ShaMismatch : InstrumentPackError("Downloaded file failed verification")
    object FileSystem : InstrumentPackError("Couldn't save the sound bank")
    object NotDownloadable : InstrumentPackError("This pack can't be downloaded by this version")
}

/** Pure deterministic naming for downloaded banks (iOS `bankSlug` / `localBankFileName`). */
object InstrumentBankNaming {
    /**
     * Last path component minus `.sf2`, lowercased, anything outside `[a-z0-9._-]` collapsed to one `-`,
     * trimmed of edge dashes; `banks/GeneralUser GS 2.0.3.sf2` -> `generaluser-gs-2.0.3`.
     */
    fun slug(key: String): String {
        var base = key.substringAfterLast('/')
        if (base.lowercase().endsWith(".sf2")) base = base.dropLast(4)
        val sb = StringBuilder()
        var lastWasDash = false
        for (ch in base.lowercase()) {
            val keep = ch in 'a'..'z' || ch in '0'..'9' || ch == '.' || ch == '_' || ch == '-'
            if (keep) {
                sb.append(ch); lastWasDash = ch == '-'
            } else if (!lastWasDash) {
                sb.append('-'); lastWasDash = true
            }
        }
        val out = sb.toString().trim('-')
        return out.ifEmpty { "bank" }
    }

    /** `instrument-<slug>.sf2`, minted through [StudioFolders] so writer and strict parser never drift. */
    fun localFileName(key: String): String = StudioFolders.fileName(StudioFamily.INSTRUMENTS, slug(key))
}

/** One downloadable bank row on the Packs screen: every pack that rides the same bank is listed once, under it. */
data class InstrumentBankGroup(val bankKey: String, val packs: List<InstrumentPack>, val bytes: Long) {
    val title: String get() = packs.joinToString(", ") { it.name }
    val downloadable: Boolean get() = bankKey.isNotEmpty()
}

object InstrumentPackGroups {
    /**
     * Group [packs] by `bankKey` (first-seen order). Size = the bank's advertised size from [banks], else the
     * largest pack `bytes`. A pack with no bankKey is its own non-downloadable group.
     */
    fun group(packs: List<InstrumentPack>, banks: List<InstrumentBank>): List<InstrumentBankGroup> {
        val out = ArrayList<InstrumentBankGroup>()
        val byKey = LinkedHashMap<String, MutableList<InstrumentPack>>()
        for (p in packs) {
            if (p.bankKey.isEmpty()) out.add(InstrumentBankGroup("", listOf(p), p.bytes)) else byKey.getOrPut(p.bankKey) { ArrayList() }.add(p)
        }
        val grouped = byKey.map { (key, ps) ->
            InstrumentBankGroup(key, ps, banks.firstOrNull { it.key == key }?.bytes?.takeIf { it > 0 } ?: ps.maxOf { it.bytes })
        }
        return grouped + out
    }

    /** "32 MB" / "820 KB" / "" for unknown. */
    fun sizeLabel(bytes: Long): String = when {
        bytes <= 0 -> ""
        bytes >= 1_000_000 -> "%d MB".format(Math.round(bytes / 1_000_000.0))
        else -> "%d KB".format(Math.max(1L, Math.round(bytes / 1_000.0)))
    }
}
