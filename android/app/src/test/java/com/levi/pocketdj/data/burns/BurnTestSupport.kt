package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.data.rips.RipStems
import java.io.File
import java.io.IOException
import java.nio.file.Files

const val BASE = "https://rips.example"

fun tmpDir(): File = Files.createTempDirectory("pdj-burn").toFile()

fun song(id: String, artist: String = "Artist", name: String = "Song $id", albumId: String? = null, bpm: Double? = null) =
    IndexSong(id = id, artist = artist, name = name, albumId = albumId, bpm = bpm, year = 1999)

fun album(id: String, artist: String = "Artist", name: String = "Album", genre: String? = "Rock") =
    IndexAlbum(id = id, artist = artist, name = name, genre = genre, year = 1999)

fun digital(id: String, bpm: Double? = 120.0, camelot: String? = "8A", key: String? = "A minor", rippedAt: Double? = null) =
    RipManifestEntry(key = "rips/$id.mp3", source = "digital", bpm = bpm, camelot = camelot, musicalKey = key, rippedAt = rippedAt)

fun analog(albumId: String, startMs: Long, rippedAt: Double? = null, cutKey: String? = null) =
    RipManifestEntry(key = "rips/$albumId.mp3", source = "analog", startMs = startMs, rippedAt = rippedAt, cutKey = cutKey)

/** Scriptable in-memory [BurnRips]: every URL is `BASE/<key>`; bytes come from [bodies]. */
class FakeBurnRips : BurnRips {
    val entries = HashMap<String, RipManifestEntry>()
    val bodies = HashMap<String, ByteArray>()
    val downloads = ArrayList<String>()
    val lastModified = HashMap<String, Double>()
    var server = true
    var presignFails = false
    var onDownload: (String) -> Unit = {}
    var failWith: (String) -> Throwable? = { null }

    override suspend fun hasServer() = server
    override fun entry(songId: String) = entries[songId]
    override suspend fun durableUrl(songId: String): String? {
        if (presignFails) return null
        return entries[songId]?.let { urlForKey(it.key) }
    }
    override fun stemUrls(songId: String) = entries[songId]?.stemUrls(BASE)
    override fun beatgridUrl(songId: String) = entries[songId]?.beatgridUrl(BASE)
    override fun urlForKey(key: String) = "$BASE/${key.removePrefix("/")}"

    override suspend fun download(url: String, dest: File): Long {
        downloads += url
        onDownload(url)
        failWith(url)?.let { throw it }
        val body = bodies[url] ?: throw IOException("HTTP 404")
        dest.parentFile?.mkdirs()
        dest.writeBytes(body)
        return body.size.toLong()
    }

    override suspend fun downloadBytes(url: String): ByteArray {
        downloads += url
        failWith(url)?.let { throw it }
        return bodies[url] ?: throw IOException("HTTP 404")
    }

    override suspend fun lastModifiedMs(url: String) = lastModified[url]

    fun serve(key: String, size: Int = 8_192, fill: Byte = 7) {
        bodies[urlForKey(key)] = ByteArray(size) { fill }
    }
}

class Rig(
    val dir: File = tmpDir(),
    val rips: FakeBurnRips = FakeBurnRips(),
    val catalog: HashMap<String, Pair<IndexSong?, IndexAlbum?>> = HashMap(),
    var nowMs: Long = 1_000_000L,
) {
    val burns = File(dir, "burns")
    val ledger = File(dir, "pocketdj-burns.json")
    val folder = AppPrivateBurnFolder(burns)

    fun store() = BurnStore(ledger, folder, rips, lookup = { catalog[it] ?: (null to null) }, clock = { nowMs })
    fun names(): List<String> = burns.list()?.sorted() ?: emptyList()
}

fun bs(id: String, title: String = "T$id", artist: String = "Artist") = BurnSong(id, title, artist)
