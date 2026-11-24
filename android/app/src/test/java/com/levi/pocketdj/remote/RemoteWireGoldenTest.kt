package com.levi.pocketdj.remote

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.sequencer.RepeatMode
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/** Wire goldens are hand-derived from RemoteWire.swift (see `_note` in the JSON), not captured from Swift. */
class RemoteWireGoldenTest {
    private val json = PdjJson.lenient
    private val golden: JsonObject = json.parseToJsonElement(
        javaClass.classLoader!!.getResourceAsStream("parity2/remote-wire-goldens.json")!!.readBytes().decodeToString(),
    ).jsonObject

    /** Numbers by value, so Swift's `5` and Kotlin's `5.0` agree. */
    private fun norm(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonObject -> e.mapValues { norm(it.value) }
        is JsonArray -> e.map { norm(it) }
        is JsonPrimitive -> if (e.isString) e.content else e.contentOrNull.let { c ->
            c?.toBooleanStrictOrNull() ?: c?.toDouble()
        }
    }

    private fun <T> roundTrip(name: String, ser: KSerializer<T>): T {
        val g = golden[name]!!
        val v = json.decodeFromJsonElement(ser, g)
        assertEquals("re-encode $name", norm(g), norm(json.encodeToJsonElement(ser, v)))
        return v
    }

    @Test fun everyCommandCaseDecodesAndReEncodesToTheSwiftShape() {
        val cmds = golden["commands"] as JsonObject
        assertEquals(16, cmds.size)
        for ((name, g) in cmds) {
            val c = json.decodeFromJsonElement(RemoteCommandSerializer, g)
            assertEquals(name, norm(g), norm(json.encodeToJsonElement(RemoteCommandSerializer, c)))
            assertEquals(name, (g as JsonObject).keys.single(), json.encodeToJsonElement(RemoteCommandSerializer, c).jsonObject.keys.single())
        }
    }

    @Test fun commandPayloadsDecodeToTypedValues() {
        fun dec(n: String) = json.decodeFromJsonElement(RemoteCommandSerializer, (golden["commands"] as JsonObject)[n]!!)
        val play = dec("play") as RemoteCommand.Play
        assertEquals(1, play.startIndex)
        assertEquals("r2", play.rows[1].rid)
        assertEquals("1440", play.rows[0].row.appleMusicId)
        assertEquals(RemoteCommand.SetPlaying(true), dec("setPlaying"))
        assertEquals(RemoteCommand.SetRepeat(RepeatMode.ALL), dec("setRepeat"))
        assertEquals(RemoteCommand.SetShuffle(false), dec("setShuffle"))
        assertEquals(RemoteCommand.Seek(1234), dec("seek"))
        assertEquals(RemoteCommand.Move("r3", 2), dec("move"))
        assertEquals(RemoteCommand.Advanced("r2"), dec("advanced"))
        assertEquals(RemoteCommand.PlayPause, dec("playPause"))
    }

    @Test fun payloadlessAndUnlabeledCasesUseSwiftsKeys() {
        fun enc(c: RemoteCommand) = json.encodeToString(RemoteCommandSerializer, c)
        assertEquals("""{"playPause":{}}""", enc(RemoteCommand.PlayPause))
        assertEquals("""{"setPlaying":{"_0":true}}""", enc(RemoteCommand.SetPlaying(true)))
        assertEquals("""{"setRepeat":{"_0":"one"}}""", enc(RemoteCommand.SetRepeat(RepeatMode.ONE)))
        assertEquals("""{"move":{"rid":"a","toUpcomingOffset":2}}""", enc(RemoteCommand.Move("a", 2)))
    }

    @Test fun unknownOrMalformedCommandsFailToDecode() {
        fun bad(text: String) {
            try {
                json.decodeFromString(RemoteCommandSerializer, text)
                throw AssertionError("decoded: $text")
            } catch (_: kotlinx.serialization.SerializationException) {
            } catch (_: IllegalArgumentException) {
            }
        }
        bad("""{"teleport":{}}""")
        bad("""{"playPause":{},"skipNext":{}}""")
        bad("{}")
        bad("""{"setPlaying":{}}""")
        bad("""{"setRepeat":{"_0":"sideways"}}""")
        bad("""{"seek":{"ms":"x"}}""")
        bad("""["playPause"]""")
    }

    @Test fun unknownCommandCaseDropsTheWholeCommandMessage() {
        val env = RemoteEnvelope(1, "command", b64("""{"id":"x","command":{"teleport":{}}}"""))
        assertNull(env.decode(RemoteCommandMessage.serializer()))
        val ok = RemoteEnvelope(1, "command", b64("""{"id":"x","command":{"skipNext":{}}}"""))
        assertEquals(RemoteCommand.SkipNext, ok.decode(RemoteCommandMessage.serializer())?.command)
    }

    private fun b64(s: String) = Base64.getEncoder().encodeToString(s.toByteArray())

    @Test fun stateRoundTripsAndKeepsTheWindowContract() {
        val s = roundTrip("state", RemotePlaybackState.serializer())
        assertEquals(RemoteSessionMode.BACKSEAT, s.mode)
        assertEquals(3, s.windowStart)
        assertEquals(9, s.totalCount)
        assertNull(s.sessionActive)
        assertTrue(s.isActiveSession) // derived from rows
        assertEquals("r2", s.currentRow?.rid)
        assertEquals("remote", s.snapshot.source.kind)
        assertEquals("Golden Hour", s.snapshot.source.name)
        assertEquals(5_000_000.5, s.anchorSharedTime, 0.0)
        assertEquals(RepeatMode.OFF, s.repeatMode)
    }

    @Test fun sessionActiveFalseOverridesRows() {
        val s = roundTrip("stateSessionActive", RemotePlaybackState.serializer())
        assertFalse(s.isActiveSession)
    }

    @Test fun statePositionExtrapolatesOnlyWhilePlaying() {
        val s = json.decodeFromJsonElement(RemotePlaybackState.serializer(), golden["state"]!!)
        assertEquals(5_000L + 1_500, s.positionMs(s.anchorSharedTime + 1_500))
        assertEquals(0L, s.positionMs(s.anchorSharedTime - 99_999))
        val paused = s.copy(snapshot = s.snapshot.copy(isPlaying = false))
        assertEquals(5_000L, paused.positionMs(s.anchorSharedTime + 99_999))
    }

    @Test fun smallBodiesRoundTrip() {
        val hb = roundTrip("heartbeat", RemoteHeartbeat.serializer())
        assertEquals("r2", hb.currentRid)
        assertNull(roundTrip("heartbeatNoRid", RemoteHeartbeat.serializer()).currentRid)
        assertEquals(-1, roundTrip("stateRequest", RemoteStateRequest.serializer()).haveRevision)
        assertEquals(RemoteCommand.Seek(1234), roundTrip("commandMessage", RemoteCommandMessage.serializer()).command)
        val hello = roundTrip("hello", RemoteHello.serializer())
        assertEquals(listOf("mix"), hello.caps)
        assertEquals(RemoteDeviceRole.SPEAKER, hello.role)
        assertNull(roundTrip("helloNoCaps", RemoteHello.serializer()).caps)
        assertEquals(listOf("r2", "r4"), roundTrip("availability", RemoteAvailability.serializer()).unavailableRids)
        assertEquals(1000.5, roundTrip("ping", RemotePing.serializer()).t0, 0.0)
        assertEquals(2000.25, roundTrip("pong", RemotePong.serializer()).t2, 0.0)
    }

    @Test fun helloWithoutCapsOmitsTheKeyLikeSwift() {
        val text = json.encodeToString(RemoteHello.serializer(), RemoteHello("n", RemoteDeviceRole.CONTROLLER, "android"))
        assertEquals("""{"name":"n","role":"controller","platform":"android"}""", text)
    }

    @Test fun envelopeShapeIsVKindStandardBase64Payload() {
        val env = RemoteEnvelope.make(RemoteMessageKind.PING, RemotePing.serializer(), RemotePing("p", 1.5))
        val obj = json.parseToJsonElement(env.encode()).jsonObject
        assertEquals(setOf("v", "kind", "payload"), obj.keys)
        assertEquals("1", obj["v"].toString())
        assertEquals("ping", (obj["kind"] as JsonPrimitive).content)
        val body = String(Base64.getDecoder().decode((obj["payload"] as JsonPrimitive).content))
        assertEquals("""{"id":"p","t0":1.5}""", body)
        assertEquals(RemotePing("p", 1.5), RemoteEnvelope.parse(env.encode())!!.decode(RemotePing.serializer()))
    }

    @Test fun envelopePayloadIsPaddedStandardBase64NotUrlSafe() {
        // "??>" encodes with '+' / '/' in standard base64 and '-' / '_' in url-safe.
        val body = RemotePing("???>>>", 0.0)
        val env = RemoteEnvelope.make(RemoteMessageKind.PING, RemotePing.serializer(), body)
        assertFalse(env.payload.contains('-') || env.payload.contains('_'))
        assertEquals(0, env.payload.length % 4)
        assertEquals(body, env.decode(RemotePing.serializer()))
        // A url-safe payload from a foreign sender is rejected, not silently accepted.
        val urlSafe = RemoteEnvelope(1, "ping", Base64.getUrlEncoder().encodeToString("""{"id":"???>>>","t0":0}""".toByteArray()))
        if (urlSafe.payload.contains('-') || urlSafe.payload.contains('_')) assertNull(urlSafe.decode(RemotePing.serializer()))
    }

    @Test fun unknownKindsAndNewerEnvelopesAreIgnored() {
        assertNull(RemoteEnvelope(1, "mix.deckEvent", b64("{}")).knownKind)
        assertNull(RemoteEnvelope(99, "command", b64("{}")).knownKind)
        assertEquals(RemoteMessageKind.COMMAND, RemoteEnvelope(1, "command", b64("{}")).knownKind)
        assertEquals(RemoteMessageKind.STATE_REQUEST, RemoteEnvelope(1, "stateRequest", "").knownKind)
        assertEquals(8, RemoteMessageKind.entries.size)
    }

    @Test fun undecodableBodiesAreDropped() {
        assertNull(RemoteEnvelope(1, "state", b64("nope")).decode(RemotePlaybackState.serializer()))
        assertNull(RemoteEnvelope(1, "state", "!!!not base64").decode(RemotePlaybackState.serializer()))
        assertNull(RemoteEnvelope(1, "ping", b64("""{"id":"p"}""")).decode(RemotePing.serializer()))
        assertNull(RemoteEnvelope.parse("garbage"))
        assertNotNull(RemoteEnvelope.parse("""{"v":1,"kind":"zzz","payload":"e30="}"""))
    }

    @Test fun unknownBodyFieldsAreIgnoredAdditiveDoctrine() {
        val body = """{"name":"n","role":"speaker","platform":"ios","future":{"x":1}}"""
        assertEquals("n", RemoteEnvelope(1, "hello", b64(body)).decode(RemoteHello.serializer())?.name)
    }

    @Test fun unknownRoleOrModeDropsTheBody() {
        assertNull(RemoteEnvelope(1, "hello", b64("""{"name":"n","role":"dj","platform":"x"}""")).decode(RemoteHello.serializer()))
    }

    @Test fun swiftRoundsHalfAwayFromZero() {
        assertEquals(-1L, roundAway(-0.5))
        assertEquals(1L, roundAway(0.5))
        assertEquals(3L, roundAway(2.5))
        assertEquals(-3L, roundAway(-2.5))
    }
}
