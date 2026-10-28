package com.levi.pocketdj.auto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutoIdCodecTest {
    private val nasty = listOf("plain", "has:colon", "uni é中🎵 code", "100% /?&=#", "a:b:c:d", "")

    private fun roundTrip(id: AutoId) = assertEquals(id, AutoId.decode(id.encoded))

    @Test fun simpleIds() {
        roundTrip(AutoId.Root); roundTrip(AutoId.Continue); roundTrip(AutoId.Loading)
        AutoId.Tab.Which.entries.forEach { roundTrip(AutoId.Tab(it)) }
    }

    @Test fun everyKindWithAwkwardComponents() {
        for (s in nasty) {
            roundTrip(AutoId.Empty(s))
            roundTrip(AutoId.Solo(s))
            roundTrip(AutoId.AddTo(s))
            for (k in AutoTargetKind.entries) roundTrip(AutoId.AddTarget(s, k, s + "x"))
            val refs = listOf(
                AutoCollectionRef(AutoCollectionKind.PLAYLIST, s),
                AutoCollectionRef(AutoCollectionKind.POCKET, s),
                AutoCollectionRef(AutoCollectionKind.SOURCE, s, "Src: $s"),
            )
            for (r in refs) {
                roundTrip(AutoId.Collection(r)); roundTrip(AutoId.PlayAll(r)); roundTrip(AutoId.ShuffleAll(r))
                roundTrip(AutoId.Song(r, s)); roundTrip(AutoId.Song(r, "z:$s"))
            }
        }
    }

    @Test fun encodedFormHasNoRawColonsInsideComponents() {
        val e = AutoId.Song(AutoCollectionRef(AutoCollectionKind.POCKET, "a:b"), "c:d").encoded
        assertEquals(5, e.split(':').size)
    }

    @Test fun foreignAndMalformedIdsDecodeToNull() {
        listOf("", "garbage", "tab:nope", "col:pk:x", "col:zz:x:", "col:src:x:", "root:extra", "addt:a:weird:b", "solo:%ZZ")
            .forEach { assertNull(it, AutoId.decode(it)) }
    }

    @Test fun sourceRefsRequireASourceName() {
        assertNull(AutoId.decode("col:src:abc:"))
    }
}
