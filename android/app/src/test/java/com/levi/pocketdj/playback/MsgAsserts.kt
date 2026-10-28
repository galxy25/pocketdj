package com.levi.pocketdj.playback

import org.junit.Assert

/** kotlin.test-style (value first, message last) assertions over JUnit4. */
internal fun assertTrue(cond: Boolean, msg: String? = null) = Assert.assertTrue(msg, cond)
internal fun assertFalse(cond: Boolean, msg: String? = null) = Assert.assertFalse(msg, cond)
internal fun <T> assertEquals(expected: T, actual: T, msg: String? = null) = Assert.assertEquals(msg, expected, actual)
internal fun assertNull(actual: Any?, msg: String? = null) = Assert.assertNull(msg, actual)
internal fun assertNotNull(actual: Any?, msg: String? = null) = Assert.assertNotNull(msg, actual)
