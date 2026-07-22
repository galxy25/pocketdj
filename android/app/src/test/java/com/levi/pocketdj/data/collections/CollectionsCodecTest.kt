package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The document contract of specs/collections-schema.md §2–§4: round-trip
 * fidelity, decode-of-OLD-doc (additive-optional iron law + identity migrate),
 * the LOSSY per-element decode insurances, and the unknown-enum-coercion trap
 * (an unknown node kind must DROP the node, never coerce to a known kind).
 */
class CollectionsCodecTest {

    private val json = PdjJson.lenient

    private fun decode(text: String) = CollectionsCodec.decode(json, text)

    private fun encode(doc: CollectionsDocument) = CollectionsCodec.encode(json, doc)

    private fun songNode(id: String, songId: String, repeat: Int? = null) = PlaylistNode(
        nodeId = id,
        kind = PlaylistNode.Kind.SONG,
        songId = songId,
        repeatCount = repeat,
    )

    private fun fullDocument(): CollectionsDocument {
        val chapter = PlaylistNode(
            nodeId = "nd_seq1",
            kind = PlaylistNode.Kind.SEQUENCE,
            name = "Warmup",
            targetMs = 1_200_000,
            children = listOf(
                songNode("nd_1", "sng_1", repeat = 3),
                PlaylistNode(nodeId = "nd_2", kind = PlaylistNode.Kind.ALBUM, albumId = "alb_1"),
                PlaylistNode(nodeId = "nd_3", kind = PlaylistNode.Kind.POCKET, pocketId = "pkt_1"),
                PlaylistNode(nodeId = "nd_4", kind = PlaylistNode.Kind.TEXT, text = "mic break", note = "breathe"),
                PlaylistNode(
                    nodeId = "nd_5",
                    kind = PlaylistNode.Kind.SEQUENCE,
                    name = "Nested",
                    children = listOf(songNode("nd_6", "sng_2")),
                ),
            ),
        )
        return CollectionsDocument(
            pockets = listOf(
                Pocket(
                    id = "pkt_1",
                    name = "Warm Pocket",
                    description = "desc",
                    songIds = listOf("sng_1", "sng_2"),
                    albumIds = listOf("alb_1"),
                    childPocketIds = listOf("pkt_2"),
                    notes = listOf(PocketNote(id = "pnt_1", text = "poem", position = 1)),
                    folderId = "fld_1",
                    songRepeats = mapOf("sng_1" to 4),
                    sourcePlaylistId = "pl_src",
                    sourceName = "Apple Music (Local)",
                    sourceSongIds = listOf("sng_1"),
                    sourceSyncEnabled = false,
                    sourceSyncedAt = 1_750_000_000_100.0,
                    lastPlayedAt = 1_750_000_000_200.0,
                    createdAt = 1_750_000_000_000.0,
                    updatedAt = 1_750_000_000_050.0,
                ),
                Pocket(id = "pkt_2", name = "Child"),
            ),
            playlists = listOf(
                Playlist(
                    id = "pls_1",
                    name = "Roadtrip",
                    description = "long drive",
                    sequences = listOf(chapter),
                    targetMs = 3_600_000,
                    folderId = "fld_1",
                    sourcePlaylistId = "pl_src2",
                    sourceName = "My Digital",
                    sourceSongIds = listOf("sng_9"),
                    sourceSyncEnabled = true,
                    sourceSyncedAt = 1_750_000_000_300.0,
                    lastPlayedAt = 1_750_000_000_400.0,
                    createdAt = 1_750_000_000_000.0,
                    updatedAt = 1_750_000_000_001.0,
                ),
            ),
            setlists = listOf(
                Setlist(
                    id = "set_1",
                    playlistId = "pls_1",
                    name = "Roadtrip — take 1",
                    seed = "seed-x",
                    generatedAt = 1_750_000_000_500.0,
                    totalMs = 420_000,
                    tracks = listOf(
                        SetlistTrack(
                            songId = "sng_1",
                            artist = "A",
                            name = "One",
                            bpm = 120.5,
                            camelot = "8A",
                            lengthMs = 210_000,
                            source = TrackSource.POCKET,
                            sequenceName = "Warmup",
                            note = "cue",
                            pocketId = "pkt_1",
                            repeatCount = 2,
                        ),
                        SetlistTrack(name = "mic break", isText = true),
                    ),
                ),
            ),
            folders = listOf(
                PlaylistFolder(id = "fld_1", name = "Gigs", createdAt = 1.0, updatedAt = 2.0),
            ),
            lastAddTarget = AddTarget(AddTarget.Kind.PLAYLIST, "pls_1", sequenceId = "nd_seq1"),
            recentAddTargets = listOf(
                AddTarget(AddTarget.Kind.PLAYLIST, "pls_1", sequenceId = "nd_seq1"),
                AddTarget(AddTarget.Kind.POCKET, "pkt_1"),
            ),
        )
    }

    // MARK: Round trip

    @Test
    fun roundTrip_fullDocument_isLossless() {
        val doc = fullDocument()
        assertEquals(doc, decode(encode(doc)))
    }

    @Test
    fun roundTrip_isByteStable_forKnownShapes() {
        val once = encode(fullDocument())
        assertEquals(once, encode(decode(once)))
    }

    @Test
    fun encode_omitsAbsentOptionals_andWritesIntegralTimestamps() {
        val text = encode(fullDocument().copy(lastAddTarget = null, recentAddTargets = null))
        assertFalse(text.contains("lastAddTarget"))
        assertFalse(text.contains("recentAddTargets"))
        // Never write JSON null for absent optionals (iOS omits nil keys).
        assertFalse(text.contains("null"))
        // Epoch ms as plain numerics, not Kotlin's 1.75E12 exponent form.
        assertTrue(text.contains("1750000000000"))
        assertFalse(text.contains("E12"))
    }

    // MARK: Old documents (additive-optional iron law + identity migrate)

    @Test
    fun decode_oldV3Document_preservesEverything_andStampsVersion7() {
        val old = """
            {
              "schemaVersion": 3,
              "pockets": [
                {"id": "pkt_old", "name": "Old Pocket", "songIds": ["sng_1"],
                 "albumIds": [], "childPocketIds": [], "notes": [],
                 "createdAt": 1700000000000, "updatedAt": 1700000000001}
              ],
              "playlists": [
                {"id": "pls_old", "name": "Old List",
                 "sequences": [{"nodeId": "nd_s", "kind": "sequence", "name": "Default",
                                "children": [{"nodeId": "nd_a", "kind": "song", "songId": "sng_1"}]}],
                 "createdAt": 1700000000000, "updatedAt": 1700000000002}
              ],
              "folders": [{"id": "fld_old", "name": "F", "createdAt": 1, "updatedAt": 2}]
            }
        """.trimIndent()
        val doc = decode(old)
        assertEquals(COLLECTIONS_SCHEMA_VERSION, doc.schemaVersion)
        assertEquals(listOf("sng_1"), doc.pockets.single().songIds)
        // New-in-later-versions fields default without wiping anything.
        assertNull(doc.pockets.single().folderId)
        assertNull(doc.pockets.single().lastPlayedAt)
        assertTrue(doc.pockets.single().songRepeats.isEmpty())
        assertNull(doc.playlists.single().sourcePlaylistId)
        assertEquals("sng_1", doc.playlists.single().sequences[0].children!![0].songId)
        assertEquals(emptyList<Setlist>(), doc.setlists)
        assertNull(doc.lastAddTarget)
        assertNull(doc.recentAddTargets)
    }

    @Test
    fun decode_unknownKeys_areIgnoredEverywhere() {
        val text = """
            {"schemaVersion": 9,
             "someFutureTopLevel": {"x": 1},
             "pockets": [{"id": "pkt_1", "name": "P", "futureField": [1,2,3]}],
             "playlists": [{"id": "pls_1", "name": "L", "futurism": true,
                            "sequences": [], "createdAt": 0, "updatedAt": 0}]}
        """.trimIndent()
        val doc = decode(text)
        assertEquals(9, doc.schemaVersion) // ≥ current: no migrate rewrite
        assertEquals("P", doc.pockets.single().name)
        assertEquals("L", doc.playlists.single().name)
    }

    @Test
    fun decode_missingIds_mintFreshOnes() {
        val doc = decode("""{"pockets": [{"name": "No Id"}], "setlists": [{"playlistId": "pls_1"}]}""")
        assertTrue(doc.pockets.single().id.startsWith("pkt_"))
        assertTrue(doc.setlists.single().id.startsWith("set_"))
        // Missing seed defaults to playlistId (iOS parity).
        assertEquals("pls_1", doc.setlists.single().seed)
    }

    // MARK: Lossy per-element decode (the v5 insurance)

    private fun playlistJson(sequencesJson: String, id: String = "pls_1") = """
        {"id": "$id", "name": "List", "sequences": $sequencesJson,
         "createdAt": 0, "updatedAt": 0}
    """.trimIndent()

    @Test
    fun unknownKind_atChapterSlot_dropsThatElementOnly() {
        val text = """{"playlists": [${playlistJson(
            """[{"nodeId": "nd_bad", "kind": "hologram"},
                {"nodeId": "nd_ok", "kind": "sequence", "name": "Default", "children": []}]""",
        )}]}"""
        val pl = decode(text).playlists.single()
        assertEquals(listOf("nd_ok"), pl.sequences.map { it.nodeId })
    }

    @Test
    fun unknownKind_child_dropsThatChildOnly() {
        val text = """{"playlists": [${playlistJson(
            """[{"nodeId": "nd_s", "kind": "sequence", "children": [
                 {"nodeId": "nd_1", "kind": "song", "songId": "sng_1"},
                 {"nodeId": "nd_2", "kind": "wormhole"},
                 {"nodeId": "nd_3", "kind": "text", "text": "hi"}]}]""",
        )}]}"""
        val children = decode(text).playlists.single().sequences.single().children!!
        assertEquals(listOf("nd_1", "nd_3"), children.map { it.nodeId })
    }

    @Test
    fun unknownKind_grandchild_dropsGrandchildOnly_parentSurvives() {
        val text = """{"playlists": [${playlistJson(
            """[{"nodeId": "nd_s", "kind": "sequence", "children": [
                 {"nodeId": "nd_sub", "kind": "sequence", "name": "Sub", "children": [
                    {"nodeId": "nd_g1", "kind": "song", "songId": "sng_1"},
                    {"nodeId": "nd_g2", "kind": "quasar"}]}]}]""",
        )}]}"""
        val sub = decode(text).playlists.single().sequences.single().children!!.single()
        assertEquals("nd_sub", sub.nodeId)
        assertEquals(listOf("nd_g1"), sub.children!!.map { it.nodeId })
    }

    @Test
    fun undecodablePlaylist_dropsThatPlaylistOnly_neverTheList() {
        val text = """{"playlists": [
            {"id": "pls_broken", "sequences": [], "createdAt": 0, "updatedAt": 0},
            ${playlistJson("[]", id = "pls_ok")}
        ]}"""
        // pls_broken is missing required `name` — it alone drops.
        assertEquals(listOf("pls_ok"), decode(text).playlists.map { it.id })
    }

    @Test
    fun missingRequiredNodeId_dropsTheNode() {
        val text = """{"playlists": [${playlistJson(
            """[{"nodeId": "nd_s", "kind": "sequence", "children": [
                 {"kind": "song", "songId": "sng_1"},
                 {"nodeId": "nd_2", "kind": "song", "songId": "sng_2"}]}]""",
        )}]}"""
        val children = decode(text).playlists.single().sequences.single().children!!
        assertEquals(listOf("nd_2"), children.map { it.nodeId })
    }

    @Test
    fun coercionTrap_unknownKind_neverBecomesAKnownKind() {
        // The PdjJson coerceInputValues trap (spec §4): if PlaylistNode.kind had
        // a default, "hologram" would silently decode as that default and the
        // next save would persist the corruption. It must DROP instead.
        val text = """{"playlists": [${playlistJson(
            """[{"nodeId": "nd_s", "kind": "sequence", "children": [
                 {"nodeId": "nd_x", "kind": "hologram", "songId": "sng_1"}]}]""",
        )}]}"""
        val children = decode(text).playlists.single().sequences.single().children!!
        assertTrue(children.isEmpty())
    }

    @Test
    fun nonArrayPlaylistsValue_yieldsEmptyList_restOfDocumentIntact() {
        val text = """{"playlists": 5, "pockets": [{"id": "pkt_1", "name": "P"}]}"""
        val doc = decode(text)
        assertTrue(doc.playlists.isEmpty())
        assertEquals("P", doc.pockets.single().name)
    }

    @Test
    fun corruptPocketElement_dropsThatPocketOnly() {
        val text = """{"pockets": [
            {"id": "pkt_1", "name": "Good"},
            {"id": "pkt_2", "name": 42, "songIds": "not-an-array"},
            {"id": "pkt_3", "name": "Also Good"}
        ]}"""
        assertEquals(listOf("pkt_1", "pkt_3"), decode(text).pockets.map { it.id })
    }

    @Test
    fun malformedRecentAddTargets_absorbedWithoutWipingDocument() {
        val text = """{"recentAddTargets": [{"kind": "teleporter", "id": "x"}],
                       "pockets": [{"id": "pkt_1", "name": "P"}]}"""
        val doc = decode(text)
        assertNull(doc.recentAddTargets)
        assertEquals(1, doc.pockets.size)
    }

    // MARK: Derived track values (display + player boundaries)

    @Test
    fun setlistTrack_perPlayAndShownMs_followTheConvention() {
        val text = SetlistTrack(songId = "s", artist = "a", name = "n", lengthMs = 60_000, repeatCount = 3)
        assertEquals(60_000L, text.perPlayMs)
        assertEquals(180_000L, text.shownMs)

        val noLength = SetlistTrack(songId = "s", artist = "a", name = "n")
        assertEquals(RealizeEngine.DEFAULT_TRACK_MS, noLength.perPlayMs)

        val cue = SetlistTrack(name = "cue", isText = true, repeatCount = 5)
        assertEquals(0L, cue.perPlayMs)
        assertEquals(0L, cue.shownMs)
    }

    @Test
    fun repeatConvention_normalizeAndStore() {
        assertEquals(1, CollectionMembership.normalizedRepeat(null))
        assertEquals(1, CollectionMembership.normalizedRepeat(0))
        assertEquals(99, CollectionMembership.normalizedRepeat(500))
        assertNull(CollectionMembership.storedRepeat(1))
        assertNull(CollectionMembership.storedRepeat(-3))
        assertEquals(2, CollectionMembership.storedRepeat(2))
        assertEquals(99, CollectionMembership.storedRepeat(1000))
    }

    @Test
    fun unknownTrackSource_coercesToExplicit_notFailure() {
        val text = """{"setlists": [{"id": "set_1", "playlistId": "pls_1",
            "tracks": [{"songId": "s", "artist": "a", "name": "n", "source": "wormhole"}]}]}"""
        val track = decode(text).setlists.single().tracks.single()
        assertEquals(TrackSource.EXPLICIT, track.source)
    }
}
