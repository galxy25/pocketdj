package com.levi.pocketdj.auto

import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoUpNextTest {
    private class FakeSource(var rows: List<AutoUpNextRow> = emptyList()) : AutoUpNextSource {
        val calls = mutableListOf<String>()
        override fun upcoming() = rows
        override fun jump(uid: String) { calls += "jump:$uid" }
        override fun playNext(uid: String) { calls += "next:$uid" }
        override fun moveToEnd(uid: String) { calls += "end:$uid" }
        override fun remove(uid: String) { calls += "rm:$uid"; rows = rows.filter { it.uid != uid } }
    }

    private fun row(uid: String, song: String = "a") = AutoUpNextRow(uid, song, "Q $song", "QA")

    private class Rig(rows: List<AutoUpNextRow>, limit: Int? = null, held: AutoHeld? = null) {
        val source = FakeSource(rows)
        val data = FakeAutoData(songs = mapOf("a" to mkSong("a"), "b" to mkSong("b")), held = held)
        val notified = mutableListOf<Pair<String, Int>>()
        val toasts = mutableListOf<String>()
        val upNext = AutoUpNext(source, data::song)
        val tree = AutoBrowseTree(data, upNext = upNext).also { it.rootLimit = limit }
        val cb = AutoLibraryCallback(
            tree = tree, addTargets = AutoAddTargets(object : AutoAddSink {
                override fun pockets() = emptyList<AutoTarget>()
                override fun playlists() = emptyList<AutoTarget>()
                override fun add(songId: String, kind: AutoTargetKind, targetId: String) = false
            }),
            player = object : AutoPlayer {
                override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) {}
                override suspend fun playSong(ref: AutoCollectionRef, songId: String) {}
                override suspend fun playSolo(songId: String) {}
                override suspend fun resumeHeld() {}
            },
            scope = CoroutineScope(Dispatchers.Unconfined),
            toast = { toasts += it },
            notifyChildrenChanged = { p, n -> notified += p to n },
        )
    }

    @Test fun idCodec_roundTripsAwkwardUids_andKeepsBareRootDistinct() {
        val uid = "u:1 é%/x"
        assertEquals(AutoId.UpNextRow(uid), AutoId.decode(AutoId.UpNextRow(uid).encoded))
        assertEquals(AutoId.UpNext, AutoId.decode("upnext"))
        assertEquals("upnext", AutoId.UpNext.encoded)
        assertNull(AutoId.decode("upnext:a:b"))
    }

    @Test fun children_areRowsKeyedByUid_repeatsDistinct_withCatalogTitleAndArt() {
        val r = Rig(listOf(row("u1", "a"), row("u2", "a"), row("u3", "zz")))
        val kids = r.cb.getChildren("upnext", 0, Int.MAX_VALUE)!!
        assertEquals(listOf("upnext:u1", "upnext:u2", "upnext:u3"), kids.map { it.id })
        assertEquals("Song a", kids[0].title)
        assertEquals("https://art/a.jpg", kids[0].artUrl)
        assertEquals("Q zz", kids[2].title) // not in the catalog: the queue's own title
        assertEquals("QA", kids[2].subtitle)
        assertTrue(kids.all { it.playable && it.upNextActions && !it.browsable })
    }

    @Test fun emptyList_isOneNothingUpNextRow() {
        val kids = Rig(emptyList()).cb.getChildren("upnext", 0, Int.MAX_VALUE)!!
        assertEquals(listOf("Nothing up next"), kids.map { it.title })
        assertFalse(kids.single().playable)
    }

    @Test fun rows_areCapped() {
        val big = (1..150).map { row("u$it") }
        assertEquals(AutoUpNext.MAX_ROWS, AutoUpNext(FakeSource(big), { null }).children().size)
    }

    @Test fun root_showsUpNextOnlyWhileRowsAreUpcoming() {
        val r = Rig(emptyList())
        assertFalse(r.cb.getChildren("root", 0, Int.MAX_VALUE)!!.any { it.id == "upnext" })
        r.source.rows = listOf(row("u1"), row("u2"))
        val root = r.cb.getChildren("root", 0, Int.MAX_VALUE)!!
        assertEquals("upnext", root.first().id) // ahead of the tabs
        assertEquals("2 songs coming up", root.first().subtitle)
        assertTrue(root.first().browsable)
    }

    @Test fun tree_withoutUpNext_isUnchanged() {
        val d = FakeAutoData()
        val ids = AutoBrowseTree(d).children("root")!!.map { it.id }
        assertEquals(listOf("tab:playlists", "tab:pockets"), ids)
    }

    @Test fun rootLimit_foldsUpNextIntoPlaylists_andContinueKeepsItsRootSlot() {
        val r = Rig(listOf(row("u1")), limit = 3, held = AutoHeld("T", "A"))
        // tabs = Playlists, Pockets (2) + Continue = 3 = limit: Up Next folds.
        assertEquals(listOf("continue", "tab:playlists", "tab:pockets"), r.cb.getChildren("root", 0, Int.MAX_VALUE)!!.map { it.id })
        assertEquals("upnext", r.cb.getChildren("tab:playlists", 0, Int.MAX_VALUE)!!.first().id)
    }

    @Test fun rootLimit_withRoomKeepsUpNextAtRoot() {
        val r = Rig(listOf(row("u1")), limit = 4)
        assertEquals(listOf("upnext", "tab:playlists", "tab:pockets"), r.cb.getChildren("root", 0, Int.MAX_VALUE)!!.map { it.id })
        assertTrue(r.cb.getChildren("tab:playlists", 0, Int.MAX_VALUE)!!.none { it.id == "upnext" })
    }

    @Test fun rowTap_isPlayNow_byUid() {
        val r = Rig(listOf(row("u1"), row("u2")))
        val job = r.cb.select("upnext:u2")
        assertNotNull(job)
        assertEquals(listOf("jump:u2"), r.source.calls)
        assertTrue(r.toasts.isEmpty())
    }

    @Test fun staleRowTap_isNoOpWithToast() {
        val r = Rig(listOf(row("u1")))
        r.cb.select("upnext:gone")
        assertTrue(r.source.calls.isEmpty())
        assertEquals(listOf("That song already played"), r.toasts)
    }

    @Test fun rowCommands_mapToSequencerEdits() {
        val r = Rig(listOf(row("u1"), row("u2"), row("u3")))
        assertTrue(r.cb.upNextCommand(AutoUpNext.ACTION_PLAY_NEXT, "upnext:u3"))
        assertTrue(r.cb.upNextCommand(AutoUpNext.ACTION_MOVE_TO_END, "upnext:u1"))
        assertTrue(r.cb.upNextCommand(AutoUpNext.ACTION_REMOVE, "upnext:u2"))
        assertEquals(listOf("next:u3", "end:u1", "rm:u2"), r.source.calls)
    }

    @Test fun rowCommands_rejectStaleRowsUnknownActionsAndForeignIds() {
        val r = Rig(listOf(row("u1")))
        assertFalse(r.cb.upNextCommand(AutoUpNext.ACTION_REMOVE, "upnext:nope"))
        assertFalse(r.cb.upNextCommand("pdj.bogus", "upnext:u1"))
        assertFalse(r.cb.upNextCommand(AutoUpNext.ACTION_REMOVE, "tab:playlists"))
        assertFalse(r.cb.upNextCommand(AutoUpNext.ACTION_REMOVE, "upnext")) // the root is not a row
        assertTrue(r.source.calls.isEmpty())
    }

    @Test fun queueChange_notifiesUpnextOnlyWhenIdentityOrOrderChanged() {
        val r = Rig(listOf(row("u1"), row("u2")))
        r.cb.onCatalogReady(); r.notified.clear()
        r.cb.onUpNextChanged()
        assertEquals(listOf("upnext" to 2), r.notified.filter { it.first == "upnext" }.take(1).let { it })
        // flip from "never evaluated" counts as appearing: root + tabs re-notified too
        assertTrue(r.notified.any { it.first == "root" })
        r.notified.clear()
        r.cb.onUpNextChanged() // unchanged: silent
        assertTrue(r.notified.isEmpty())
        r.source.rows = listOf(row("u2"), row("u1")) // reordered
        r.cb.onUpNextChanged()
        assertEquals(listOf("upnext" to 2), r.notified)
        r.notified.clear()
        r.source.rows = listOf(row("u2")) // one played/removed
        r.cb.onUpNextChanged()
        assertTrue(r.notified.contains("upnext" to 1))
        assertTrue(r.notified.any { it.first == "root" }) // count changed: root subtitle refreshed too
    }

    @Test fun countChange_pastTheRowCap_stillNotifies() {
        val many = (1..150).map { row("u$it") }
        val r = Rig(many)
        r.cb.onCatalogReady(); r.cb.onUpNextChanged(); r.notified.clear()
        r.source.rows = many.drop(1) // 149 left, visible 100 rows' uids identical shifted -> still differs; drop tail instead
        r.cb.onUpNextChanged(); r.notified.clear()
        r.source.rows = many.drop(1).dropLast(1) // first 100 uids unchanged, total 148
        r.cb.onUpNextChanged()
        assertTrue(r.notified.any { it.first == "root" })
    }

    @Test fun beforeCatalogReady_queueEditsDoNotNotify() {
        val r = Rig(listOf(row("u1")))
        r.cb.onUpNextChanged()
        r.source.rows = listOf(row("u1"), row("u2"))
        r.cb.onUpNextChanged()
        assertTrue(r.notified.isEmpty())
    }

    @Test fun queueEmptying_notifiesRootSoTheTabVanishes() {
        val r = Rig(listOf(row("u1")))
        r.cb.onCatalogReady(); r.cb.onUpNextChanged(); r.notified.clear()
        r.source.rows = emptyList()
        r.cb.onUpNextChanged()
        assertTrue(r.notified.any { it.first == "root" })
        assertTrue(r.notified.any { it.first == "upnext" && it.second == 1 }) // "Nothing up next" placeholder
    }

    @Test fun removeCommand_renotifiesImmediately() {
        val r = Rig(listOf(row("u1"), row("u2")))
        r.cb.onCatalogReady(); r.cb.onUpNextChanged(); r.notified.clear()
        r.cb.upNextCommand(AutoUpNext.ACTION_REMOVE, "upnext:u1")
        assertTrue(r.notified.contains("upnext" to 1))
    }

    @Test fun item_resolvesRowAndRoot_andNothingElse() {
        val r = Rig(listOf(row("u1")))
        assertEquals("upnext:u1", r.cb.getItem("upnext:u1")?.id)
        assertEquals("Up Next", r.cb.getItem("upnext")?.title)
        assertNull(r.cb.getItem("upnext:other"))
    }

    @Test fun queueMapping_takesRowsAfterTheCursor_byUid() {
        val q = listOf(
            QueueItem("s1", "One", uid = "a"), QueueItem("s2", "Two", "X", uid = "b"),
            QueueItem("s2", "Two", "X", uid = "c"),
        )
        assertEquals(listOf("c"), UpNextRows.upcoming(q, 1).map { it.uid })
        assertEquals(listOf("b", "c"), UpNextRows.upcoming(q, 0).map { it.uid })
        assertEquals(listOf("s2", "s2"), UpNextRows.upcoming(q, 0).map { it.songId })
        assertTrue(UpNextRows.upcoming(q, 2).isEmpty())
        assertTrue(UpNextRows.upcoming(emptyList(), 0).isEmpty())
    }

    @Test fun command_actionConstantsAreDistinctAndNamespaced() {
        assertEquals(3, AutoUpNext.ACTIONS.toSet().size)
        assertTrue(AutoUpNext.ACTIONS.all { it.startsWith("pdj.") })
    }
}
