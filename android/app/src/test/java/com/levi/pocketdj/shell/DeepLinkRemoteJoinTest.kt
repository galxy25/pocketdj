package com.levi.pocketdj.shell

import org.junit.Assert.assertEquals
import org.junit.Test

class DeepLinkRemoteJoinTest {
    @Test fun remoteJoinLinkParsesTheToken() {
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj://remote/join/ABCD2345"))
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj://remote/join/abcd2345"))
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj:///remote/join/ABCD2345"))
    }

    @Test fun malformedRemoteLinksAreNone() {
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/join/"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/join/a!b"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/leave/ABCD2345"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote"))
    }

    @Test fun remoteJoinParksInItsOwnSlot() {
        val store = PendingOpenStore()
        store.park(DeepLink.RemoteJoin("AAAA1111"))
        store.park(DeepLink.Navigate(ShellRoute.Album("x")))
        store.park(DeepLink.RemoteJoin("BBBB2222"))
        assertEquals(listOf<DeepLink>(DeepLink.Navigate(ShellRoute.Album("x")), DeepLink.RemoteJoin("BBBB2222")), store.drain())
    }
}
