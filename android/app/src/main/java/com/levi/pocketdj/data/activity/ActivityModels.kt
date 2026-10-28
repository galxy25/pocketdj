package com.levi.pocketdj.data.activity

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * Collection-activity document models (specs/activity-favorites.md §2) — the
 * append-only log of user collection acts powering History's Activity segment.
 * Shape-compatible with iOS `pocketdj-collection-activity.json`.
 *
 * ALL FOUR kinds are defined now even though P2 emits only add/remove — the
 * schema is the future-proof part; a later favorites slice plumbs heart/unheart
 * straight in with zero store changes.
 */

/** What happened. Raw tokens are the persisted values — never rename. */
@Serializable
enum class ActivityKind(val token: String) {
    @SerialName("add")
    ADD("add"),

    @SerialName("heart")
    HEART("heart"),

    @SerialName("unheart")
    UNHEART("unheart"),

    @SerialName("remove")
    REMOVE("remove"),

    /** Library/catalog add (Discover +Add, imports) — no collection fields. */
    @SerialName("catalogAdd")
    CATALOG_ADD("catalogAdd"),

    @SerialName("catalogRemove")
    CATALOG_REMOVE("catalogRemove"),
}

/**
 * One activity event. `itemTitle`/`collectionName` are SNAPSHOTS at record time
 * so a row stays readable after the item leaves the catalog or the collection
 * is renamed/deleted. The three collection fields are null for heart/unheart.
 * `id` travels verbatim (exact-string dedupe — never case-normalize).
 */
@Serializable
data class ActivityEvent(
    val id: String,
    /** Epoch ms of the event. */
    val at: Double,
    val kind: ActivityKind,
    val itemId: String,
    val itemTitle: String? = null,
    /** Artist snapshot (additive-optional). */
    val itemArtist: String? = null,
    val collectionId: String? = null,
    /** AddTarget.Kind raw token ("pocket" / "playlist"). */
    val collectionKind: String? = null,
    val collectionName: String? = null,
    /** installId of the ORIGINATING device (null ⇒ legacy, treated as local). */
    val originInstallId: String? = null,
    /** `.catalogAdd` only: the Apple Music library write outcome token. */
    val libraryWrite: String? = null,
)

/**
 * The on-disk document. Additive-optional iron law: every field defaulted,
 * unknown keys ignored — an empty or forward-version file loads degraded rather
 * than resetting the store. `installId` is the merge attribution key.
 */
@Serializable(with = ActivityDocumentSerializer::class)
data class ActivityDocument(
    val schemaVersion: Int = COLLECTION_ACTIVITY_SCHEMA_VERSION,
    val installId: String = "",
    /** Append-only, oldest → newest. */
    val events: List<ActivityEvent> = emptyList(),
)

const val COLLECTION_ACTIVITY_SCHEMA_VERSION = 1

/**
 * Lenient document decode (iOS `Document.init(from:)`): every field falls back to its default and
 * `events` decode PER ELEMENT — an unknown/malformed event (e.g. a newer build's kind) is skipped
 * while every other event is kept, instead of resetting the whole log.
 */
object ActivityDocumentSerializer : KSerializer<ActivityDocument> {
    override val descriptor = buildClassSerialDescriptor("ActivityDocument")

    override fun deserialize(decoder: Decoder): ActivityDocument {
        val input = decoder as? JsonDecoder ?: throw SerializationException("JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("activity document must be an object")
        val events = (obj["events"] as? JsonArray)?.mapNotNull { el ->
            runCatching { input.json.decodeFromJsonElement(ActivityEvent.serializer(), el) }.getOrNull()
        } ?: emptyList()
        return ActivityDocument(
            schemaVersion = (obj["schemaVersion"] as? JsonPrimitive)?.intOrNull
                ?: COLLECTION_ACTIVITY_SCHEMA_VERSION,
            installId = (obj["installId"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "",
            events = events,
        )
    }

    override fun serialize(encoder: Encoder, value: ActivityDocument) {
        val output = encoder as? JsonEncoder ?: throw SerializationException("JSON only")
        output.encodeJsonElement(
            buildJsonObject {
                put("schemaVersion", value.schemaVersion)
                put("installId", value.installId)
                put(
                    "events",
                    JsonArray(value.events.map { output.json.encodeToJsonElement(ActivityEvent.serializer(), it) }),
                )
            },
        )
    }
}
