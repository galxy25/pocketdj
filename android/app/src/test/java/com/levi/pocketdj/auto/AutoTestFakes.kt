package com.levi.pocketdj.auto

internal class FakeAutoData(
    override var catalogReady: Boolean = true,
    var playlists: List<AutoCollectionInfo> = emptyList(),
    var sources: List<AutoCollectionInfo> = emptyList(),
    var pockets: List<AutoCollectionInfo> = emptyList(),
    var songs: Map<String, AutoSongInfo> = emptyMap(),
    var songIdsByRef: Map<AutoCollectionRef, List<String>> = emptyMap(),
    var held: AutoHeld? = null,
) : AutoLibraryData {
    var heldReads = 0
    override fun playlists() = playlists
    override fun sourcePlaylists() = sources
    override fun pockets() = pockets
    override fun collection(ref: AutoCollectionRef) = (playlists + sources + pockets).firstOrNull { it.ref == ref }
    override fun songIds(ref: AutoCollectionRef) = songIdsByRef[ref].orEmpty()
    override fun song(id: String) = songs[id]
    override fun searchSongs(query: String, limit: Int) =
        songs.values.filter { it.title.contains(query, ignoreCase = true) }.take(limit)
    override fun held(): AutoHeld? { heldReads++; return held }
}

internal fun mkSong(id: String, playable: Boolean = true, artist: String = "Artist") =
    AutoSongInfo(id, "Song $id", artist, artUrl = "https://art/$id.jpg", playable = playable)

internal fun plRef(id: String) = AutoCollectionRef(AutoCollectionKind.PLAYLIST, id)
internal fun pkRef(id: String) = AutoCollectionRef(AutoCollectionKind.POCKET, id)
internal fun srcRef(id: String, source: String) = AutoCollectionRef(AutoCollectionKind.SOURCE, id, source)
