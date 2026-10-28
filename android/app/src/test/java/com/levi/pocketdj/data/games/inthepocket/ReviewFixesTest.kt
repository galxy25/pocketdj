package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.pockets.lpIntStrict
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReviewFixesTest {
    @Test fun evaluatorBaseIdDelegatesToSharedSongVariant() {
        for (id in listOf("sng_1a7f6bc854af_clean", "sng_1a7f6bc854af_explicit", "plain", "sng_short_clean")) {
            assertEquals(SongVariant.baseId(id), InThePocketRoundEvaluator.baseId(id))
        }
    }

    @Test fun lpIntStrictAcceptsIntegralDoublesOnly() {
        val o = Json.parseToJsonElement("""{"a":3.0,"b":3.2,"c":4,"d":"5"}""").jsonObject
        assertEquals(3, o.lpIntStrict("a")); assertNull(o.lpIntStrict("b"))
        assertEquals(4, o.lpIntStrict("c")); assertNull(o.lpIntStrict("d"))
    }

    @Test fun outcomeBrokeAtIsStrict() {
        fun dec(s: String) = InThePocketOutcome.fromJson(Json.parseToJsonElement(s))
        assertEquals(InThePocketOutcome.Broke(2), dec("""{"outcome":"broke","brokeAt":2}"""))
        assertEquals(InThePocketOutcome.Broke(2), dec("""{"outcome":"broke","brokeAt":2.0}"""))
        assertEquals(InThePocketOutcome.Broke(1), dec("""{"outcome":"broke","brokeAt":"2"}"""))
        assertEquals(InThePocketOutcome.Broke(1), dec("""{"outcome":"broke","brokeAt":2.7}"""))
    }
}
