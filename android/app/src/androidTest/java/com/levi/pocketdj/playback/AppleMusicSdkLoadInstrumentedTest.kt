package com.levi.pocketdj.playback

import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.apple.android.music.playback.controller.MediaPlayerController
import com.apple.android.music.playback.controller.MediaPlayerControllerFactory
import com.apple.android.music.playback.model.MediaItemType
import com.apple.android.music.playback.queue.CatalogPlaybackQueueItemProvider
import com.apple.android.sdk.authentication.TokenProvider
import org.junit.Assert.assertNotNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Play Console 16 KB check: libappleMusicSDK.so (Apple MusicKit for Android mediaplayback 1.1.1)
 * was built with NDK r19b. Its LOAD segments are 64 KB-aligned, so it should map on a 16 KB-page
 * kernel; this proves it on a device (run on a `*_ps16k` arm64 AVD): the factory loads the JavaCPP
 * natives, builds the local controller and accepts a catalog queue with placeholder tokens (the
 * request then fails with an auth error, which is fine — the point is no linker/SIGBUS crash).
 * arm only: the SDK ships no x86_64 natives.
 */
@RunWith(AndroidJUnit4::class)
class AppleMusicSdkLoadInstrumentedTest {
    @Test fun nativeSdkLoadsAndControllerPrepares() {
        assumeTrue(Build.SUPPORTED_ABIS.any { it == "arm64-v8a" })
        val pageSize = Os.sysconf(OsConstants._SC_PAGESIZE)
        Log.i(TAG, "page size = $pageSize")
        // The SDK never loads its own natives (Apple's sample app does it in Application).
        System.loadLibrary("c++_shared")
        System.loadLibrary("appleMusicSDK")
        Log.i(TAG, "libappleMusicSDK.so loaded")
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val tokens = object : TokenProvider {
            override fun getDeveloperToken(): String = "placeholder-developer-token"
            override fun getUserToken(): String = "placeholder-user-token"
        }
        var controller: MediaPlayerController? = null
        val built = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            controller = MediaPlayerControllerFactory.createLocalController(ctx, tokens)
            val provider = CatalogPlaybackQueueItemProvider.Builder().items(MediaItemType.SONG, "617154366").build()
            controller!!.prepare(provider, false)
            built.countDown()
        }
        built.await(10, TimeUnit.SECONDS)
        assertNotNull(controller)
        // Let the native engine spin up and process the queue (and fail auth) before teardown.
        Thread.sleep(5_000)
        Log.i(TAG, "state=${controller!!.playbackState} (page size $pageSize)")
        InstrumentationRegistry.getInstrumentation().runOnMainSync { controller!!.release() }
    }

    private companion object { const val TAG = "AmSdkLoadTest" }
}
