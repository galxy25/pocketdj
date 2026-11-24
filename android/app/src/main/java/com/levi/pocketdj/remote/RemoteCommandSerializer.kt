package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.RepeatMode
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.long

/**
 * Swift's synthesized enum Codable: every case is a single-key object `{"<case>":{<labels>}}`, an unlabeled
 * associated value is `_0`, a payload-less case is `{"case":{}}`. An unknown case key (or a shape that isn't a
 * one-key object) throws, so the envelope body fails to decode and the message is dropped (forward-compat).
 */
object RemoteCommandSerializer : KSerializer<RemoteCommand> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("RemoteCommand")

    private val rowsSer = ListSerializer(RemoteRow.serializer())
    private val ridsSer = ListSerializer(String.serializer())

    override fun serialize(encoder: Encoder, value: RemoteCommand) {
        val enc = encoder as? JsonEncoder ?: throw SerializationException("RemoteCommand is JSON-only")
        val json = enc.json
        fun rows(r: List<RemoteRow>) = json.encodeToJsonElement(rowsSer, r)
        val (name, body) = when (value) {
            is RemoteCommand.Play -> "play" to mapOf("rows" to rows(value.rows), "startIndex" to JsonPrimitive(value.startIndex))
            is RemoteCommand.PlayNow -> "playNow" to mapOf("rows" to rows(value.rows))
            RemoteCommand.PlayPause -> "playPause" to emptyMap()
            is RemoteCommand.SetPlaying -> "setPlaying" to mapOf("_0" to JsonPrimitive(value.on))
            is RemoteCommand.Seek -> "seek" to mapOf("ms" to JsonPrimitive(value.ms))
            RemoteCommand.SkipNext -> "skipNext" to emptyMap()
            RemoteCommand.SkipPrevious -> "skipPrevious" to emptyMap()
            is RemoteCommand.JumpTo -> "jumpTo" to mapOf("rid" to JsonPrimitive(value.rid))
            is RemoteCommand.EnqueueNext -> "enqueueNext" to mapOf("rows" to rows(value.rows))
            is RemoteCommand.Append -> "append" to mapOf("rows" to rows(value.rows))
            is RemoteCommand.Remove -> "remove" to mapOf("rid" to JsonPrimitive(value.rid))
            is RemoteCommand.Move -> "move" to mapOf(
                "rid" to JsonPrimitive(value.rid), "toUpcomingOffset" to JsonPrimitive(value.toUpcomingOffset),
            )
            is RemoteCommand.Reorder -> "reorder" to mapOf("rids" to json.encodeToJsonElement(ridsSer, value.rids))
            is RemoteCommand.SetRepeat -> "setRepeat" to mapOf("_0" to JsonPrimitive(value.mode.token))
            is RemoteCommand.SetShuffle -> "setShuffle" to mapOf("_0" to JsonPrimitive(value.on))
            is RemoteCommand.Advanced -> "advanced" to mapOf("fromRid" to JsonPrimitive(value.fromRid))
        }
        enc.encodeJsonElement(JsonObject(mapOf(name to JsonObject(body))))
    }

    override fun deserialize(decoder: Decoder): RemoteCommand {
        val dec = decoder as? JsonDecoder ?: throw SerializationException("RemoteCommand is JSON-only")
        val json = dec.json
        val root = dec.decodeJsonElement() as? JsonObject ?: throw SerializationException("command is not an object")
        if (root.size != 1) throw SerializationException("command must have exactly one case key")
        val (name, raw) = root.entries.first()
        val b = raw as? JsonObject ?: throw SerializationException("command body is not an object")
        fun el(k: String): JsonElement = b[k] ?: throw SerializationException("missing $k")
        fun prim(k: String): JsonPrimitive = el(k) as? JsonPrimitive ?: throw SerializationException("bad $k")
        fun str(k: String): String = prim(k).also { if (!it.isString) throw SerializationException("bad $k") }.content
        fun rows(k: String) = json.decodeFromJsonElement(rowsSer, el(k))
        return when (name) {
            "play" -> RemoteCommand.Play(rows("rows"), prim("startIndex").int)
            "playNow" -> RemoteCommand.PlayNow(rows("rows"))
            "playPause" -> RemoteCommand.PlayPause
            "setPlaying" -> RemoteCommand.SetPlaying(prim("_0").boolean)
            "seek" -> RemoteCommand.Seek(prim("ms").long)
            "skipNext" -> RemoteCommand.SkipNext
            "skipPrevious" -> RemoteCommand.SkipPrevious
            "jumpTo" -> RemoteCommand.JumpTo(str("rid"))
            "enqueueNext" -> RemoteCommand.EnqueueNext(rows("rows"))
            "append" -> RemoteCommand.Append(rows("rows"))
            "remove" -> RemoteCommand.Remove(str("rid"))
            "move" -> RemoteCommand.Move(str("rid"), prim("toUpcomingOffset").int)
            "reorder" -> RemoteCommand.Reorder(json.decodeFromJsonElement(ridsSer, el("rids")))
            "setRepeat" -> {
                val token = str("_0")
                RepeatMode.entries.firstOrNull { it.token == token }?.let { RemoteCommand.SetRepeat(it) }
                    ?: throw SerializationException("unknown repeat mode")
            }
            "setShuffle" -> RemoteCommand.SetShuffle(prim("_0").boolean)
            "advanced" -> RemoteCommand.Advanced(str("fromRid"))
            else -> throw SerializationException("unknown command case $name")
        }
    }
}
