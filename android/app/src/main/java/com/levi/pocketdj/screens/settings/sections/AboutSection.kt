package com.levi.pocketdj.screens.settings.sections

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.screens.settings.AboutRow
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection

/** Public legal pages (Play listing + in-app, Play User Data policy). */
internal object AboutLinks {
    const val PRIVACY_URL = "https://legal.pocket-dj.com/privacy/"
    const val PRIVACY_LABEL = "Privacy policy"
}

internal fun aboutSection() = SettingsSection(SettingsSections.ABOUT, 800) { host ->
    val context = LocalContext.current
    SettingsHeader("About")
    val versionName = remember {
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "?"
    }
    AboutRow("App", "PocketDJ $versionName (Android)")
    AboutRow("Android", "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
    TextButton(
        onClick = {
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(AboutLinks.PRIVACY_URL)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        },
        modifier = Modifier.testTag("about-privacy-policy"),
    ) { Text(AboutLinks.PRIVACY_LABEL) }
    // Endpoint URLs are an advanced detail (Settings ▸ Show advanced).
    if (host.showAdvanced) {
        AboutRow("Catalog", Endpoints.CATALOG_BASE)
        AboutRow("Rips", Endpoints.RIPS_BASE)
        // Which backend (blue/green AWS account) + where it came from — remote endpoints.
        AboutRow("Backend", RemoteEndpoints.summary)
    }
}
