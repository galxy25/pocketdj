package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.screens.producer.demux.DemuxScreenRules
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemuxRulesTest {
    @Test fun rotationDoesNotClearTheDemuxSessionButARealExitDoes() {
        assertFalse(DemuxScreenRules.shouldClearOnDispose(isChangingConfigurations = true))
        assertTrue(DemuxScreenRules.shouldClearOnDispose(isChangingConfigurations = false))
    }

    @Test fun customStemIdsMirrorTheServerRegex() {
        assertTrue(DemuxSource.isCustomStemId("smp_a-b"))
        assertFalse(DemuxSource.isCustomStemId("smp_a_b"))
        assertFalse(DemuxSource.isCustomStemId("xyz_abc"))
    }
}
