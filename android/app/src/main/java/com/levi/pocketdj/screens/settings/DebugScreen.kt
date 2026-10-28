package com.levi.pocketdj.screens.settings

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.BuildConfig
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.diag.DiagKeyImporter
import com.levi.pocketdj.diag.DiagServices
import com.levi.pocketdj.shell.SettingsHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Seam the playback area fills with the dead-air meter summary (placeholder until it ships). */
fun interface DeadAirSource {
    fun summary(): String?

    companion object {
        @Volatile var current: DeadAirSource? = null
    }
}

/** Body of Settings ▸ Debug: build identity, backend, upload status, key import, capture. */
@Composable
internal fun ColumnScope.DebugPanel(host: SettingsHost) {
    val diag = DiagServices.get(host.graph)
    val context = LocalContext.current
    val status by diag.log.uploadStatus.collectAsState()
    val fromFiles by diag.pendingImport.collectAsState()
    val capturing = androidx.compose.runtime.remember { mutableStateOf(diag.capture.active) }
    var sessions by remember { mutableStateOf(diag.capture.sessions()) }
    var keyText by remember { mutableStateOf("") }
    var pendingMismatch by remember { mutableStateOf<String?>(null) }
    var pendingText by remember { mutableStateOf<String?>(null) }
    var enabled by remember { mutableStateOf(diag.log.isEnabled()) }
    var telemetry by remember { mutableStateOf(diag.settings.telemetryEnabled) }
    var keyId by remember { mutableStateOf<String?>(null) }
    androidx.compose.runtime.LaunchedEffect(Unit) { keyId = withContext(Dispatchers.IO) { diag.keyId() } }
    val now = System.currentTimeMillis()

    fun report(outcome: DiagKeyImporter.Outcome) {
        when (outcome) {
            is DiagKeyImporter.Outcome.Imported -> {
                pendingMismatch = null; pendingText = null; keyText = ""; diag.pendingImport.value = null
                host.scope.launch { host.snackbar.showSnackbar("Diag key imported (${outcome.keyId})") }
            }
            is DiagKeyImporter.Outcome.NeedsConfirmation -> {
                pendingMismatch = outcome.mismatch.warning
            }
            is DiagKeyImporter.Outcome.Invalid ->
                host.scope.launch { host.snackbar.showSnackbar("Key rejected: ${outcome.reason}") }
        }
    }

    // A key opened from Files that needed confirmation: surface it here.
    androidx.compose.runtime.LaunchedEffect(fromFiles) {
        fromFiles?.let { pendingText = it.text; pendingMismatch = it.warning }
    }

    fun importNow(text: String, force: Boolean = false) {
        host.scope.launch {
            val outcome = withContext(Dispatchers.IO) { diag.importer.importText(text, force) }
            keyId = withContext(Dispatchers.IO) { diag.keyId() }
            report(outcome)
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) host.scope.launch {
            val text = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.readText() }.getOrNull()
            }
            if (text == null) host.snackbar.showSnackbar("Couldn't read the file") else {
                pendingText = text
                importNow(text)
            }
        }
    }

    SettingsHeader("Debug")
    AboutRow("Version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
    AboutRow("Git", BuildConfig.GIT_SHA)
    AboutRow("Build", if (BuildConfig.DEBUG) "debug" else "release")
    AboutRow("Backend", RemoteEndpoints.summary)
    AboutRow("Logs", RemoteEndpoints.diagBucket)

    SettingsDivider()
    SettingsHeader("Remote diagnostics")
    Text(status.summary(now), style = MaterialTheme.typography.bodyMedium)
    SettingsCaption("Key: ${keyId ?: "none"}")
    ToggleRow("Remote diagnostics", enabled) {
        enabled = it; diag.settings.diagEnabled = it; diag.log.setEnabled(it)
    }
    ToggleRow("Remote telemetry", telemetry) {
        telemetry = it; diag.settings.telemetryEnabled = it; diag.log.telemetryEnabled = it
    }
    SettingsCaption("Telemetry streams every action and screen (with titles) near-live. Owner opt-in; uploads need a key.")

    OutlinedTextField(
        value = keyText, onValueChange = { keyText = it },
        label = { Text("Paste .pdjdiagkey contents") },
        modifier = Modifier.fillMaxWidth(), minLines = 2, maxLines = 4,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(enabled = keyText.isNotBlank(), onClick = { pendingText = keyText; importNow(keyText) }) { Text("Import key") }
        OutlinedButton(onClick = { picker.launch(arrayOf("*/*")) }) { Text("From file…") }
        OutlinedButton(enabled = keyId != null, onClick = { host.scope.launch { keyId = withContext(Dispatchers.IO) { diag.importer.remove(); diag.keyId() } } }) { Text("Remove diag key") }
    }
    pendingMismatch?.let { warn ->
        SettingsCaption(warn)
        Button(onClick = { pendingText?.let { importNow(it, force = true) } }) { Text("Import anyway") }
    }

    SettingsDivider()
    SettingsHeader("Recs")
    var timbreStatus by remember { mutableStateOf("Timbre corpus: not loaded") }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                timbreStatus = "Timbre corpus: loading…"
                val n = withContext(Dispatchers.IO) {
                    com.levi.pocketdj.data.recs.TimbreCatalog(host.graph.catalogService) {
                        "${com.levi.pocketdj.data.config.Endpoints.CATALOG_BASE}/timbre.json"
                    }.vectors().size
                }
                timbreStatus = "Timbre corpus: $n rows"
                diag.log.log("recs", "timbre corpus rows=$n")
            }
        }) { Text("Load timbre corpus") }
        Text(timbreStatus, style = MaterialTheme.typography.bodySmall)
    }

    var editionStatus by remember { mutableStateOf("Edition probe: not run") }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                val pref = com.levi.pocketdj.data.edition.EditionSettings.get(host.graph.settings)
                val song = withContext(Dispatchers.IO) {
                    host.graph.catalogRepository.catalogFlow.first()?.songs
                        ?.firstOrNull { it.appleMusicIdExplicit != null && it.appleMusicIdExplicit != it.appleMusicId }
                }
                val d = com.levi.pocketdj.data.edition.EditionPolicy.decide(song, false, pref)
                editionStatus = "Edition probe: pref=$pref song=${song?.id} base=${song?.appleMusicId} -> ${d.edition?.raw} ${d.catalogId}"
                diag.log.log("recs", editionStatus)
            }
        }) { Text("Edition probe") }
        Text(editionStatus, style = MaterialTheme.typography.bodySmall)
    }

    var seedStatus by remember { mutableStateOf("Seed: idle") }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                val ids = withContext(Dispatchers.IO) {
                    host.graph.catalogRepository.catalogFlow.first()?.songs?.take(500)?.map { it.id } ?: emptyList()
                }
                val store = host.graph.collections
                val pl = store.playlists.firstOrNull { it.name == "Seed500" } ?: store.createPlaylist("Seed500")
                val n = store.addSongs(
                    ids,
                    com.levi.pocketdj.data.collections.AddTarget(com.levi.pocketdj.data.collections.AddTarget.Kind.PLAYLIST, pl.id),
                )
                // Deliberately NO flushNow(): the ON_STOP flush must persist this (COL-2 emulator step).
                seedStatus = "Seed: added $n (no flush)"
            }
        }) { Text("Seed 500 songs") }
        Text(seedStatus, style = MaterialTheme.typography.bodySmall)
    }
    // STU emulator seed: a 2 s 440 Hz mono WAV filed as a Studio sample ("SeedTone").
    var sampleSeedStatus by remember { mutableStateOf("Sample seed: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            sampleSeedStatus = withContext(Dispatchers.IO) {
                runCatching {
                    val rate = 44100; val n = rate * 2
                    val bb = java.nio.ByteBuffer.allocate(44 + n * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    bb.put("RIFF".toByteArray()).putInt(36 + n * 2).put("WAVEfmt ".toByteArray()).putInt(16)
                        .putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
                        .put("data".toByteArray()).putInt(n * 2)
                    for (i in 0 until n) bb.putShort((Math.sin(2 * Math.PI * 440 * i / rate) * 12000).toInt().toShort())
                    val f = java.io.File(host.graph.appContext.cacheDir, "SeedTone.wav").also { it.writeBytes(bb.array()) }
                    val smp = host.graph.studioGraph.sampleFactory.importFile(f, "SeedTone.wav")
                    "Sample seed: ${smp.name} ${smp.durationMs}ms"
                }.getOrElse { "Sample seed failed: $it" }
            }
        }
    }) { Text("Seed sample (tone)") }
    Text(sampleSeedStatus, style = MaterialTheme.typography.bodySmall)

    // STU-11 emulator seed: a Bounce artifact (copy of the seed tone) on the newest arrangement.
    OutlinedButton(onClick = {
        host.scope.launch {
            sampleSeedStatus = withContext(Dispatchers.IO) {
                runCatching {
                    val g = host.graph.studioGraph
                    val arr = g.studioStore.arrangementsOrdered().firstOrNull() ?: error("no arrangement")
                    val src = java.io.File(host.graph.appContext.cacheDir, "SeedTone.wav")
                    check(src.isFile) { "seed the tone sample first" }
                    val fn = "bounce-seed-${System.currentTimeMillis()}.wav"
                    src.copyTo(java.io.File(g.studioRoots.arrangementsDir(), fn))
                    g.studioStore.addArrangementArtifact(
                        com.levi.pocketdj.studio.model.StudioArrangementArtifact(
                            id = com.levi.pocketdj.studio.model.StudioFactory.newArtifactId(), arrangementId = arr.id,
                            kind = com.levi.pocketdj.studio.model.StudioArrangementArtifact.Kind.BOUNCE,
                            name = "Seed bounce", fileName = fn, durationMs = 2000, createdAt = System.currentTimeMillis().toDouble(),
                        ),
                    )
                    "Sample seed: bounce on ${arr.name}"
                }.getOrElse { "Bounce seed failed: $it" }
            }
        }
    }) { Text("Seed bounce artifact") }

    // COL-8 emulator step: 60-song batch into the converted AM pocket "SeedDup" -> confirm dialog (>50).
    OutlinedButton(onClick = {
        host.scope.launch {
            val store = host.graph.collections
            val pocket = store.pockets.firstOrNull { it.name == "SeedDup" }
            val ids = withContext(Dispatchers.IO) {
                val snap = pocket?.sourceSongIds.orEmpty().toSet()
                host.graph.catalogRepository.catalogFlow.first()?.songs
                    ?.filter { !it.appleMusicId.isNullOrBlank() && it.id !in snap && !it.id.startsWith("pdj_") }
                    ?.take(60)?.map { it.id } ?: emptyList()
            }
            if (pocket != null) {
                store.addSongs(ids, com.levi.pocketdj.data.collections.AddTarget(com.levi.pocketdj.data.collections.AddTarget.Kind.POCKET, pocket.id))
                seedStatus = "Seed: batch ${ids.size} -> SeedDup"
            } else seedStatus = "Seed: no SeedDup pocket"
        }
    }) { Text("Seed 60 AM batch") }

    // Wave-4 verify seeds (debug only): a short-rip queue with a metadata-only row between playables.
    var ripStatus by remember { mutableStateOf("Rip seed: idle") }
    var seedIds by remember { mutableStateOf<List<String>>(emptyList()) }
    suspend fun pickSeed(): List<String> = withContext(Dispatchers.IO) {
        val songs = host.graph.catalogRepository.catalogFlow.first()?.songs ?: emptyList()
        val manifest = host.graph.ripsRepository.manifest.value
        val ripped = songs.filter { s ->
            val e = manifest[s.id]
            e != null && e.source == "digital" && (e.durationMs ?: Long.MAX_VALUE) in 20_000L..90_000L
        }.sortedBy { manifest[it.id]?.durationMs }.take(12)
        val meta = songs.firstOrNull { manifest[it.id] == null }
        val ids = ripped.map { it.id }.toMutableList()
        if (meta != null && ids.size >= 2) ids.add(1, meta.id)
        ids
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                val ids = pickSeed(); seedIds = ids
                val store = host.graph.collections
                val pl = store.playlists.firstOrNull { it.name == "SeedRip" } ?: store.createPlaylist("SeedRip")
                store.addSongs(ids, com.levi.pocketdj.data.collections.AddTarget(com.levi.pocketdj.data.collections.AddTarget.Kind.PLAYLIST, pl.id))
                ripStatus = "Rip seed: ${ids.size} ids ${ids.joinToString(",")}"
                android.util.Log.d("PdjVerify", ripStatus)
            }
        }) { Text("Seed rip playlist") }
        OutlinedButton(onClick = {
            host.scope.launch {
                val ids = seedIds.ifEmpty { pickSeed().also { seedIds = it } }
                val out = host.graph.playbackController.playQueue(ids.map { com.levi.pocketdj.playback.QueuePlan.QueueEntry(it) })
                ripStatus = "Rip seed: play -> $out"
            }
        }) { Text("Play seed queue") }
        OutlinedButton(onClick = {
            host.scope.launch {
                val ids = seedIds.ifEmpty { pickSeed().also { seedIds = it } }
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val r = host.graph.servicesGraph.burnStore.burn(ids.take(3).map { com.levi.pocketdj.data.burns.BurnSong(it, songs[it]?.name ?: it, songs[it]?.artist ?: "") })
                ripStatus = "Rip seed: burn -> $r"
                android.util.Log.d("PdjVerify", ripStatus)
            }
        }) { Text("Burn first 3") }
    }
    Row { OutlinedButton(onClick = {
            host.scope.launch {
                val ids = seedIds.ifEmpty { pickSeed().also { seedIds = it } }
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val r = host.graph.servicesGraph.burnStore.burn(ids.take(10).map { com.levi.pocketdj.data.burns.BurnSong(it, songs[it]?.name ?: it, songs[it]?.artist ?: "") })
                ripStatus = "Rip seed: burn10 -> $r"
            }
        }) { Text("Burn 10") } }
    // SVC-3 verify seeds: the 5 LONGEST ripped digital songs (bigger files so a force-stop can land mid-download).
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        fun burn5(bad: Boolean) {
            host.scope.launch {
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val manifest = host.graph.ripsRepository.manifest.value
                val ids = songs.keys.filter { manifest[it]?.source == "digital" }
                    .sortedByDescending { manifest[it]?.durationMs ?: 0L }.take(5)
                val store = host.graph.servicesGraph.burnStore
                android.util.Log.d("PdjVerify", "burn5 start bad=$bad ids=$ids")
                ripStatus = "Rip seed: burn5 running ${ids.size}"
                withContext(Dispatchers.IO) { store.removeBurns(ids) }
                store.debugUrlTransform = if (bad) { u -> u + "?X-Amz-Algorithm=BAD&X-Amz-Credential=x&X-Amz-Date=x&X-Amz-Expires=x&X-Amz-SignedHeaders=host&X-Amz-Signature=x" } else null
                val r = store.burn(ids.map { com.levi.pocketdj.data.burns.BurnSong(it, songs[it]?.name ?: it, songs[it]?.artist ?: "") })
                store.debugUrlTransform = null
                ripStatus = "Rip seed: burn5 bad=$bad -> $r"
                android.util.Log.d("PdjVerify", ripStatus)
            }
        }
        OutlinedButton(onClick = {
            // MIX-6: stream the 6th-longest ripped digital song (NOT burned) through MixStreamLoader and poll it.
            host.scope.launch {
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val manifest = host.graph.ripsRepository.manifest.value
                val store = host.graph.servicesGraph.burnStore
                val id = songs.keys.filter { manifest[it]?.source == "digital" && !store.hasLocalFile(it) }
                    .sortedByDescending { manifest[it]?.durationMs ?: 0L }.firstOrNull()
                if (id == null) { ripStatus = "Mix stream: no candidate"; return@launch }
                com.levi.pocketdj.di.MixDebug.publicRips = true
                val loader = host.graph.mixGraph.mixStreamLoader
                val s = loader.open(id, songs[id]?.name ?: id, songs[id]?.artist ?: "")
                android.util.Log.d("PdjVerify", "mixstream debug open $id can=${loader.canStream(id)} stream=${s != null}")
                repeat(40) {
                    kotlinx.coroutines.delay(1000)
                    val st = loader.stream(id)
                    android.util.Log.d("PdjVerify", "mixstream poll $id bytes=${st?.bytesReceived} expected=${st?.expectedBytes} complete=${st?.isComplete} failed=${st?.failed} adopted=${st?.adopted} burned=${store.hasLocalFile(id)}")
                    ripStatus = "Mix stream $id bytes=${st?.bytesReceived} burned=${store.hasLocalFile(id)}"
                    if (st == null || st.isComplete || st.failed) return@launch
                }
            }
        }) { Text("Mix stream open") }
        OutlinedButton(onClick = { burn5(false) }) { Text("Burn 5 long") }
        OutlinedButton(onClick = { burn5(true) }) { Text("Burn 5 (HTTP 400)") }
    }
    Text(ripStatus, style = MaterialTheme.typography.bodySmall)

    // MIX-5 verify seeds (debug only): drive the MixEngine until the Mix screen (MIX-14) owns it.
    var mixStatus by remember { mutableStateOf("Mix: idle") }
    var showDeckHarness by remember { mutableStateOf(false) }
    fun mixLine(): String {
        val e = host.graph.mixGraph.mixEngine
        return com.levi.pocketdj.mix.model.Deck.entries.joinToString(" | ") { d ->
            "${d.label}:${e.loaded(d)?.songId?.takeLast(4) ?: "-"} play=${e.isPlaying(d)} pos=${"%.1f".format(e.position(d))}/${"%.1f".format(e.duration(d))} rate=${e.rate(d)} vol=${e.volume(d)}"
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                val e = host.graph.mixGraph.mixEngine
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val burned = host.graph.servicesGraph.burnStore.items.value.values.take(2)
                burned.forEachIndexed { i, b ->
                    val song = songs[b.songId]
                    e.load(
                        com.levi.pocketdj.mix.model.MixLoadable(b.songId, b.title, b.artist, b.bpm, b.camelot, b.musicalKey, song?.albumId, b.durationMs?.toInt()),
                        if (i == 0) com.levi.pocketdj.mix.model.Deck.A else com.levi.pocketdj.mix.model.Deck.B,
                    )
                }
                kotlinx.coroutines.delay(2000) // loads commit off-main
                e.playBoth()
                mixStatus = "Mix load: ${mixLine()}"
            }
        }) { Text("Mix: load 2 + play") }
        OutlinedButton(onClick = {
            val e = host.graph.mixGraph.mixEngine
            val A = com.levi.pocketdj.mix.model.Deck.A; val B = com.levi.pocketdj.mix.model.Deck.B
            e.setRate(1.05, A); e.setPitch(1.0, A); e.setVolume(0.8, A); e.setRate(0.97, B); e.setVolume(0.9, B); e.setCrossfader(0.3)
            mixStatus = "Mix twist: ${mixLine()}"
        }) { Text("Mix: twist") }
        OutlinedButton(onClick = { showDeckHarness = true }) { Text("Mix: deck UI") }
    }
    if (showDeckHarness) com.levi.pocketdj.screens.mix.DebugDeckHarness(host.graph) { showDeckHarness = false }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { mixStatus = "Mix status: ${mixLine()}" }) { Text("Mix: status") }
        OutlinedButton(onClick = {
            val e = host.graph.mixGraph.mixEngine
            e.restorePersistedMixIfIdle(); e.materializePendingRestoreIfNeeded("debug")
            mixStatus = "Mix restore: ${mixLine()}"
        }) { Text("Mix: restore") }
        OutlinedButton(onClick = {
            val f = com.levi.pocketdj.mix.service.MixDiag.export(
                java.io.File(host.graph.appContext.cacheDir, "diag"), mixLine(),
            )
            mixStatus = "Mix diag exported: ${f.absolutePath}"
        }) { Text("Mix: export diag") }
    }
    Text(mixStatus, style = MaterialTheme.typography.bodySmall)

    // MIX-9 verify probes (debug only): Auto-DJ over the burned songs until the Mix screen owns it.
    var autoStatus by remember { mutableStateOf("AutoDJ: idle") }
    fun autoLine(): String {
        val dj = host.graph.mixGraph.autoDj
        val u = dj.ui.value
        return "AutoDJ mixing=${u.mixing} paused=${u.paused} trans=${u.transitioning} pos=${u.livePos}/${u.queueSize} deck=${u.liveDeck.label} status=${u.status} buf=${host.graph.mixGraph.mixStreamDecks.buffering.value.map { it.label }} strm=${host.graph.mixGraph.mixStreamDecks.streaming.value.map { it.label }} | ${mixLine()}"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch {
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val items = host.graph.servicesGraph.burnStore.items.value.values.filter { host.graph.servicesGraph.burnStore.hasLocalFile(it.songId) }.take(5).map { b ->
                    val song = songs[b.songId]
                    com.levi.pocketdj.mix.model.AutoMixItem(
                        com.levi.pocketdj.mix.model.MixLoadable(b.songId, b.title, b.artist, b.bpm, b.camelot, b.musicalKey, song?.albumId, b.durationMs?.toInt()),
                        b.durationMs?.toInt() ?: 30000,
                        "SeedBurns",
                    )
                }
                host.graph.mixGraph.autoDj.startAutoMix(items, false, 5.0, 3.0, "SeedBurns")
                kotlinx.coroutines.delay(2500)
                autoStatus = autoLine()
            }
        }) { Text("AutoDJ: start") }
        OutlinedButton(onClick = { host.graph.mixGraph.autoDj.skipToNext(2.0); autoStatus = autoLine() }) { Text("AutoDJ: skip") }
        OutlinedButton(onClick = {
            // MIX-10: Auto-DJ over three ripped-but-NOT-burned digital songs (STREAMING MODE).
            host.scope.launch {
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs?.associateBy { it.id } ?: emptyMap()
                val manifest = host.graph.ripsRepository.manifest.value
                val store = host.graph.servicesGraph.burnStore
                com.levi.pocketdj.di.MixDebug.publicRips = true
                val ids = songs.keys.filter { manifest[it]?.source == "digital" && !store.hasLocalFile(it) }
                    .sortedByDescending { manifest[it]?.durationMs ?: 0L }.take(3)
                val items = ids.map { id ->
                    val sg = songs[id]
                    com.levi.pocketdj.mix.model.AutoMixItem(
                        com.levi.pocketdj.mix.model.MixLoadable(id, sg?.name ?: id, sg?.artist ?: "", null, null, null, sg?.albumId, manifest[id]?.durationMs?.toInt()),
                        manifest[id]?.durationMs?.toInt() ?: 200000,
                        "SeedStream",
                    )
                }
                host.graph.mixGraph.autoDj.startAutoMix(items, true, 5.0, 3.0, "SeedStream")
                autoStatus = "AutoDJ stream start ids=${ids.size}"
            }
        }) { Text("AutoDJ: start streamed") }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { host.graph.mixGraph.autoDj.pauseAuto(); autoStatus = autoLine() }) { Text("AutoDJ: pause") }
        OutlinedButton(onClick = { host.graph.mixGraph.autoDj.resumeAuto(); autoStatus = autoLine() }) { Text("AutoDJ: resume") }
        OutlinedButton(onClick = { autoStatus = autoLine() }) { Text("AutoDJ: status") }
    }
    Text(autoStatus, style = MaterialTheme.typography.bodySmall)

    // GM-7 verify probes (debug only): the In the Pocket game screen (GAMES-8) has no UI yet.
    var pocketStatus by remember { mutableStateOf("Pocket: idle") }
    fun pocketLine(): String {
        val st = host.graph.gamesGraph.inThePocket.state.value
        val c = st.current
        return "Pocket bridge=${host.graph.gamesGraph.pocketsBridge.isEnabled.value} build=${st.buildState} songs=${c?.songs?.size} idx=${st.currentSongIndex} outcome=${c?.outcome?.token} states=${c?.songs?.joinToString(",") { it.state.name }} runs=${host.graph.gamesGraph.scoreboard.let { sb -> sb.inThePocketStats() }}"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            host.scope.launch { host.graph.gamesGraph.inThePocket.buildRound(); host.graph.gamesGraph.inThePocket.start(); pocketStatus = pocketLine() }
        }) { Text("Pocket: build+start") }
        OutlinedButton(onClick = { pocketStatus = pocketLine() }) { Text("Pocket: status") }
        OutlinedButton(onClick = { host.graph.gamesGraph.inThePocket.endActiveRound(); pocketStatus = pocketLine() }) { Text("Pocket: end") }
    }
    Text(pocketStatus, style = MaterialTheme.typography.bodySmall)

    // BRW-10 verify probe (debug only): In Da Zone has no renderer yet (REC-5); log the queue it would build.
    var zoneStatus by remember { mutableStateOf("Zone: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val songs = host.graph.catalogRepository.catalogFlow.first()?.songs.orEmpty()
            val hist = com.levi.pocketdj.data.history.PlayHistoryStore.get(host.graph.appContext)
            val t0 = System.currentTimeMillis()
            val q = withContext(Dispatchers.Default) {
                com.levi.pocketdj.data.recs.ZoneEngine.inDaZone(
                    songs = songs,
                    plays = hist.events.map { com.levi.pocketdj.data.recs.ZoneEngine.Play(it.songId, it.playedAt) },
                    playCount = { hist.playCount(it) },
                    nowMs = System.currentTimeMillis().toDouble(),
                )
            }
            zoneStatus = "Zone: songs=${songs.size} queue=${q.count} familiar=${q.count(com.levi.pocketdj.data.recs.ZoneEngine.Pool.FAMILIAR)} buried(rediscovery)=${q.count(com.levi.pocketdj.data.recs.ZoneEngine.Pool.REDISCOVERY)} in ${System.currentTimeMillis() - t0}ms"
            com.levi.pocketdj.diag.NPLog.lane("zone", zoneStatus)
        }
    }) { Text("Zone: rank now") }
    Text(zoneStatus, style = MaterialTheme.typography.bodySmall)

    // GM-3 verify probes (debug only): the Gem Collector round engine has no screen yet.
    var gemStatus by remember { mutableStateOf("Gem: idle") }
    fun gemLine(): String {
        val st = host.graph.gamesGraph.puzzleEngine.state.value
        return "Gem phase=${st.phase} cd=${st.countdown} q=${st.queueIndex}/${st.queue.size} score=${st.score} cur=${st.current?.name} err=${st.lastError} exhausted=${st.poolExhausted}"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { host.graph.gamesGraph.puzzleEngine.startRoundDetached(); gemStatus = "Gem: starting" }) { Text("Gem: start") }
        OutlinedButton(onClick = { host.graph.gamesGraph.puzzleEngine.skip(); gemStatus = gemLine() }) { Text("Gem: skip") }
        OutlinedButton(onClick = { gemStatus = gemLine() }) { Text("Gem: status") }
        OutlinedButton(onClick = { host.graph.gamesGraph.puzzleEngine.endRound(); gemStatus = gemLine() }) { Text("Gem: end") }
    }
    Text(gemStatus, style = MaterialTheme.typography.bodySmall)

    // SVC-15 verify probe (debug only): catalog search (dev token) + a user-scoped call (NeedsUserToken when signed out).
    var amStatus by remember { mutableStateOf("AM API: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val api = host.graph.appleMusicApi
            val cat = withContext(Dispatchers.IO) { runCatching { api.searchCatalog("daft punk") }.getOrElse { com.levi.pocketdj.data.applemusic.AmResult.Failure(null, it.message ?: "err") } }
            val lib = withContext(Dispatchers.IO) { runCatching { api.libraryPlaylists() }.getOrElse { com.levi.pocketdj.data.applemusic.AmResult.Failure(null, it.message ?: "err") } }
            amStatus = "AM API: catalog=${cat::class.simpleName} library=${lib::class.simpleName}"
            android.util.Log.d("PdjVerify", amStatus + " " + (cat as? com.levi.pocketdj.data.applemusic.AmResult.Failure)?.message)
        }
    }) { Text("AM API probe") }
    Text(amStatus, style = MaterialTheme.typography.bodySmall)

    // GM-9 verify probe (debug only): live broker smoke for Music with Friends (create, refresh, suggest, end).
    var mwfStatus by remember { mutableStateOf("MwF: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val f = host.graph.gamesGraph.friends
            val err = f.create("Wave12 MwF", "Test theme", "Wave12", com.levi.pocketdj.data.games.friends.MwFSettings())
            val id = f.sessions.value.firstOrNull()?.id
            if (err != null || id == null) { mwfStatus = "MwF: create failed: $err"; android.util.Log.d("PdjVerify", mwfStatus); return@launch }
            val st = f.refresh(id)
            val sErr = runCatching { f.suggest(id, "Test Song", "Test Artist") }.exceptionOrNull()?.message
            val st2 = f.refresh(id)
            f.endSession(id)
            mwfStatus = "MwF: id=$id members=${st?.members?.size} suggestions=${st2?.suggestions?.size} suggestErr=$sErr ended=${f.entry(id) == null || f.lastState.value[id]?.ended == true} pollErr=${f.pollErrors.value[id]}"
            android.util.Log.d("PdjVerify", mwfStatus)
        }
    }) { Text("MwF: live smoke") }
    Text(mwfStatus, style = MaterialTheme.typography.bodySmall)

    // SURF-8 verify probe (debug only): a real media3 MediaBrowser against PlaybackService (what Android
    // Auto does), walking root -> tabs -> collections -> songs, logging every level to tag PdjVerify.
    var autoBrowseStatus by remember { mutableStateOf("Auto browse: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val ctx = host.graph.appContext
            val token = androidx.media3.session.SessionToken(ctx, android.content.ComponentName(ctx, com.levi.pocketdj.playback.PlaybackService::class.java))
            suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.await(): T =
                kotlinx.coroutines.suspendCancellableCoroutine { c ->
                    addListener({ runCatching { get() }.fold({ c.resumeWith(Result.success(it)) }, { c.resumeWith(Result.failure(it)) }) }, Runnable::run)
                }
            val out = StringBuilder()
            fun log(m: String) { out.appendLine(m); android.util.Log.d("PdjVerify", "auto: $m") }
            runCatching {
                val b = androidx.media3.session.MediaBrowser.Builder(ctx, token).buildAsync().await()
                val rr = b.getLibraryRoot(null).await(); log("rootResult code=${rr.resultCode}")
                val root = rr.value!!
                log("root=${root.mediaId}")
                val tabs = b.getChildren(root.mediaId, 0, 50, null).await().value.orEmpty()
                tabs.forEach { log("tab ${it.mediaId} '${it.mediaMetadata.title}' browsable=${it.mediaMetadata.isBrowsable} playable=${it.mediaMetadata.isPlayable}") }
                for (t in tabs.filter { it.mediaMetadata.isBrowsable == true }) {
                    val cols = b.getChildren(t.mediaId, 0, 50, null).await().value.orEmpty()
                    log("  ${t.mediaMetadata.title}: ${cols.size} children")
                    cols.take(3).forEach { c ->
                        log("    col ${c.mediaId} '${c.mediaMetadata.title}' sub='${c.mediaMetadata.subtitle}'")
                        if (c.mediaMetadata.isBrowsable == true) {
                            val songs = b.getChildren(c.mediaId, 0, 10, null).await().value.orEmpty()
                            songs.take(4).forEach { sg -> log("      ${sg.mediaId} '${sg.mediaMetadata.title}' playable=${sg.mediaMetadata.isPlayable} sub='${sg.mediaMetadata.subtitle}' art=${sg.mediaMetadata.artworkUri}") }
                        }
                    }
                }
                b.search("Intro", null).await()
                val sr = b.getSearchResult("Intro", 0, 10, null).await().value.orEmpty()
                log("search Intro -> ${sr.size}: ${sr.take(3).map { it.mediaMetadata.title }}")
                // Select the first playable song of the first playlist the way Auto does (setMediaItem by id).
                val pl = b.getChildren("tab:playlists", 0, 5, null).await().value.orEmpty().first { it.mediaMetadata.title == "SeedRip" }
                val song = b.getChildren(pl.mediaId, 0, 10, null).await().value.orEmpty().first { it.mediaId.startsWith("song:") && it.mediaMetadata.isPlayable == true }
                b.setMediaItem(song); b.prepare(); b.play()
                kotlinx.coroutines.delay(4000)
                log("play ${song.mediaId} -> state=${b.playbackState} isPlaying=${b.isPlaying} queue=${b.mediaItemCount} pos=${b.currentPosition} err=${b.playerError?.message}")
                val addRes = b.sendCustomCommand(
                    androidx.media3.session.SessionCommand(com.levi.pocketdj.auto.AutoLibraryCallback.ACTION_ADD_TO, android.os.Bundle.EMPTY),
                    android.os.Bundle().apply { putString(androidx.media3.session.MediaConstants.EXTRA_KEY_MEDIA_ID, song.mediaId) },
                ).await()
                val chooser = addRes.extras.getString(com.levi.pocketdj.auto.AutoLibraryCallback.KEY_RESULT_BROWSE_NODE)
                log("addTo result=${addRes.resultCode} chooser=$chooser")
                if (chooser != null) {
                    b.getChildren(chooser, 0, 20, null).await().value.orEmpty().take(8).forEach { log("  chooser ${it.mediaId} '${it.mediaMetadata.title}' playable=${it.mediaMetadata.isPlayable}") }
                }
                b.pause(); b.release()
            }.onFailure { log("FAILED ${it::class.simpleName}: ${it.message} ${android.util.Log.getStackTraceString(it).take(600)}") }
            autoBrowseStatus = out.toString().take(1500)
        }
    }) { Text("Auto browse smoke") }
    Text(autoBrowseStatus, style = MaterialTheme.typography.bodySmall)

    // MIX-7 verify probe (debug only): begin the app-scoped collection download for the SeedRip playlist.
    var mdlStatus by remember { mutableStateOf("Mix dl: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val pl = host.graph.collections.playlists.firstOrNull { it.name == "SeedRip" }
            if (pl == null) { mdlStatus = "Mix dl: no SeedRip playlist"; return@launch }
            val d = host.graph.mixGraph.collectionMixDownloader
            d.begin(com.levi.pocketdj.mix.model.MixSource.Playlist(pl.id))
            kotlinx.coroutines.delay(3000)
            val st = d.state.value
            mdlStatus = "Mix dl: ${st.downloadedCount} of ${st.totalCount} downloaded ripping=${st.rippingCount} eta=${st.etaSeconds} active=${st.isActive}"
            android.util.Log.d("PdjVerify", mdlStatus)
        }
    }) { Text("Mix download SeedRip") }
    Text(mdlStatus, style = MaterialTheme.typography.bodySmall)

    // COL-3 verify seed (debug only): a pocket holding one catalog twin pair (same artist/title/album, two ids).
    var dupStatus by remember { mutableStateOf("Dup seed: idle") }
    OutlinedButton(onClick = {
        host.scope.launch {
            val pair = withContext(Dispatchers.IO) {
                val songs = host.graph.catalogRepository.catalogFlow.first()?.songs ?: emptyList()
                songs.groupBy { Triple(it.artist.lowercase(), it.name.lowercase(), it.albumId) }
                    .values.firstOrNull { g -> g.size >= 2 && g.map { it.id }.distinct().size >= 2 }?.take(2)?.map { it.id }
            }
            dupStatus = if (pair == null) "Dup seed: no twin pair in catalog" else {
                host.graph.collections.createPocket("SeedDup", pair)
                "Dup seed: pocket SeedDup with ${pair.joinToString(",")}"
            }
        }
    }) { Text("Seed duplicate pocket") }
    Text(dupStatus, style = MaterialTheme.typography.bodySmall)

    SettingsDivider()
    SettingsHeader("Capture")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = {
            if (capturing.value) { diag.capture.stop(); sessions = diag.capture.sessions() } else diag.capture.start()
            capturing.value = diag.capture.active
        }) { Text(if (capturing.value) "Capture off" else "Capture on") }
        Text(if (capturing.value) "Recording…" else "${sessions.size} saved session(s)", style = MaterialTheme.typography.bodySmall)
    }
    sessions.forEach { f ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(f.name, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = {
                // Stream the file via FileProvider: EXTRA_TEXT would blow the Binder limit on big captures.
                val uri = runCatching {
                    androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", f)
                }.getOrNull()
                if (uri == null) host.scope.launch { host.snackbar.showSnackbar("Couldn't share the capture") } else {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"; putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(Intent.createChooser(send, "Share capture").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
            }) { Text("Share") }
            OutlinedButton(onClick = { diag.capture.delete(f); sessions = diag.capture.sessions() }) { Text("Delete") }
        }
    }

    SettingsDivider()
    SettingsHeader("Dead air")
    SettingsCaption(DeadAirSource.current?.summary() ?: "Dead-air meter not available yet (ships with the playback area).")
}

@Composable
private fun ToggleRow(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onChange)
    }
}
