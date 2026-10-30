package com.levi.pocketdj.screens.browse

import org.junit.Test
import org.junit.Assert.assertEquals

class ProfilePlayabilityTest {
    @Test fun profileRowWithLocalAssetPlaysWithoutManifestOrServer() {
        assertEquals(Playability.STREAM, playability("pdj_abc", emptyMap(), hasRipServer = false, hasProfileAsset = true))
    }

    @Test fun profileRowWithoutAssetIsNotPlayable() {
        assertEquals(Playability.NONE, playability("pdj_abc", emptyMap(), hasRipServer = false, hasProfileAsset = false))
    }
}
