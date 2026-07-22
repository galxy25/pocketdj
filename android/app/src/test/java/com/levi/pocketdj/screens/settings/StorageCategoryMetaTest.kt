package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.storage.StorageService.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure UI copy behind Settings ▸ Storage (specs/storage.md §2). Compose is
 * not involved, so these are plain JVM assertions that every category has a
 * title/description and that the clearable/display-only split holds at the UI
 * layer (Collections carries no clear affordance, §2.3).
 */
class StorageCategoryMetaTest {

    @Test
    fun everyCategoryHasTitleAndDescription() {
        Category.entries.forEach { category ->
            val meta = storageCategoryMeta(category)
            assertTrue("title for $category", meta.title.isNotBlank())
            assertTrue("description for $category", meta.description.isNotBlank())
        }
    }

    @Test
    fun clearableCategoriesCarryConfirmCopy() {
        Category.entries.filter { it.clearable }.forEach { category ->
            val meta = storageCategoryMeta(category)
            assertTrue("clearTitle for $category", meta.clearTitle.isNotBlank())
            assertTrue("clearBody for $category", meta.clearBody.isNotBlank())
        }
    }

    @Test
    fun collectionsIsDisplayOnlyWithNoConfirmCopy() {
        // Parity-load-bearing (§2.3): the collections doc row is a size only, no
        // Clear — so it carries no confirm copy to render.
        assertEquals(false, Category.COLLECTIONS.clearable)
        val meta = storageCategoryMeta(Category.COLLECTIONS)
        assertEquals("", meta.clearTitle)
        assertEquals("", meta.clearBody)
    }
}
