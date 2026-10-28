package com.levi.pocketdj.screens.settings.sections

import android.os.Build
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.screens.settings.AboutRow
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection

internal fun aboutSection() = SettingsSection(SettingsSections.ABOUT, 800) { _ ->
    val context = LocalContext.current
    SettingsHeader("About")
    val versionName = remember {
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "?"
    }
    AboutRow("App", "PocketDJ $versionName (Android)")
    AboutRow("Android", "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
    AboutRow("Catalog", Endpoints.CATALOG_BASE)
    AboutRow("Rips", Endpoints.RIPS_BASE)
    // Which backend (blue/green AWS account) + where it came from — remote endpoints.
    AboutRow("Backend", RemoteEndpoints.summary)
}
