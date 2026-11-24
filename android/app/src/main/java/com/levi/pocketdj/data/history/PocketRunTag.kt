package com.levi.pocketdj.data.history

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull

/**
 * Tags a play as part of a Pocket Wheel run (iOS `PocketRunTag`, PocketWheelModels.swift L168).
 * Exact iOS keys. [runId] is kept as the VERBATIM string (iOS writes an uppercase UUID; re-casing it
 * would make the same doc differ byte-wise and restart the sync ping-pong). [momentKey] "" and [slot] 0
 * are the lenient defaults for absent/garbled values.
 */
@Serializable(with = PocketRunTagSerializer::class)
data class PocketRunTag(
    val runId: String,
    val momentKey: String = "",
    val rowCollectionId: String? = null,
    /** 1-based slot in the run. */
    val slot: Int = 0,
)

@Serializable
private data class PocketRunTagWire(
    val runId: String,
    val momentKey: String = "",
    val rowCollectionId: String? = null,
    val slot: Int = 0,
)

/**
 * Lenient like iOS `try? decodeIfPresent`: a missing runId or a wrong-typed field yields null for the
 * whole tag (never fails the document); per-field garbage in momentKey/rowCollectionId/slot falls to defaults.
 */
object PocketRunTagSerializer : KSerializer<PocketRunTag> {
    override val descriptor: SerialDescriptor = PocketRunTagWire.serializer().descriptor

    override fun serialize(encoder: Encoder, value: PocketRunTag) {
        encoder.encodeSerializableValue(
            PocketRunTagWire.serializer(),
            PocketRunTagWire(value.runId, value.momentKey, value.rowCollectionId, value.slot),
        )
    }

    override fun deserialize(decoder: Decoder): PocketRunTag {
        val d = decoder as? JsonDecoder ?: throw SerializationException("PocketRunTag is JSON-only")
        val el: JsonElement = d.decodeJsonElement()
        return parse(el) ?: throw SerializationException("PocketRunTag: unusable")
    }

    /** Null when [el] has no usable runId. Pure; used by the event serializer too. */
    fun parse(el: JsonElement): PocketRunTag? {
        val o = el as? kotlinx.serialization.json.JsonObject ?: return null
        fun prim(k: String) = (o[k] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it !is JsonNull }
        val runId = prim("runId")?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() } ?: return null
        val momentKey = prim("momentKey")?.takeIf { it.isString }?.content ?: ""
        val row = prim("rowCollectionId")?.takeIf { it.isString }?.content
        val slot = prim("slot")?.takeIf { !it.isString }?.content?.toIntOrNull() ?: 0
        return PocketRunTag(runId, momentKey, row, slot)
    }
}

/** Nullable-field serializer: any unusable tag decodes to null instead of failing the event/document. */
object LenientPocketRunTagSerializer : KSerializer<PocketRunTag?> {
    override val descriptor: SerialDescriptor = PocketRunTagSerializer.descriptor

    override fun serialize(encoder: Encoder, value: PocketRunTag?) {
        if (value == null) encoder.encodeNull() else PocketRunTagSerializer.serialize(encoder, value)
    }

    override fun deserialize(decoder: Decoder): PocketRunTag? {
        val d = decoder as? JsonDecoder ?: return null
        return PocketRunTagSerializer.parse(d.decodeJsonElement())
    }
}
