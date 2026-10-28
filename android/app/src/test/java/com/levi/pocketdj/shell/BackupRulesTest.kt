package com.levi.pocketdj.shell

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** Final review: credential mirrors and big media must stay out of Auto Backup / device transfer. */
class BackupRulesTest {
    private fun excluded(name: String): Set<String> {
        val f = listOf("src/main/res/xml/$name", "app/src/main/res/xml/$name").map(::File).first { it.exists() }
        return Regex("""<exclude[^>]*path="([^"]+)"""").findAll(f.readText()).map { it.groupValues[1] }.toSet()
    }

    @Test fun credentialMirrorsAndMediaExcluded() {
        val must = listOf(
            "pocketdj-settings-credentials.json", "pocketdj-diag-key.json", "pocketdj-rec-key.json",
            "burns", "catalog-cache", "demux-cache", "pocketdj-secrets.xml",
        )
        for (n in listOf("data_extraction_rules.xml", "backup_rules.xml")) {
            val ex = excluded(n)
            for (m in must) assertTrue("$n must exclude $m", m in ex)
        }
    }
}
