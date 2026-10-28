package com.levi.pocketdj.diag

import android.content.Intent
import android.provider.OpenableColumns
import android.widget.Toast
import com.levi.pocketdj.BuildConfig
import com.levi.pocketdj.data.config.EndpointKey
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.Flushable
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Wires the pure diag classes to the app (one instance per process, built by ServicesGraph). */
class DiagServices private constructor(private val app: AppGraph) {
    val channel: Boolean = BuildConfig.DEBUG || BuildConfig.DIAG_CHANNEL
    val settings = DiagSettings(SharedDiagPrefs(app.appContext))
    val credentials = DiagCredentialStore(app.secrets)
    val capture = CaptureSessions(File(app.appContext.filesDir, "diag-captures"))
    val jank = JankWatchdog({ c, m -> log.log(c, m) })

    val log: DiagLog by lazy {
        val versionCode = BuildConfig.VERSION_CODE
        val now = System.currentTimeMillis()
        DiagLog(
            enabled = channel && settings.diagEnabled,
            credentialStore = credentials,
            settings = settings,
            uploader = OkHttpDiagUploader(app.httpClient, { RemoteEndpoints.url(EndpointKey.DIAG_LOGS_BASE) }),
            scope = app.appScope,
            scheduler = DiagScheduler.system(),
            clock = System::currentTimeMillis,
            keyBase = if (channel) DiagLog.keyBase(settings.installId, now, versionCode) else "release-disabled",
            offReason = if (channel) "turned off in Settings ▸ Debug" else "release build (uploads disabled by design)",
            launchLine = "build=$versionCode name=${BuildConfig.VERSION_NAME} sha=${BuildConfig.GIT_SHA} platform=android device=${if (channel) settings.installId.take(8) else "-"}",
            endpointsLine = "launch ${RemoteEndpoints.summary}",
        ).also {
            it.capture = capture
            it.telemetryEnabled = settings.telemetryEnabled
            DiagLog.shared = it
        }
    }

    /** SVC-10: set by the services graph; fires after a key import/removal so the synced doc materializes + pushes. */
    @Volatile var onKeyImported: (() -> Unit)? = null

    val importer: DiagKeyImporter by lazy {
        DiagKeyImporter(
            store = credentials,
            logsBase = { RemoteEndpoints.url(EndpointKey.DIAG_LOGS_BASE) },
            activeEnv = { RemoteEndpoints.current.env },
            log = { log.log("diag", it) },
            reloadCredentials = { log.reloadCredentials(); onKeyImported?.invoke() },
        )
    }

    /** A key opened from Files that needs the owner's confirmation (shown in Settings ▸ Debug). */
    data class PendingImport(val text: String, val warning: String)
    val pendingImport = kotlinx.coroutines.flow.MutableStateFlow<PendingImport?>(null)

    /** Access key id of the stored key (an id, not a secret), or null. */
    fun keyId(): String? = credentials.load()?.accessKeyId

    /** Materialize the log and hook the process lifecycle (jank watchdog + background flush). */
    fun start() {
        if (!channel) return
        log // materialize off-main (caller launches us on IO); lines for launch/endpoints/status
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                object : androidx.lifecycle.DefaultLifecycleObserver {
                    override fun onStart(owner: androidx.lifecycle.LifecycleOwner) {
                        if (log.isEnabled()) jank.start()
                    }
                    override fun onStop(owner: androidx.lifecycle.LifecycleOwner) {
                        jank.stop()
                        if (log.isEnabled()) log.flushOnBackground()
                    }
                },
            )
        }
    }

    val flushable = Flushable { if (channel) log.flushAndWait() }

    /** Opening a `.pdjdiagkey` from Files: import (or surface the pairing warning in Debug). */
    val deepLink = DeepLinkHandler { intent ->
        val uri = intent.data
        if (!channel || intent.action != Intent.ACTION_VIEW || uri == null) return@DeepLinkHandler false
        val ctx = app.appContext
        val name = runCatching {
            ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        }.getOrNull() ?: uri.lastPathSegment.orEmpty()
        if (!name.endsWith(".${DiagKeyFile.FILE_EXTENSION}", ignoreCase = true)) return@DeepLinkHandler false
        app.appScope.launch(Dispatchers.IO) {
            val text = runCatching { ctx.contentResolver.openInputStream(uri)?.bufferedReader()?.readText() }.getOrNull()
            val msg = if (text == null) "Couldn't read the key file" else when (val o = importer.importText(text)) {
                is DiagKeyImporter.Outcome.Imported -> "Diag key imported (${o.keyId})"
                is DiagKeyImporter.Outcome.NeedsConfirmation -> {
                    pendingImport.value = PendingImport(text, o.mismatch.warning)
                    "Key is for another AWS account — open Settings ▸ Debug to import anyway"
                }
                is DiagKeyImporter.Outcome.Invalid -> "Key rejected: ${o.reason}"
            }
            kotlinx.coroutines.withContext(Dispatchers.Main) { Toast.makeText(ctx, msg, Toast.LENGTH_LONG).show() }
        }
        true
    }

    companion object {
        @Volatile private var instance: DiagServices? = null

        fun get(app: AppGraph): DiagServices =
            instance ?: synchronized(this) { instance ?: DiagServices(app).also { instance = it } }
    }
}
