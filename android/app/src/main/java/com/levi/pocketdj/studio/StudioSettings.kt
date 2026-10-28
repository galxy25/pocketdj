package com.levi.pocketdj.studio

import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.screens.producer.StudioSubTab
import com.levi.pocketdj.studio.store.FileStudioDir
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioRoots
import java.io.File

/** Producer-area preferences (own PrefKey file per decision D3; names are frozen once shipped). */
object StudioSettings {
    /** Last Producer sub-tab (StudioSubTab.rawValue). iOS persists the same raw value. */
    val STUDIO_TAB = PrefKey.string("studioTab", StudioSubTab.Samples.raw)

    /** Last mic input the user picked (AudioDeviceInfo id), -1 = system default. */
    val MIC_INPUT_ID = PrefKey.int("studioMicInputId", -1)
}

/** Writable-File access to the app-managed roots (offline renders/recordings write real files). */
object StudioFiles {
    fun appFile(roots: StudioRoots, family: StudioFamily, name: String): File? {
        if (name.isEmpty() || name.contains('/')) return null
        val dir = (roots.appDir(family) as? FileStudioDir)?.dir ?: return null
        return File(dir, name)
    }
}
