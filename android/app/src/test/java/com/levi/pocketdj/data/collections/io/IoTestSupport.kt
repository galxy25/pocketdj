package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog

internal object IoTestSupport {
    fun resource(path: String): ByteArray =
        IoTestSupport::class.java.classLoader!!.getResourceAsStream(path)!!.use { it.readBytes() }

    fun catalog(songs: List<IndexSong>, albums: List<IndexAlbum> = emptyList()): MergedCatalog =
        MergedCatalog.merge(listOf(IndexJson(manifest = IndexManifest(sourceName = "Test"), albums = albums, songs = songs)))

    fun json(bytes: ByteArray): kotlinx.serialization.json.JsonElement =
        kotlinx.serialization.json.Json.parseToJsonElement(String(bytes, Charsets.UTF_8))
}
